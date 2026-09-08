#!/usr/bin/env bash
set -euo pipefail
# Example restore script -- restores a backup archive produced by this
# image into a running target, using that target's own tools:
#   postgres/mariadb/mongo -- pipe the dump into the running DB container's
#                             own client via `docker/podman exec`
#   tar                    -- extract the archive into a named volume using
#                             a throwaway helper container
#   qdrant                 -- upload each per-collection snapshot to a
#                             running Qdrant over its REST API
# Nothing needs installing on the host for the db/tar paths; the qdrant
# path needs `curl` on the host.
#
# This is a starting point to copy into a specific deployment and adapt
# (env var names, container/volume naming, extra flags for that service's
# schema), not something to run unmodified against production without
# reading it first -- it overwrites data in the target. Other repos (e.g.
# hemsaw/docker, hemsaw/ai) can call this directly instead of duplicating
# it -- see README's "Using these scripts from another repo".
#
# Usage:
#   scripts/restore.sh postgres ./backups/postgres/daily/postgres_20260814.sql.gz    my-postgres-1
#   scripts/restore.sh mariadb  ./backups/mariadb/daily/mariadb_20260814.sql.gz      my-mariadb-1
#   scripts/restore.sh mongo    ./backups/mongo/daily/mongo_20260814.archive.gz      my-mongo-1
#   scripts/restore.sh tar      ./backups/vol-a/daily/vol-a_20260814.tar.gz          hemsaw_vol_a
#   scripts/restore.sh qdrant   ./backups/qdrant/daily/qdrant_mycoll_20260814.snapshot  http://localhost:6333
#
#   scripts/restore.sh all [targets-file]     # restore the LATEST daily backup
#                                              # for every target listed in the
#                                              # manifest (default: ./restore-targets.conf)
#
# Manifest format (one line per target, whitespace-separated,
# `#`-comments/blank lines ignored -- see restore-targets.conf.example):
#   mode  prefix  archive_dir  target  env_file
#
# `target` is mode-specific: a container name (postgres/mariadb/mongo), a
# volume name (tar), or a base URL (qdrant). `env_file` may be `-` (or
# omitted) for a target that needs no creds (tar always; qdrant unless an
# API key is set). It is sourced (in-process) immediately before that
# target's restore, and must set the mode-specific vars below for that
# target only.
#
# In `all` mode, a manifest entry with no backup file yet found is a SKIP,
# not a failure -- the manifest can list every target a deployment might
# eventually back up; only the ones actually producing backups get restored.
# If 3 of 5 listed targets currently have backups, `all` restores those 3
# and exits 0. A manifest entry whose env_file is missing is still a hard
# failure (that's a config mistake, not "not backed up yet").
#
# Env (mode-specific, same names as this image's own backup scripts):
#   postgres: POSTGRES_USER, POSTGRES_DB, POSTGRES_PASSWORD (optional)
#   mariadb:  MARIADB_USER, MARIADB_PASSWORD, MARIADB_DB
#   mongo:    MONGO_USER, MONGO_PASSWORD, MONGO_AUTH_DB (optional; unset = no auth)
#   tar:      (none) -- TAR_RESTORE_MERGE=1 extracts over existing volume
#             contents instead of wiping them first
#   qdrant:   QDRANT_API_KEY (optional) -- BACKUP_PREFIX is required for the
#             single-file invocation (to derive the collection name from
#             the filename); `all` mode takes it from the manifest
#
# Other env:
#   CONTAINER_ENGINE  docker or podman (default: autodetect)
#   BACKUP_IMAGE      helper image for `tar` extraction, must have `tar`
#                     (default: ghcr.io/hem-inc/backup:1)

ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then ENGINE=podman
    else echo "ERROR: neither docker nor podman found on PATH" >&2; exit 1
    fi
fi

BACKUP_IMAGE="${BACKUP_IMAGE:-ghcr.io/hem-inc/backup:1}"

# Clears creds from a previous target in `all` mode so a var an earlier
# target's env_file set can't silently leak into a later target that
# doesn't set it.
_clear_creds() {
    unset POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
          MARIADB_USER MARIADB_PASSWORD MARIADB_DB \
          MONGO_USER MONGO_PASSWORD MONGO_AUTH_DB \
          QDRANT_API_KEY || true
}

# Checks an env var is set, by name, without bash's `${VAR:?msg}` -- that
# form kills the whole script (not just the calling function) when unset,
# which would take down an entire `all` run over one bad target's env_file.
_require() {
    if [ -z "${!1:-}" ]; then
        echo "ERROR: $1 is required" >&2
        return 1
    fi
}

# Derive a Qdrant collection name from a snapshot filename:
#   <prefix>_<collection>_<YYYYMMDD>.snapshot  ->  <collection>
# The collection may itself contain underscores; the date is always 8 digits.
# Fails (non-zero, no output) if the prefix doesn't match or the date
# suffix is missing -- a wrong prefix is a hard error, not a guess.
_qdrant_collection() {
    local base="${1##*/}" prefix="$2" stripped name
    stripped="${base#"${prefix}_"}"
    [ "$stripped" != "$base" ] || return 1
    name="${stripped%_????????.snapshot}"
    [ "$name" != "$stripped" ] || return 1
    printf '%s\n' "$name"
}

restore_one() {
    local MODE="$1" FILE="$2" TARGET="$3" PREFIX="${4:-}"
    [ -f "$FILE" ] || { echo "ERROR: archive file not found: $FILE" >&2; return 1; }

    case "$MODE" in
        postgres)
            _require POSTGRES_USER || return 1
            _require POSTGRES_DB || return 1
            set -- exec -i
            [ -n "${POSTGRES_PASSWORD:-}" ] && set -- "$@" -e PGPASSWORD="$POSTGRES_PASSWORD"
            set -- "$@" "$TARGET" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q
            gunzip -c "$FILE" | "$ENGINE" "$@"
            ;;
        mariadb)
            _require MARIADB_USER || return 1
            _require MARIADB_PASSWORD || return 1
            _require MARIADB_DB || return 1
            # MYSQL_PWD (env, not -p on the command line) keeps the password
            # out of the container's process list -- same reasoning as
            # mariadb-backup.sh's --defaults-extra-file.
            gunzip -c "$FILE" | "$ENGINE" exec -i -e MYSQL_PWD="$MARIADB_PASSWORD" \
                "$TARGET" mariadb -u"$MARIADB_USER" "$MARIADB_DB"
            ;;
        mongo)
            set -- mongorestore --archive --gzip --drop
            if [ -n "${MONGO_USER:-}" ]; then
                set -- "$@" --username="$MONGO_USER" --password="$MONGO_PASSWORD" \
                    --authenticationDatabase="${MONGO_AUTH_DB:-admin}"
            fi
            cat "$FILE" | "$ENGINE" exec -i "$TARGET" "$@"
            ;;
        tar)
            # TARGET is a volume name. Extract inside a throwaway helper so
            # this works whether or not the consuming app is running -- but
            # stop that app first if it is. Clean by default (the volume
            # ends up matching the backup); TAR_RESTORE_MERGE=1 keeps
            # whatever else is already in the volume.
            local src_dir base wipe=""
            src_dir=$(cd "$(dirname "$FILE")" && pwd)
            base=$(basename "$FILE")
            [ -z "${TAR_RESTORE_MERGE:-}" ] && wipe='find /data -mindepth 1 -delete; '
            "$ENGINE" run --rm --entrypoint sh \
                -v "${TARGET}:/data" \
                -v "${src_dir}:/src:ro" \
                "$BACKUP_IMAGE" -c "${wipe}exec tar xzf '/src/${base}' -C /data"
            ;;
        qdrant)
            # TARGET is a base URL; FILE is one per-collection snapshot.
            local coll
            _require PREFIX || { echo "  (BACKUP_PREFIX, or the manifest prefix column)" >&2; return 1; }
            coll=$(_qdrant_collection "$FILE" "$PREFIX") || true
            [ -n "${coll:-}" ] || {
                echo "ERROR: cannot derive collection name from $(basename "$FILE") with prefix '$PREFIX'" >&2
                return 1
            }
            local -a auth=()
            [ -n "${QDRANT_API_KEY:-}" ] && auth=(-H "api-key: ${QDRANT_API_KEY}")
            echo "Uploading $(basename "$FILE") -> ${TARGET%/}/collections/${coll}"
            curl -fsS -X POST "${auth[@]}" \
                -F "snapshot=@${FILE}" \
                "${TARGET%/}/collections/${coll}/snapshots/upload?priority=snapshot" >/dev/null
            ;;
        *)
            echo "ERROR: unsupported mode '$MODE' -- supported: postgres, mariadb, mongo, tar, qdrant" >&2
            return 1
            ;;
    esac
}

# Extension used in daily archive filenames, per single-file mode.
_ext_for_mode() {
    case "$1" in
        postgres|mariadb) echo "sql.gz" ;;
        mongo)            echo "archive.gz" ;;
        tar)              echo "tar.gz" ;;
        *) return 1 ;;
    esac
}

# Latest YYYYMMDD among a prefix's daily qdrant snapshots.
_qdrant_latest_date() {
    find "${1}/daily" -maxdepth 1 -name "${2}_*.snapshot" -type f 2>/dev/null \
        | sed -E 's/.*_([0-9]{8})\.snapshot$/\1/' \
        | sort -r | head -n1
}

USAGE="Usage: $0 <postgres|mariadb|mongo|tar|qdrant> <archive-file> <target>  |  $0 all [targets-file]"

if [ "${1:-}" = "all" ]; then
    TARGETS_FILE="${2:-./restore-targets.conf}"
    [ -f "$TARGETS_FILE" ] || { echo "ERROR: targets file not found: $TARGETS_FILE" >&2; exit 1; }

    echo "About to restore the LATEST daily backup for every target in $TARGETS_FILE that currently has one:"
    grep -Ev '^[[:space:]]*(#|$)' "$TARGETS_FILE" | while read -r mode prefix archive_dir target _; do
        echo "  - $mode  $target  (prefix=$prefix, archive_dir=$archive_dir)"
    done
    read -r -p "This overwrites data in every listed target that has a backup. Continue? [y/N] " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *) echo "Aborted."; exit 1 ;;
    esac

    FAIL=0
    RESULTS=""
    while read -r mode prefix archive_dir target env_file; do
        [ "${env_file:-}" = "-" ] && env_file=""

        files=()
        case "$mode" in
            postgres|mariadb|mongo|tar)
                ext=$(_ext_for_mode "$mode")
                f=$(find "${archive_dir}/daily" -maxdepth 1 -name "${prefix}_*.${ext}" -type f 2>/dev/null | sort -r | head -n1)
                [ -n "$f" ] && files=("$f")
                ;;
            qdrant)
                qdate=$(_qdrant_latest_date "$archive_dir" "$prefix")
                if [ -n "$qdate" ]; then
                    mapfile -t files < <(find "${archive_dir}/daily" -maxdepth 1 -name "${prefix}_*_${qdate}.snapshot" -type f 2>/dev/null | sort)
                fi
                ;;
            *)
                echo "ERROR: unsupported mode '$mode' in $TARGETS_FILE" >&2
                RESULTS="${RESULTS}FAIL  $target ($mode) -- unsupported mode\n"
                FAIL=1
                continue
                ;;
        esac

        if [ "${#files[@]}" -eq 0 ]; then
            echo "SKIP: no ${prefix}_* backup found in ${archive_dir}/daily -- not backed up (yet): $target" >&2
            RESULTS="${RESULTS}SKIP  $target ($mode) -- not backed up\n"
            continue
        fi

        echo "=== restoring $target ($mode) from ${#files[@]} file(s) ==="
        _clear_creds
        if [ -n "${env_file:-}" ]; then
            if [ ! -f "$env_file" ]; then
                echo "ERROR: env_file not found: $env_file -- skipping $target" >&2
                RESULTS="${RESULTS}FAIL  $target ($mode) -- env_file not found\n"
                FAIL=1
                continue
            fi
            # shellcheck disable=SC1090
            . "$env_file"
        fi

        ok=1
        for file in "${files[@]}"; do
            echo "--- $file ---"
            restore_one "$mode" "$file" "$target" "$prefix" || ok=0
        done
        if [ "$ok" -eq 1 ]; then
            RESULTS="${RESULTS}PASS  $target ($mode)\n"
        else
            RESULTS="${RESULTS}FAIL  $target ($mode)\n"
            FAIL=1
        fi
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$TARGETS_FILE")

    echo "############################################"
    echo "### summary"
    echo "############################################"
    printf '%b' "$RESULTS"
    # A target with no backup yet is a SKIP, not a failure -- if only 3 of 5
    # manifest entries are actually being backed up today, restoring those 3
    # cleanly is a pass, not a partial failure. Only real restore errors (or
    # a manifest misconfiguration like a missing env_file) fail the run.
    exit "$FAIL"
fi

MODE="${1:?$USAGE}"
FILE="${2:?$USAGE}"
TARGET="${3:?$USAGE}"

[ -f "$FILE" ] || { echo "ERROR: archive file not found: $FILE" >&2; exit 1; }

echo "About to restore $FILE into $MODE target '$TARGET' via $ENGINE."
read -r -p "This overwrites data in '$TARGET'. Continue? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
esac

restore_one "$MODE" "$FILE" "$TARGET" "${BACKUP_PREFIX:-}"
echo "Restore complete."
