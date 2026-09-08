#!/usr/bin/env bash
set -euo pipefail
# Full restore-validation drill -- run by an operator on the host (cron,
# manually, or a timer unit), NOT by the always-on backup container. It
# never touches docker.sock/podman.sock itself: it just shells out to
# whichever engine is already on the host's PATH, the same as any other
# admin tooling would. See README's "Drill testing" section for why this
# lives here instead of inside the shared image. Other repos (e.g.
# hemsaw/docker, hemsaw/ai) can call this directly instead of duplicating
# it -- see README's "Using these scripts from another repo".
#
# What it does, per target:
#   postgres/mariadb/mongo -- start a throwaway scratch DB, restore the
#     latest backup into it, run a schema-agnostic inventory query against
#     the scratch restore and LIVE_TARGET, print them side by side.
#   tar -- extract the latest archive into a scratch tree, inventory it
#     (file count / byte size / top-level entries), print that next to the
#     same inventory of the live volume (mounted read-only).
#   qdrant -- start a throwaway scratch Qdrant, upload the latest per-
#     collection snapshots into it, print each collection's points_count
#     next to the live instance's.
# Scratch containers/trees are torn down unconditionally (normal exit,
# failure, or Ctrl-C -- an EXIT trap covers interruption too).
#
# The inventory is informational, not an equality check -- the live target
# will usually have moved on since the backup was taken, so a diff is
# expected. What this validates is the thing CI's ephemeral fixtures can't:
# that a real production backup restores cleanly into a fresh instance of
# the real engine/version this deployment runs, and produces something
# structurally sane next to the real one. Pass/fail is about whether the
# restore and inventory succeeded at all.
#
# Usage:
#   scripts/restore-verify.sh <postgres|mariadb|mongo|tar|qdrant>
#
#   scripts/restore-verify.sh all [targets-file]   # drill every target in the
#                                                   # manifest (default:
#                                                   # ./restore-targets.conf)
#
# Manifest format (one line per target, whitespace-separated,
# `#`-comments/blank lines ignored -- see restore-targets.conf.example):
#   mode  prefix  archive_dir  target  env_file
#
# `target` is mode-specific: a live container name (postgres/mariadb/mongo),
# a volume name (tar), or a base URL (qdrant). `env_file` may be `-` (or
# omitted) for a target that needs no creds. It is sourced (in-process)
# immediately before that target's drill, and must set the mode-specific
# vars below for that target only.
#
# In `all` mode, a manifest entry with no backup file yet found is a SKIP,
# not a failure -- the manifest can list every target a deployment might
# eventually back up; only the ones actually producing backups get drilled.
# If 3 of 5 listed targets currently have backups, `all` drills those 3 and
# exits 0. A manifest entry whose env_file is missing is still a hard
# failure (that's a config mistake, not "not backed up yet").
#
# Env (single-target invocation; mode-specific, same names/semantics as
# this image's backup scripts, shared by the scratch instance and the
# live-target query):
#   ARCHIVE_DIR      Host path containing daily/ (default: ./backups)
#   BACKUP_PREFIX    Prefix used when the backup was written (default: mode name)
#   LIVE_TARGET      Live container name (db), volume name (tar), or base URL
#                    (qdrant) to compare against (required; LIVE_CONTAINER is
#                    accepted as an alias)
#   CONTAINER_ENGINE docker or podman (default: autodetect)
#   BACKUP_IMAGE     helper image for `tar` (needs `tar`; default ghcr.io/hem-inc/backup:1)
#   QDRANT_VERIFY_IMAGE  scratch image for `qdrant` (default qdrant/qdrant:v1.19.1 --
#                    override to match the version this deployment runs)
#   QDRANT_API_KEY   sent as `api-key` to the LIVE qdrant target only (optional)
#     postgres: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#     mariadb:  MARIADB_USER, MARIADB_PASSWORD, MARIADB_DB
#     mongo:    MONGO_USER, MONGO_PASSWORD, MONGO_AUTH_DB (optional)

ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then ENGINE=podman
    else echo "ERROR: neither docker nor podman found on PATH" >&2; exit 1
    fi
fi

BACKUP_IMAGE="${BACKUP_IMAGE:-ghcr.io/hem-inc/backup:1}"
QDRANT_VERIFY_IMAGE="${QDRANT_VERIFY_IMAGE:-qdrant/qdrant:v1.19.1}"

# Emergency net: if the script is interrupted mid-drill, clean up whatever
# scratch container the current verify_one call is using. Normal-path
# cleanup happens explicitly at the end of verify_one itself, per target.
CURRENT_SCRATCH=""
trap '[ -n "$CURRENT_SCRATCH" ] && "$ENGINE" rm -f "$CURRENT_SCRATCH" >/dev/null 2>&1; true' EXIT

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

# <prefix>_<collection>_<YYYYMMDD>.snapshot -> <collection>
# Fails (non-zero, no output) on a prefix mismatch or missing date suffix.
_qdrant_collection() {
    local base="${1##*/}" prefix="$2" stripped name
    stripped="${base#"${prefix}_"}"
    [ "$stripped" != "$base" ] || return 1
    name="${stripped%_????????.snapshot}"
    [ "$name" != "$stripped" ] || return 1
    printf '%s\n' "$name"
}

# Print "<collection>: <points_count>" for every collection at a base URL.
_qdrant_inventory() {
    local url="${1%/}" key="${2:-}"
    local -a h=()
    [ -n "$key" ] && h=(-H "api-key: $key")
    curl -fsS "${h[@]}" "${url}/collections" | jq -r '.result.collections[].name' | sort | while read -r c; do
        [ -n "$c" ] || continue
        printf '%s: %s\n' "$c" "$(curl -fsS "${h[@]}" "${url}/collections/${c}" | jq -r '.result.points_count')"
    done
}

# verify_one MODE ARCHIVE_DIR PREFIX LIVE_TARGET
# Returns: 0 pass, 2 skipped (no backup found for this target yet), 1 fail.
# Never exits the script itself.
verify_one() {
    local MODE="$1" ARCHIVE_DIR="$2" PREFIX="$3" LIVE_CONTAINER="$4" LIVE_TARGET="$4"
    local EXT IMAGE FILE FAIL=0

    case "$MODE" in
        postgres) EXT="sql.gz"; IMAGE="postgres:16-alpine" ;;
        mariadb)  EXT="sql.gz"; IMAGE="mariadb:10.11" ;;
        mongo)    EXT="archive.gz"; IMAGE="mongo:8.0" ;;
        tar)      EXT="tar.gz" ;;
        qdrant)   EXT="snapshot" ;;
        *) echo "ERROR: unsupported mode '$MODE' -- supported: postgres, mariadb, mongo, tar, qdrant" >&2; return 1 ;;
    esac

    # qdrant restores a *set* of files (one per collection) sharing the
    # latest date; every other mode restores a single latest file.
    if [ "$MODE" = "qdrant" ]; then
        local DATE SNAPS
        DATE=$(find "${ARCHIVE_DIR}/daily" -maxdepth 1 -name "${PREFIX}_*.snapshot" -type f 2>/dev/null \
            | sed -E 's/.*_([0-9]{8})\.snapshot$/\1/' | sort -r | head -n1)
        if [ -z "$DATE" ]; then
            echo "SKIP: no ${PREFIX}_*.snapshot backup found in ${ARCHIVE_DIR}/daily -- not backed up (yet)" >&2
            return 2
        fi
        mapfile -t SNAPS < <(find "${ARCHIVE_DIR}/daily" -maxdepth 1 -name "${PREFIX}_*_${DATE}.snapshot" -type f 2>/dev/null | sort)
        [ "${#SNAPS[@]}" -gt 0 ] || { echo "SKIP: no snapshots for date ${DATE}" >&2; return 2; }
        echo "--- using ${#SNAPS[@]} snapshot(s) from ${DATE} ---"

        local SCRATCH="restore-verify-qdrant-$$-${RANDOM}"
        CURRENT_SCRATCH="$SCRATCH"
        echo "--- starting scratch qdrant (${QDRANT_VERIFY_IMAGE}) ---"
        "$ENGINE" run -d --name "$SCRATCH" -p 127.0.0.1::6333 "$QDRANT_VERIFY_IMAGE" >/dev/null
        local hostport surl
        hostport=$("$ENGINE" port "$SCRATCH" 6333/tcp | head -n1 | sed 's/.*://')
        if [ -z "$hostport" ]; then
            echo "ERROR: could not resolve scratch qdrant host port" >&2
            FAIL=1
        else
            surl="http://127.0.0.1:${hostport}"
            timeout 30 sh -c "until curl -fsS '${surl}/healthz' >/dev/null 2>&1; do sleep 1; done" || FAIL=1

            local snap coll base
            for snap in "${SNAPS[@]}"; do
                base=$(basename "$snap")
                coll=$(_qdrant_collection "$base" "$PREFIX") || true
                if [ -z "${coll:-}" ]; then
                    echo "ERROR: cannot derive collection from $base with prefix '$PREFIX'" >&2
                    FAIL=1; continue
                fi
                echo "--- uploading $base -> collection '$coll' ---"
                curl -fsS -X POST -F "snapshot=@${snap}" \
                    "${surl}/collections/${coll}/snapshots/upload?priority=snapshot" >/dev/null || FAIL=1
            done

            echo "--- inventory: scratch (restored backup) ---"
            _qdrant_inventory "$surl" || FAIL=1
            echo "--- inventory: $LIVE_TARGET (live) ---"
            _qdrant_inventory "$LIVE_TARGET" "${QDRANT_API_KEY:-}" || FAIL=1
        fi

        "$ENGINE" rm -f "$SCRATCH" >/dev/null 2>&1 || true
        CURRENT_SCRATCH=""

        if [ "$FAIL" -eq 0 ]; then
            echo "=== RESTORE-VERIFY PASSED: ${#SNAPS[@]} snapshot(s) recovered into a fresh qdrant ==="
        else
            echo "=== RESTORE-VERIFY FAILED for $LIVE_TARGET (qdrant) -- see output above ==="
        fi
        return "$FAIL"
    fi

    FILE=$(find "${ARCHIVE_DIR}/daily" -maxdepth 1 -name "${PREFIX}_*.${EXT}" -type f 2>/dev/null | sort -r | head -n1)
    if [ -z "$FILE" ]; then
        echo "SKIP: no ${PREFIX}_*.${EXT} backup found in ${ARCHIVE_DIR}/daily -- not backed up (yet)" >&2
        return 2
    fi
    echo "--- using $FILE ---"

    if [ "$MODE" = "tar" ]; then
        local src_dir base
        src_dir=$(cd "$(dirname "$FILE")" && pwd)
        base=$(basename "$FILE")

        echo "--- extracting into scratch + inventory ---"
        "$ENGINE" run --rm --entrypoint sh -v "${src_dir}:/src:ro" "$BACKUP_IMAGE" -c "
            set -e
            mkdir /x
            tar xzf '/src/${base}' -C /x
            [ -n \"\$(find /x -mindepth 1 -print -quit)\" ] || { echo 'ERROR: extracted tree is empty'; exit 1; }
            printf 'files=%s bytes=%s\n' \"\$(find /x -type f | wc -l)\" \"\$(du -sb /x | cut -f1)\"
            find /x -mindepth 1 -maxdepth 1 | sed 's#^/x/#  #' | sort
        " || FAIL=1

        echo "--- inventory: $LIVE_TARGET (live volume) ---"
        "$ENGINE" run --rm --entrypoint sh -v "${LIVE_TARGET}:/data:ro" "$BACKUP_IMAGE" -c "
            printf 'files=%s bytes=%s\n' \"\$(find /data -type f | wc -l)\" \"\$(du -sb /data | cut -f1)\"
            find /data -mindepth 1 -maxdepth 1 | sed 's#^/data/#  #' | sort
        " || FAIL=1

        if [ "$FAIL" -eq 0 ]; then
            echo "=== RESTORE-VERIFY PASSED: $FILE extracted cleanly into a fresh tree ==="
        else
            echo "=== RESTORE-VERIFY FAILED for $LIVE_TARGET (tar) -- see output above ==="
        fi
        return "$FAIL"
    fi

    local SCRATCH="restore-verify-${MODE}-$$-${RANDOM}"
    CURRENT_SCRATCH="$SCRATCH"

    case "$MODE" in
        postgres)
            _require POSTGRES_USER || return 1
            _require POSTGRES_PASSWORD || return 1
            _require POSTGRES_DB || return 1

            echo "--- starting scratch postgres ---"
            "$ENGINE" run -d --name "$SCRATCH" \
                -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -e POSTGRES_DB="$POSTGRES_DB" \
                "$IMAGE" >/dev/null
            # pg_isready alone isn't enough here: the official postgres image
            # briefly accepts connections during its internal init-script
            # phase, then restarts before the real, final startup --
            # pg_isready can catch that brief window and report ready right
            # before the restart drops the connection (same gotcha
            # scripts/functional-test.sh hit). Retry an actual query instead
            # of trusting a single readiness probe.
            timeout 30 sh -c "until $ENGINE exec -e PGPASSWORD='$POSTGRES_PASSWORD' $SCRATCH psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tAc 'SELECT 1' >/dev/null 2>&1; do sleep 1; done"

            echo "--- restoring into scratch ---"
            gunzip -c "$FILE" | "$ENGINE" exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$SCRATCH" \
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q || FAIL=1

            local QUERY="SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1, 2;"
            echo "--- inventory: scratch (restored backup) ---"
            "$ENGINE" exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$SCRATCH" \
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$QUERY" || FAIL=1
            echo "--- inventory: $LIVE_CONTAINER (live) ---"
            "$ENGINE" exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$LIVE_CONTAINER" \
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$QUERY" || FAIL=1
            ;;

        mariadb)
            _require MARIADB_USER || return 1
            _require MARIADB_PASSWORD || return 1
            _require MARIADB_DB || return 1

            echo "--- starting scratch mariadb ---"
            "$ENGINE" run -d --name "$SCRATCH" \
                -e MARIADB_ROOT_PASSWORD="$MARIADB_PASSWORD" -e MARIADB_USER="$MARIADB_USER" \
                -e MARIADB_PASSWORD="$MARIADB_PASSWORD" -e MARIADB_DATABASE="$MARIADB_DB" \
                "$IMAGE" >/dev/null
            timeout 30 sh -c "until $ENGINE exec $SCRATCH healthcheck.sh --connect --innodb_initialized 2>/dev/null; do sleep 1; done"

            echo "--- restoring into scratch ---"
            gunzip -c "$FILE" | "$ENGINE" exec -i -e MYSQL_PWD="$MARIADB_PASSWORD" "$SCRATCH" \
                mariadb -u"$MARIADB_USER" "$MARIADB_DB" || FAIL=1

            local QUERY="SELECT table_schema, table_name, table_rows FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY 1, 2;"
            echo "--- inventory: scratch (restored backup) ---"
            "$ENGINE" exec -e MYSQL_PWD="$MARIADB_PASSWORD" "$SCRATCH" \
                mariadb -u"$MARIADB_USER" -e "$QUERY" || FAIL=1
            echo "--- inventory: $LIVE_CONTAINER (live) ---"
            "$ENGINE" exec -e MYSQL_PWD="$MARIADB_PASSWORD" "$LIVE_CONTAINER" \
                mariadb -u"$MARIADB_USER" -e "$QUERY" || FAIL=1
            ;;

        mongo)
            echo "--- starting scratch mongo ---"
            "$ENGINE" run -d --name "$SCRATCH" "$IMAGE" >/dev/null
            timeout 30 sh -c "until $ENGINE exec $SCRATCH mongosh --quiet --eval 'db.adminCommand(\"ping\")' >/dev/null 2>&1; do sleep 1; done"

            echo "--- restoring into scratch ---"
            set -- mongorestore --archive --gzip
            if [ -n "${MONGO_USER:-}" ]; then
                set -- "$@" --username="$MONGO_USER" --password="$MONGO_PASSWORD" --authenticationDatabase="${MONGO_AUTH_DB:-admin}"
            fi
            cat "$FILE" | "$ENGINE" exec -i "$SCRATCH" "$@" || FAIL=1

            local JS='db.getMongo().getDBNames().filter(n => !["admin","local","config"].includes(n)).forEach(n => { const d = db.getSiblingDB(n); d.getCollectionNames().forEach(c => print(n + "." + c + ": " + d.getCollection(c).countDocuments())); });'
            echo "--- inventory: scratch (restored backup) ---"
            "$ENGINE" exec "$SCRATCH" mongosh --quiet --eval "$JS" || FAIL=1
            echo "--- inventory: $LIVE_CONTAINER (live) ---"
            "$ENGINE" exec "$LIVE_CONTAINER" mongosh --quiet --eval "$JS" || FAIL=1
            ;;
    esac

    "$ENGINE" rm -f "$SCRATCH" >/dev/null 2>&1 || true
    CURRENT_SCRATCH=""

    if [ "$FAIL" -eq 0 ]; then
        echo "=== RESTORE-VERIFY PASSED: $FILE restored cleanly into a fresh $MODE instance ==="
    else
        echo "=== RESTORE-VERIFY FAILED for $LIVE_CONTAINER ($MODE) -- see output above ==="
    fi
    return "$FAIL"
}

if [ "${1:-}" = "all" ]; then
    TARGETS_FILE="${2:-./restore-targets.conf}"
    [ -f "$TARGETS_FILE" ] || { echo "ERROR: targets file not found: $TARGETS_FILE" >&2; exit 1; }

    FAIL=0
    RESULTS=""
    while read -r mode prefix archive_dir live_target env_file; do
        [ "${env_file:-}" = "-" ] && env_file=""
        echo "############################################"
        echo "### $live_target ($mode)"
        echo "############################################"
        _clear_creds
        if [ -n "${env_file:-}" ]; then
            if [ ! -f "$env_file" ]; then
                echo "ERROR: env_file not found: $env_file -- skipping $live_target" >&2
                RESULTS="${RESULTS}FAIL  $live_target ($mode) -- env_file not found\n"
                FAIL=1
                continue
            fi
            # shellcheck disable=SC1090
            . "$env_file"
        fi
        rc=0
        verify_one "$mode" "$archive_dir" "$prefix" "$live_target" || rc=$?
        case "$rc" in
            0) RESULTS="${RESULTS}PASS  $live_target ($mode)\n" ;;
            2) RESULTS="${RESULTS}SKIP  $live_target ($mode) -- not backed up\n" ;;
            *) RESULTS="${RESULTS}FAIL  $live_target ($mode)\n"; FAIL=1 ;;
        esac
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$TARGETS_FILE")

    echo "############################################"
    echo "### summary"
    echo "############################################"
    printf '%b' "$RESULTS"
    # A target with no backup yet is a SKIP, not a failure -- if only 3 of 5
    # manifest entries are actually being backed up today, drilling those 3
    # cleanly is a pass, not a partial failure. Only real restore/query
    # errors (or a manifest misconfiguration like a missing env_file) fail
    # the run.
    exit "$FAIL"
fi

MODE="${1:?Usage: $0 <postgres|mariadb|mongo|tar|qdrant>  |  $0 all [targets-file]}"
ARCHIVE_DIR="${ARCHIVE_DIR:-./backups}"
PREFIX="${BACKUP_PREFIX:-$MODE}"
LIVE_TARGET="${LIVE_TARGET:-${LIVE_CONTAINER:-}}"
[ -n "$LIVE_TARGET" ] || { echo "ERROR: LIVE_TARGET is required -- live container name (db), volume name (tar), or base URL (qdrant)" >&2; exit 1; }

verify_one "$MODE" "$ARCHIVE_DIR" "$PREFIX" "$LIVE_TARGET"
