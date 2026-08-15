#!/bin/sh
set -e

SCHEDULE="${BACKUP_SCHEDULE:?BACKUP_SCHEDULE is required (e.g. '0 3 * * *')}"

nl='
'
case "$SCHEDULE" in
    *"$nl"*)
        printf 'ERROR: BACKUP_SCHEDULE must not contain newlines\n' >&2
        exit 1 ;;
esac

# Ensure archive dirs exist and are owned by the backup user before dropping privileges
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
mkdir -p "${ARCHIVE}/daily" "${ARCHIVE}/weekly" "${ARCHIVE}/monthly"
chown -R backup:backup "${ARCHIVE}"

CRONTAB_FILE=/tmp/backup.crontab
printf '%s /usr/local/bin/backup.sh\n' "$SCHEDULE" > "$CRONTAB_FILE"
chown backup:backup "$CRONTAB_FILE"

exec su-exec backup supercronic "$CRONTAB_FILE"
