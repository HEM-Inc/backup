#!/bin/sh
set -e
# Lightweight backup integrity check -- validates the most recent backup
# file(s) are structurally intact (tar/gzip integrity), without restoring
# into a live database. Deliberately does NOT spin up a second database
# engine or restore real data: it needs to be safe to run unattended on
# resource-constrained hardware (e.g. an 8GB-RAM IPC), where standing up a
# scratch database for a real restore-and-verify test is not. See the
# README's "Drill testing" section for the full reasoning.
#
# Real restore-and-verify testing (does a genuine restore actually work,
# not just "is the file well-formed") lives in this repo's own CI
# (.github/workflows/), against ephemeral fixtures with no such constraint
# -- not here.
#
# Runs as a second, independent cron schedule (DRILL_SCHEDULE) alongside
# BACKUP_SCHEDULE -- see entrypoint.sh.

ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-backup}"

# Most recent date suffix among this prefix's daily backups. qdrant mode
# writes one file per collection sharing the same date suffix, so this
# checks every file from the latest date, not just a single newest file.
LATEST_DATE=$(find "${ARCHIVE}/daily" -maxdepth 1 -name "${PREFIX}*" -type f 2>/dev/null \
    | sed -E 's/.*_([0-9]{8})\.[^.]+(\.gz)?$/\1/' \
    | sort -r | head -n1)

if [ -z "$LATEST_DATE" ]; then
    echo "DRILL FAIL: no backup files found for prefix '${PREFIX}' in ${ARCHIVE}/daily"
    exit 1
fi

FAIL=0
FOUND=0
for f in "${ARCHIVE}/daily/${PREFIX}"*"_${LATEST_DATE}."*; do
    [ -e "$f" ] || continue
    FOUND=$((FOUND + 1))
    case "$f" in
        *.tar.gz)
            if tar -tzf "$f" >/dev/null 2>&1; then
                echo "DRILL PASS: $(basename "$f") -- tar+gzip integrity OK"
            else
                echo "DRILL FAIL: $(basename "$f") -- tar+gzip integrity check failed"
                FAIL=1
            fi
            ;;
        *.gz)
            if gunzip -t "$f" 2>/dev/null; then
                echo "DRILL PASS: $(basename "$f") -- gzip integrity OK"
            else
                echo "DRILL FAIL: $(basename "$f") -- gzip integrity check failed"
                FAIL=1
            fi
            ;;
        *.snapshot)
            # Qdrant's raw snapshot format -- no portable integrity check
            # without Qdrant's own tooling; confirm it's non-empty only.
            if [ -s "$f" ]; then
                echo "DRILL PASS: $(basename "$f") -- non-empty ($(wc -c < "$f") bytes)"
            else
                echo "DRILL FAIL: $(basename "$f") -- empty file"
                FAIL=1
            fi
            ;;
        *)
            echo "DRILL SKIP: $(basename "$f") -- no integrity check defined for this extension"
            ;;
    esac
done

if [ "$FOUND" -eq 0 ]; then
    echo "DRILL FAIL: no backup files matched date ${LATEST_DATE}"
    exit 1
fi

exit "$FAIL"
