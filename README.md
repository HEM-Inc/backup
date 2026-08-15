# backup

A single Docker/Podman image providing six backup strategies. Pull once, reuse across any service by mounting a volume and setting env vars. No Docker socket required — compatible with both Docker and Podman (including rootless).

Published to GHCR as [`ghcr.io/hem-inc/backup`](https://github.com/HEM-Inc/backup/pkgs/container/backup). See [Versioning](#versioning) for tags.

Runs as a non-root `backup` user via [supercronic](https://github.com/aptible/supercronic). All job output (including pruning activity) appears in `docker compose logs` / `podman compose logs`.

## Image contents

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 26.04 LTS + curl + jq + postgresql-client + mariadb-client + `mongodump`/`mongorestore` (copied from the official `mongo:8.0` image) + supercronic; drops to non-root via gosu |
| `entrypoint.sh` | Writes crontab from `BACKUP_SCHEDULE` (and `DRILL_SCHEDULE`, if set), chowns archive dirs, execs supercronic as the `backup` user |
| `backup.sh` | Dispatcher — reads `BACKUP_MODE` and calls the appropriate script |
| `qd-snapshot.sh` | Qdrant API-based backup — per-collection snapshot via REST API |
| `tar-backup.sh` | Generic volume backup — tars a mounted volume to an archive directory |
| `pg-backup.sh` | Postgres backup — `pg_dump | gzip`, waits for the database to be ready |
| `mariadb-backup.sh` | MariaDB/MySQL backup — `mariadb-dump | gzip`, waits for the database to be ready |
| `surreal-backup.sh` | SurrealDB backup — logical export via the HTTP `/export` endpoint, gzipped |
| `mongo-backup.sh` | MongoDB backup — `mongodump --archive --gzip`, waits for the database to be ready |
| `retention.sh` | Shared tiered retention — daily / weekly / monthly; called by all backup scripts |
| `drill.sh` | Lightweight backup integrity check — see [Drill testing](#drill-testing) |

**Why Ubuntu instead of Alpine**: `mongodump`/`mongorestore` ship no Alpine/musl build — they're dynamically linked against glibc and Kerberos. Rather than fetch MongoDB's own tools tarball as a second, independently-checksummed download path, the binaries are copied from the official `mongo:8.0` image in a multi-stage build; the final stage uses the same Ubuntu lineage so there's no glibc-version mismatch to worry about. `mariadb-client` is installed explicitly (not `default-mysql-client`) — Ubuntu's `default-mysql-client` installs `mysqldump`/`mysqladmin`, not the `mariadb-dump`/`mariadb-admin` names `mariadb-backup.sh` actually calls.

## Backup modes

Select the mode with `BACKUP_MODE`:

| Mode | Script | Use for |
|---|---|---|
| `qdrant` | `qd-snapshot.sh` | Qdrant vector database |
| `tar` | `tar-backup.sh` | Any mounted volume |
| `postgres` | `pg-backup.sh` | PostgreSQL databases |
| `mariadb` | `mariadb-backup.sh` | MariaDB / MySQL databases |
| `surreal` | `surreal-backup.sh` | SurrealDB databases |
| `mongo` | `mongo-backup.sh` | MongoDB databases |

## Common environment variables

These apply to all modes:

| Env var | Default | Description |
|---|---|---|
| `BACKUP_MODE` | `tar` | `qdrant`, `tar`, `postgres`, `mariadb`, `surreal`, or `mongo` |
| `BACKUP_SCHEDULE` | *(required)* | Cron expression, e.g. `0 3 * * *` |
| `BACKUP_PREFIX` | `backup` | Filename prefix |
| `BACKUP_ARCHIVE` | `/archive` | Path inside the container to write archives |
| `BACKUP_KEEP_DAILY` | `7` | Number of daily backups to keep |
| `BACKUP_KEEP_WEEKLY` | *(unset)* | Number of weekly backups to keep; unset disables weekly |
| `BACKUP_KEEP_MONTHLY` | *(unset)* | Number of monthly backups to keep; unset disables monthly |

## Mode-specific environment variables

### `BACKUP_MODE=qdrant`

| Env var | Default | Description |
|---|---|---|
| `QDRANT_URL` | `http://qdrant:6333` | Base URL of the Qdrant instance |

Snapshots are per collection, not a single full-storage snapshot: full-storage
snapshots can only be restored via a CLI flag at Qdrant startup (no REST API
for it), which would require stopping the live instance to restore. Per-collection
snapshots support REST API recovery against a running instance instead, so
`qd-snapshot.sh` enumerates collections and snapshots each one, archived as
`<prefix>_<collection>_<YYYYMMDD>.snapshot`.

Snapshots are fetched via HTTP download (`GET .../snapshots/{name}`), not read
off a shared filesystem mount — Qdrant creates the file as its own container
user, which this container's unprivileged backup user can't read directly.
Only the archive mount is required:

```yaml
volumes:
  - ./backups/qdrant:/archive
```

### `BACKUP_MODE=tar`

| Env var | Default | Description |
|---|---|---|
| `BACKUP_SOURCE` | `/data` | Path inside the container to back up |

### `BACKUP_MODE=postgres`

| Env var | Default | Description |
|---|---|---|
| `POSTGRES_HOST` | `postgres` | Hostname of the PostgreSQL server |
| `POSTGRES_PORT` | `5432` | Port |
| `POSTGRES_USER` | *(required)* | Database user |
| `POSTGRES_PASSWORD` | *(required)* | Database password |
| `POSTGRES_DB` | *(required)* | Database name |

The script waits for the database to be ready before dumping, so it is safe to start alongside the database container without an explicit `depends_on` health check.

### `BACKUP_MODE=mariadb`

| Env var | Default | Description |
|---|---|---|
| `MARIADB_HOST` | `mariadb` | Hostname of the MariaDB server |
| `MARIADB_PORT` | `3306` | Port |
| `MARIADB_USER` | *(required)* | Database user |
| `MARIADB_PASSWORD` | *(required)* | Database password |
| `MARIADB_DB` | *(unset)* | Database name; if unset, dumps all databases |

The script waits for the database to be ready (`mariadb-admin ping`) before dumping, so it is safe to start alongside the database container without an explicit `depends_on` health check. The password is passed via a `--defaults-extra-file` (never on the command line or in the process list).

### `BACKUP_MODE=surreal`

| Env var | Default | Description |
|---|---|---|
| `SURREAL_URL` | `http://surrealdb:8000` | Base URL of the SurrealDB HTTP interface |
| `SURREAL_USER` | *(required)* | Database user |
| `SURREAL_PASSWORD` | *(required)* | Database password |
| `SURREAL_NAMESPACE` | *(required)* | Namespace to export |
| `SURREAL_DATABASE` | *(required)* | Database to export |

Produces a logical SurrealQL dump via `GET /export` — the same mechanism as SurrealDB's own `surreal export` CLI — rather than tarring the RocksDB storage directory directly, since a live tar of RocksDB files carries real risk of capturing a torn write. The script waits for `GET /health` before exporting, so it is safe to start alongside the database container without an explicit `depends_on` health check.

### `BACKUP_MODE=mongo`

| Env var | Default | Description |
|---|---|---|
| `MONGO_HOST` | `mongodb` | Hostname of the MongoDB server |
| `MONGO_PORT` | `27017` | Port |
| `MONGO_USER` | *(unset)* | Database user; if unset, connects without authentication |
| `MONGO_PASSWORD` | *(unset)* | Database password |
| `MONGO_AUTH_DB` | `admin` | Authentication database, only used when `MONGO_USER` is set |
| `MONGO_DB` | *(unset)* | Database name; if unset, dumps all databases |

Produces a single gzip-compressed archive via `mongodump --archive --gzip` (extension `.archive.gz`), restorable with `mongorestore --archive --gzip`. The script waits for the port to accept connections (`nc -z`) before dumping — `mongosh` isn't bundled in this image (it's ~190MB, not needed for a headless dump/restore), so readiness is checked at the TCP level rather than with a real ping. When `MONGO_USER` is set, credentials are written to a temp YAML `--config` file rather than passed on the command line — same reasoning as `mariadb-backup.sh`'s `--defaults-extra-file`.

## Archive structure

Archives are written to `${BACKUP_ARCHIVE}` with the following layout:

```
/archive/
  daily/    PREFIX_YYYYMMDD.{ext}
  weekly/   PREFIX_YYYYWW.{ext}    (ISO year + week — written on Sundays)
  monthly/  PREFIX_YYYYMM.{ext}    (written on the last day of the month)
```

File extensions by mode: `.snapshot` (qdrant), `.tar.gz` (tar), `.sql.gz` (postgres, mariadb), `.surql.gz` (surreal), `.archive.gz` (mongo).

Retention is enforced by filename sort (lexicographic = chronological), not by `mtime`, so counts are exact regardless of month length or year boundaries. ISO week numbering uses `%G%V` which correctly handles the Dec/Jan edge case.

## Drill testing

`drill.sh` runs on an optional second, independent cron schedule (`DRILL_SCHEDULE`, alongside `BACKUP_SCHEDULE`) and validates the most recent backup file is structurally intact — `tar -tzf`/`gunzip -t` for the compressed formats, a non-empty check for Qdrant's raw `.snapshot` format. It logs `DRILL PASS`/`DRILL FAIL` per file and exits non-zero on any failure, visible in `docker compose logs` like every other job this image runs.

```yaml
environment:
  BACKUP_SCHEDULE: "0 2 * * *"
  DRILL_SCHEDULE: "0 5 * * 0"   # weekly, Sunday 05:00 -- unset = no drill runs at all
```

**What this deliberately does *not* do**: restore the backup into a live database and verify the data. That would need a second, standing database instance (a "scratch" sidecar) to restore into — considered and rejected for now. The deployment fleet this image actually runs on includes 8GB-RAM industrial PCs already running a real-time production stack; a second idle database engine plus a full restored copy of production data is a real resource risk there (RAM via `tmpfs`, or disk via a real volume — neither is free on hardware that tight), and a `docker.sock`-based "spin up a throwaway container on demand" alternative doesn't work cleanly with rootless Podman (no `/var/run/docker.sock` to bind-mount; its own API socket lives at a different, per-user path) — see this project's own "no Docker socket required" design principle above. If a specific deployment has real headroom to spare, a scratch-sidecar restore-verify drill is a reasonable thing to add to *that stack's* compose file (not to this shared image) — not implemented anywhere today.

The genuine restore-and-verify testing — does a real restore of a real dump actually work, not just "is the file well-formed" — happens in this repo's own CI instead (`scripts/functional-test.sh`, run by every push/PR via `.github/workflows/test.yml`, and required to pass before `publish.yml` will push a new image to GHCR). CI runners don't have the IPC fleet's resource constraints, so that's where it's safe to do the real thing.

## Adding a new backup target

Add a service to the relevant `docker-compose.yml`, pulling the published image rather than building locally:

```yaml
my-service-backup:
  image: ghcr.io/hem-inc/backup:1
  hostname: my_service_backup
  restart: unless-stopped
  depends_on:
    - my-service
  networks:
    - internal_network
  volumes:
    - my_volume:/data:ro
    - ../../backups/my-service:/archive
  environment:
    BACKUP_MODE: tar
    BACKUP_SCHEDULE: "0 4 * * *"
    BACKUP_SOURCE: /data
    BACKUP_ARCHIVE: /archive
    BACKUP_PREFIX: my-service
    BACKUP_KEEP_DAILY: 7
    BACKUP_KEEP_WEEKLY: 4
    BACKUP_KEEP_MONTHLY: 3
```

Then create the archive directory on the host: `mkdir -p backups/my-service`.

Pin to `:1` (major) to get patch/minor updates automatically, `:1.2` (minor) for patch updates only, or an exact `:1.2.3` for full pinning. `:latest` tracks the newest release regardless of major version.

## Versioning

[Semantic Versioning](https://semver.org/) — see [`VERSION`](VERSION) for the current version. Every commit updates `VERSION` in the same commit, per [`CLAUDE.md`](CLAUDE.md)'s Conventional Commits-based bump rule. A pushed `vX.Y.Z` tag triggers [`.github/workflows/publish.yml`](.github/workflows/publish.yml), which builds and pushes `linux/amd64` + `linux/arm64` images to GHCR tagged `latest`, `X.Y.Z`, `X.Y`, and `X`.
