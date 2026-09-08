#!/bin/sh
set -e
# Shared daily/weekly/monthly retention logic.
# $1 = full path to the newly created file, already written to ${BACKUP_ARCHIVE}/daily/
#
# Env: BACKUP_ARCHIVE, BACKUP_PREFIX, BACKUP_KEEP_DAILY,
#      BACKUP_KEEP_WEEKLY (unset = disabled), BACKUP_KEEP_MONTHLY (unset = disabled)

ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-backup}"
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-}"

case "$PREFIX" in
    *[*?\[\]/]*) printf 'ERROR: BACKUP_PREFIX contains invalid characters: %s\n' "$PREFIX" >&2; exit 1 ;;
esac

_validate_int() {
    case "$1" in
        ''|*[!0-9]*) printf 'ERROR: %s must be a positive integer, got: "%s"\n' "$2" "$1" >&2; exit 1 ;;
    esac
}
_validate_int "$KEEP_DAILY" "BACKUP_KEEP_DAILY"
[ -n "$KEEP_WEEKLY" ]  && _validate_int "$KEEP_WEEKLY"  "BACKUP_KEEP_WEEKLY"
[ -n "$KEEP_MONTHLY" ] && _validate_int "$KEEP_MONTHLY" "BACKUP_KEEP_MONTHLY"

NEW_FILE="$1"

# Extract extension from the daily filename (e.g. sql.gz, tar.gz, snapshot)
BASENAME=$(basename "$NEW_FILE")
EXT="${BASENAME#${PREFIX}_????????.}"

# Weekly promotion — runs on Sunday (date +%w = 0)
# Filename format: PREFIX_YYYYWW.ext  (ISO year + week via %G%V — handles year-boundary correctly)
if [ -n "$KEEP_WEEKLY" ] && [ "$(date +%w)" = "0" ]; then
    mkdir -p "${ARCHIVE}/weekly"
    cp "$NEW_FILE" "${ARCHIVE}/weekly/${PREFIX}_$(date +%G%V).${EXT}"
    echo "Weekly backup saved (keeping ${KEEP_WEEKLY} weeks)."
    find "${ARCHIVE}/weekly" -maxdepth 1 -name "${PREFIX}_*" -type f \
        | sort -r \
        | tail -n "+$((KEEP_WEEKLY + 1))" \
        | while read -r f; do
              rm -f "$f"
              echo "Pruned weekly: $(basename "$f")"
          done
fi

# Monthly promotion — runs on the last day of the month
# Filename format: PREFIX_YYYYMM.ext
if [ -n "$KEEP_MONTHLY" ]; then
    TOMORROW=$(date -d @$(($(date +%s) + 86400)) +%d)
    if [ "$TOMORROW" = "01" ]; then
        mkdir -p "${ARCHIVE}/monthly"
        cp "$NEW_FILE" "${ARCHIVE}/monthly/${PREFIX}_$(date +%Y%m).${EXT}"
        echo "Monthly backup saved (keeping ${KEEP_MONTHLY} months)."
        find "${ARCHIVE}/monthly" -maxdepth 1 -name "${PREFIX}_*" -type f \
            | sort -r \
            | tail -n "+$((KEEP_MONTHLY + 1))" \
            | while read -r f; do
                  rm -f "$f"
                  echo "Pruned monthly: $(basename "$f")"
              done
    fi
fi

# Prune daily — sort by filename (YYYYMMDD), keep KEEP_DAILY most recent
find "${ARCHIVE}/daily" -maxdepth 1 -name "${PREFIX}_*" -type f \
    | sort -r \
    | tail -n "+$((KEEP_DAILY + 1))" \
    | while read -r f; do
          rm -f "$f"
          echo "Pruned daily: $(basename "$f")"
      done
