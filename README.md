# backup

A single Docker/Podman image providing six backup strategies. Pull once, reuse across any service by mounting a volume and setting env vars. No Docker socket required — compatible with both Docker and Podman (including rootless).

Published to GHCR as [`ghcr.io/hem-inc/backup`](https://github.com/HEM-Inc/backup/pkgs/container/backup). See [Versioning](#versioning) for tags.

Runs as a non-root `backup` user via [supercronic](https://github.com/aptible/supercronic). All job output (including pruning activity) appears in `docker compose logs` / `podman compose logs`.

## Image contents

Root holds the container's front door; `src/` holds the scripts baked into
the image and run behind it; `scripts/` holds host-side operator tooling
that never enters the image (see [scripts/README.md](scripts/README.md)).

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 26.04 LTS + curl + jq + postgresql-client + mariadb-client + `mongodump`/`mongorestore` (copied from the official `mongo:8.0` image) + supercronic; drops to non-root via gosu |
| `entrypoint.sh` | Writes crontab from `BACKUP_SCHEDULE` (and `DRILL_SCHEDULE`, if set), chowns archive dirs, execs supercronic as the `backup` user |
| `src/backup.sh` | Dispatcher — reads `BACKUP_MODE` and calls the appropriate script |
| `src/qd-snapshot.sh` | Qdrant API-based backup — per-collection snapshot via REST API |
| `src/tar-backup.sh` | Generic volume backup — tars a mounted volume to an archive directory |
| `src/pg-backup.sh` | Postgres backup — `pg_dump | gzip`, waits for the database to be ready |
| `src/mariadb-backup.sh` | MariaDB/MySQL backup — `mariadb-dump | gzip`, waits for the database to be ready |
| `src/surreal-backup.sh` | SurrealDB backup — logical export via the HTTP `/export` endpoint, gzipped |
| `src/mongo-backup.sh` | MongoDB backup — `mongodump --archive --gzip`, waits for the database to be ready |
| `src/retention.sh` | Shared tiered retention — daily / weekly / monthly; called by all backup scripts |
| `src/drill.sh` | Lightweight backup integrity check — see [Drill testing](#drill-testing) |

**Why Ubuntu instead of Alpine**: `mongodump`/`mongorestore` ship no Alpine/musl build — they're dynamically linked against glibc and Kerberos. Rather than fetch MongoDB's own tools tarball as a second, independently-checksummed download path, the binaries are copied from the official `mongo:8.0` image in a multi-stage build; the final stage uses the same Ubuntu lineage so there's no glibc-version mismatch to worry about. `mariadb-client` is installed explicitly (not `default-mysql-client`) — Ubuntu's `default-mysql-client` installs `mysqldump`/`mysqladmin`, not the `mariadb-dump`/`mariadb-admin` names `mariadb-backup.sh` actually calls.

## Backup modes

Select the mode with `BACKUP_MODE`:

| Mode | Script | Use for |
|---|---|---|
| `qdrant` | `src/qd-snapshot.sh` | Qdrant vector database |
| `tar` | `src/tar-backup.sh` | Any mounted volume |
| `postgres` | `src/pg-backup.sh` | PostgreSQL databases |
| `mariadb` | `src/mariadb-backup.sh` | MariaDB / MySQL databases |
| `surreal` | `src/surreal-backup.sh` | SurrealDB databases |
| `mongo` | `src/mongo-backup.sh` | MongoDB databases |

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

**What this deliberately does *not* do**: restore the backup into a live database and verify the data, on the fleet's own schedule, from inside the image. That would need a second, standing database instance (a "scratch" sidecar) baked into every deployment, or `docker.sock`/`podman.sock` access from the always-on backup container itself — both rejected for this shared image. The deployment fleet this image actually runs on includes 8GB-RAM industrial PCs already running a real-time production stack, where a second idle database engine plus a full restored copy of production data is a real resource risk (RAM via `tmpfs`, or disk via a real volume — neither is free on hardware that tight). Giving the backup container the container-engine socket would fix the "how do we spin up a throwaway container" problem, but it also hands that background cron process root-equivalent control of the host — a bad trade for what should be a narrowly-scoped process, and it doesn't work cleanly with rootless Podman anyway (no fixed `/var/run/docker.sock`-equivalent path — see this project's own "no Docker socket required" design principle above).

The genuine restore-and-verify testing — does a real restore of a real dump actually work, not just "is the file well-formed" — happens in two places instead, neither of which requires the shared image to touch a socket:

- **This repo's own CI** (`scripts/functional-test.sh`, run by every push/PR via `.github/workflows/test.yml`, required to pass before `publish.yml` will push a new image to GHCR) — against ephemeral fixtures, proving the image's own backup/restore logic works.
- **`scripts/restore-verify.sh`**, run by an operator against a real deployment (see [Restoring a backup](#restoring-a-backup) below) — it shells out to whatever `docker`/`podman` is already on the *host's* PATH, the same as any other admin tooling. The always-on backup container's own permissions are unchanged either way.

## Restoring a backup

Two scripts under `scripts/` cover the two restore scenarios — copy and adapt them for a specific deployment rather than running them unmodified. Full usage, env vars, the multi-target manifest format, and worked examples live in **[scripts/README.md](scripts/README.md)**; short version:

- **`scripts/restore.sh <postgres|mariadb|mongo|tar|qdrant> <archive-file> <target>`** — a real restore. `target` is a running container (db, dump piped into its own client via `docker/podman exec`), a named volume (`tar`, extracted via a throwaway helper container), or a base URL (`qdrant`, each snapshot uploaded over REST). Prompts for confirmation before overwriting data. Use this for actual disaster recovery.
- **`scripts/restore-verify.sh <postgres|mariadb|mongo|tar|qdrant>`** — the full validation drill: finds the latest backup for `BACKUP_PREFIX`, reconstitutes it in a throwaway scratch (a fresh engine container for db modes, a scratch tree for `tar`, a scratch `qdrant/qdrant` for `qdrant`), runs a schema-agnostic inventory (row counts / file count + bytes / per-collection `points_count`) against both the scratch and `LIVE_TARGET`, prints them side by side, and tears the scratch down. Pass/fail is about whether the restore and inventory succeeded, not whether the two sides match exactly — the live target will usually have moved on since the backup was taken.
- Both also take **`all [targets-file]`** to restore/drill every target listed in a manifest in one shot (`scripts/restore-targets.conf.example`). The loop dispatches per line on `mode`, so a stack with (say) three `tar` volumes and one `qdrant` is just four manifest lines. A target with no backup yet is a `SKIP`, not a failure, so a manifest can list every service a deployment might eventually back up without failing the run over the ones that aren't wired up yet.
- `surreal` restore is not scripted — reimport a SurrealQL dump with `POST /import`.

Neither script requires `docker.sock`/`podman.sock` inside any container; both are meant to be run by whoever/whatever already has host-level Docker or Podman access (an operator's shell, a host cron job, a systemd timer) — never wired into the always-on backup container.

```console
$ ARCHIVE_DIR=./backups/postgres BACKUP_PREFIX=postgres LIVE_CONTAINER=my-postgres-1 \
  POSTGRES_USER=myuser POSTGRES_PASSWORD=mypass POSTGRES_DB=mydb \
  scripts/restore-verify.sh postgres
```

### Using these scripts from another repo

`scripts/restore.sh` and `scripts/restore-verify.sh` don't depend on anything else in this image or repo (no `BACKUP_MODE`, no Dockerfile) — they're plain host scripts driven entirely by CLI args, env vars, and a targets manifest. A compose repo like `hemsaw/docker` or `hemsaw/ai` can call a pinned copy directly instead of duplicating them:

```console
$ curl -fsSL https://raw.githubusercontent.com/HEM-Inc/backup/v1.2.0/scripts/restore-verify.sh -o restore-verify.sh
$ chmod +x restore-verify.sh
$ LIVE_CONTAINER=my-postgres-1 POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=... ./restore-verify.sh postgres
```

Pin to a tag (`v1.2.0`, matching this repo's own [Versioning](#versioning)), not `main` — an unpinned reference from another repo can otherwise pick up a breaking change to these scripts without warning.

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
