# scripts/

Host-side tooling for this image. Nothing here runs inside the shipped
container or is `COPY`'d into the `Dockerfile` — these are plain scripts an
operator, a host cron job, a systemd timer, or another repo's CI runs
directly, using whatever `docker`/`podman` and CI tooling is already on
that host's `PATH`. See the main [README](../README.md#drill-testing) for
why restore-verification deliberately lives out here instead of inside the
always-on backup container (short version: giving a background cron
container access to the container-engine socket effectively hands it root
on the host — a bad trade for a narrowly-scoped backup process).

| Script | Run by | Purpose |
|---|---|---|
| [`restore.sh`](#restoresh) | An operator, during a real recovery | Restore one backup archive (or every target in a manifest) into a running container, a named volume, or a live Qdrant |
| [`restore-verify.sh`](#restore-verifysh) | An operator, on a schedule or on demand | Prove a backup actually restores cleanly, against a throwaway scratch container or tree |
| [`functional-test.sh`](#functional-testsh) | This repo's own CI | Prove the image's backup/restore logic works, against ephemeral fixtures |

All three require `docker` or `podman` on `PATH`; `restore.sh` and
`restore-verify.sh` also work fine with rootless Podman (they only ever run
`podman exec`/`podman run`/`podman rm`/`podman port`, never touch a socket
directly). The `qdrant` code paths additionally need `curl` and `jq` on the
host; the `postgres`/`mariadb`/`mongo`/`tar` paths need neither.

## Prerequisites

- `bash` 4+ (all three scripts use `set -euo pipefail`, `mapfile`, and other bash-only syntax — `sh scripts/restore.sh ...` will not work; macOS ships bash 3.2, so `brew install bash` if testing from a Mac)
- `docker` or `podman` on `PATH` (or set `CONTAINER_ENGINE=docker` / `CONTAINER_ENGINE=podman` to skip autodetection)
- `gunzip`/`gzip` (restore.sh, restore-verify.sh)
- GNU `timeout` (restore-verify.sh's readiness waits) — present on the Linux hosts/CI runners this project targets; not preinstalled on macOS (`brew install coreutils` gives you `gtimeout`, or alias `timeout=gtimeout` if testing restore-verify.sh from a Mac)
- `curl` and `jq` — only for the `qdrant` code paths (snapshot upload + `points_count` inventory over REST)
- A running target container / named volume / reachable Qdrant URL to restore into or compare against

The `postgres`/`mariadb`/`mongo` paths need nothing else on the host — no
client libraries, no Python — they lean on the target database image's own
client tools via `exec` (`psql`, `mariadb`, `mongorestore`). The `tar` path
extracts inside a throwaway helper container built from `BACKUP_IMAGE`
(default `ghcr.io/hem-inc/backup:1`), so it needs no host `tar` either.

## `restore.sh`

```console
$ scripts/restore.sh <postgres|mariadb|mongo|tar|qdrant> <archive-file> <target>
$ scripts/restore.sh all [targets-file]
```

`target` is mode-specific — a running container name for
`postgres`/`mariadb`/`mongo`, a named volume for `tar`, a base URL for
`qdrant`:

- **`postgres` / `mariadb` / `mongo`** — decompress the dump on the host
  and pipe it into the running container's own client
  (`psql` / `mariadb` / `mongorestore`). These are the engines with
  natively-compiled clients whose behavior can break across a base-image
  change (see the main README's "Why Ubuntu instead of Alpine").
- **`tar`** — extract the archive into the named volume using a throwaway
  helper container (`run --rm -v <vol>:/data ... tar xzf`). Works whether
  or not the app that consumes the volume is running — but stop it first.
  Clean by default (the volume ends up matching the backup);
  `TAR_RESTORE_MERGE=1` extracts over whatever is already there.
- **`qdrant`** — `POST` each per-collection `.snapshot` to
  `/collections/{name}/snapshots/upload` on the live instance. The
  collection name is derived from the filename, so `BACKUP_PREFIX` must be
  set for the single-file form (the `all` form takes it from the manifest).
  `QDRANT_API_KEY` is sent as `api-key` if set.

`surreal` is not covered — restore a SurrealQL dump with `POST /import`.

```console
$ scripts/restore.sh postgres ./backups/postgres/daily/postgres_20260814.sql.gz my-postgres-1
About to restore ./backups/postgres/daily/postgres_20260814.sql.gz into postgres target 'my-postgres-1' via docker.
This overwrites data in 'my-postgres-1'. Continue? [y/N] y
Restore complete.
```

Required env vars, per mode (same names as this image's own backup
scripts — see the main README's "Mode-specific environment variables"):

| Mode | Required | Optional |
|---|---|---|
| `postgres` | `POSTGRES_USER`, `POSTGRES_DB` | `POSTGRES_PASSWORD` |
| `mariadb` | `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DB` | — |
| `mongo` | — | `MONGO_USER`, `MONGO_PASSWORD`, `MONGO_AUTH_DB` (default `admin`) |
| `tar` | — | `TAR_RESTORE_MERGE`, `BACKUP_IMAGE` |
| `qdrant` | `BACKUP_PREFIX` (single-file form only) | `QDRANT_API_KEY` |

```console
$ POSTGRES_USER=myuser POSTGRES_PASSWORD=mypass POSTGRES_DB=mydb \
  scripts/restore.sh postgres ./backups/postgres/daily/postgres_20260814.sql.gz my-postgres-1

$ scripts/restore.sh tar ./backups/vol-a/daily/vol-a_20260814.tar.gz hemsaw_vol_a

$ BACKUP_PREFIX=qdrant \
  scripts/restore.sh qdrant ./backups/qdrant/daily/qdrant_mycoll_20260814.snapshot http://localhost:6333
```

Passwords never appear on the command line or in the target container's
process list: Postgres gets `PGPASSWORD` via `exec -e`, MariaDB gets
`MYSQL_PWD` via `exec -e`, Mongo gets `--password` passed to `mongorestore`
inside the container's own exec session (not the host's process list).

Always prompts for confirmation before writing — it overwrites whatever is
currently in the target container/database. There is no `--yes`/`--force`
flag; script it with `yes | scripts/restore.sh ...` if you deliberately
need non-interactive DR automation, understanding what that skips.

This is a **starting point to copy into a specific deployment and adapt**
(container/volume naming, extra restore flags for that service's schema),
not something to run unmodified against production without reading it first.

## `restore-verify.sh`

The real "does this backup actually stand up" check. Per target, it:

1. Finds the latest daily backup for `BACKUP_PREFIX` in `ARCHIVE_DIR`
   (for `qdrant`, every per-collection snapshot sharing the latest date).
2. Reconstitutes it in a throwaway scratch:
   - `postgres` / `mariadb` / `mongo` — a scratch container of the same
     engine/version this project's fixtures use (`postgres:16-alpine`,
     `mariadb:10.11`, `mongo:8.0`), restore piped in.
   - `tar` — the archive extracted into a scratch tree inside a helper
     container built from `BACKUP_IMAGE`.
   - `qdrant` — a scratch `qdrant/qdrant` container
     (`QDRANT_VERIFY_IMAGE`, default `v1.19.1` — override to match the
     version this deployment runs), each snapshot uploaded into it.
3. Prints a schema-agnostic inventory side by side with `LIVE_TARGET`:
   table/collection row counts (db), file count + byte size + top-level
   entries (`tar`, live volume mounted read-only), per-collection
   `points_count` (`qdrant`).
4. Tears the scratch container/tree down unconditionally (normal exit,
   failure, or Ctrl-C — an `EXIT` trap covers interruption too).

```console
$ ARCHIVE_DIR=./backups/postgres BACKUP_PREFIX=postgres LIVE_CONTAINER=my-postgres-1 \
  POSTGRES_USER=myuser POSTGRES_PASSWORD=mypass POSTGRES_DB=mydb \
  scripts/restore-verify.sh postgres
--- using ./backups/postgres/daily/postgres_20260814.sql.gz ---
--- starting scratch postgres ---
--- restoring into scratch ---
--- inventory: scratch (restored backup) ---
 schemaname |  relname  | n_live_tup
------------+-----------+------------
 public     | orders    |       4213
--- inventory: my-postgres-1 (live) ---
 schemaname |  relname  | n_live_tup
------------+-----------+------------
 public     | orders    |       4310
=== RESTORE-VERIFY PASSED: ./backups/postgres/daily/postgres_20260814.sql.gz restored cleanly into a fresh postgres instance ===
```

**The inventory query is informational, not an equality check.** The live
database will usually have moved on since the backup was taken (4213 vs
4310 rows above is expected, not a bug) — comparing exact counts would
produce false failures on every run. What PASS/FAIL actually means is
narrower and more useful: did a real production dump restore cleanly into
a fresh instance of the real engine version this deployment runs, and does
the result look structurally sane (same tables/collections, non-garbage
row counts) next to the real thing. That's exactly the class of failure a
"is the gzip valid" check (`drill.sh`, inside the image) can't catch —
e.g. a dump taken mid-schema-migration that gunzips fine but won't restore.

| Env var | Required | Default |
|---|---|---|
| `LIVE_TARGET` | yes | — (live container name for db, volume name for `tar`, base URL for `qdrant`; `LIVE_CONTAINER` is accepted as an alias) |
| `ARCHIVE_DIR` | no | `./backups` |
| `BACKUP_PREFIX` | no | the mode name |
| `CONTAINER_ENGINE` | no | autodetect (`docker` preferred, then `podman`) |
| `BACKUP_IMAGE` | no | `ghcr.io/hem-inc/backup:1` (`tar` helper) |
| `QDRANT_VERIFY_IMAGE` | no | `qdrant/qdrant:v1.19.1` (`qdrant` scratch) |
| `QDRANT_API_KEY` | no | — (sent to the live qdrant target only) |
| Mode creds | db modes only, same table as `restore.sh` above minus the "optional" carve-outs — `POSTGRES_PASSWORD`/`MARIADB_*` are required here since they also stand up the scratch instance. `tar` and `qdrant` need no creds. | — |

## Restoring or drilling every target at once

Both scripts accept `all [targets-file]` in place of the single-target
arguments, driven by a manifest — one line per target, whitespace-separated,
`#`-comments and blank lines ignored (template: `restore-targets.conf.example`):

```
# mode      prefix     archive_dir              target                  env_file
postgres    postgres   ../backups/postgres      my-postgres-1           ./secrets/postgres.env
mariadb     mariadb    ../backups/mariadb       my-mariadb-1            ./secrets/mariadb.env
mongo       mongo      ../backups/mongo         my-mongo-1              ./secrets/mongo.env
tar         vol-a      ../backups/vol-a         hemsaw_vol_a            -
qdrant      qdrant     ../backups/qdrant        http://localhost:6333   -
```

The `all` loop dispatches per line on `mode`, so a deployment with, say,
three `tar` volumes and one `qdrant` is just four lines — no need for one
manifest per mode.

| Column | Meaning |
|---|---|
| `mode` | `postgres`, `mariadb`, `mongo`, `tar`, or `qdrant` |
| `prefix` | `BACKUP_PREFIX` the backup was written with |
| `archive_dir` | host path containing `daily/` — the host-side path backing that service's `/archive` volume mount, **not** the in-container `/archive` path |
| `target` | mode-specific: a container name (`postgres`/`mariadb`/`mongo`), a volume name (`tar`), or a base URL (`qdrant`). For `restore.sh` it's what gets restored *into*; for `restore-verify.sh` it's the **live** thing compared against a throwaway scratch |
| `env_file` | path to a `KEY=value` file with that target's creds, sourced immediately before that one target runs and cleared before the next — one target's env can never leak into another's. Use `-` for a target that needs no creds (`tar`; `qdrant` unless an API key applies) |

```console
$ cp scripts/restore-targets.conf.example restore-targets.conf
$ vim restore-targets.conf   # point at your real containers/archive dirs/env files

$ scripts/restore-verify.sh all                       # drill every target
$ scripts/restore.sh all ./restore-targets.conf        # restore every target (asks once, up front, before touching anything)
```

**A manifest entry with no backup file yet is a `SKIP`, not a failure.**
The manifest is meant to list every target a deployment *could* eventually
back up, not just the ones that do today — if 3 of 5 listed targets
currently produce backups, `all` restores/drills those 3 and exits `0`;
the other 2 show up as `SKIP ... -- not backed up` in the summary. Only a
real restore/query error, or a manifest entry whose `env_file` is missing,
fails the run:

```
############################################
### summary
############################################
PASS  my-postgres-1 (postgres)
SKIP  my-mariadb-1 (mariadb) -- not backed up
PASS  my-mongo-1 (mongo)
```

`restore.sh all` prints every listed target and asks for **one**
confirmation up front, then restores each from its latest daily backup
without prompting again per target. `restore-verify.sh all` never prompts
(it only ever touches its own scratch containers) and keeps going after a
single target fails, so one bad target doesn't hide results for the rest.

Keep `restore-targets.conf`, any `secrets/` directory, and `*.env` files
out of version control — the repo's own `.gitignore` already excludes
them, since they encode real container names and point at real credentials
for a specific deployment.

## `functional-test.sh`

This one isn't operator-facing — it's this repo's own CI, run by every
push/PR via `.github/workflows/test.yml` and required to pass before
`publish.yml` will push a new image to GHCR. It proves the *image's own*
backup/restore logic works (not a specific deployment's data), against
ephemeral fixtures defined in `docker-compose.test.yml`:

```console
$ scripts/functional-test.sh
```

Builds the image, starts throwaway `postgres`/`mariadb`/`mongo`/`qdrant`
fixtures plus a seeded source volume, drops a canary (row, document, point,
or file) into each, runs each backup mode, restores the resulting archive
into a fresh container/volume of the same kind, and asserts the canary
survived the round trip. Also sanity-checks `drill.sh` (the in-image,
gzip/tar-integrity-only check) against one of the archives it produced.
Cleans up all containers/volumes/networks on exit via a trap, success or
failure.

Safe to run locally before pushing — same thing CI does, just on your own
machine. Not meant to run against production: everything it touches is
throwaway, created and destroyed by the run itself.

## Where the docker/podman socket question landed

Short version, for anyone re-deriving this: a fully automated,
always-running restore-drill *inside* the shipped image would need either
a permanently standing scratch database (real resource cost on the
8GB-RAM industrial PCs this image actually runs on) or `docker.sock`/
`podman.sock` mounted into the backup container (which hands that
background cron process root-equivalent control of the host — a bad
trade for what should be a narrowly-scoped process, and doesn't work
cleanly with rootless Podman's per-user socket path anyway). `restore.sh`
and `restore-verify.sh` get the same real-restore validation without
either cost, by running as host-side scripts that use whatever engine
access the *operator* already has — never inside the always-on container.
See the main README's [Drill testing](../README.md#drill-testing) section
for the full reasoning.
