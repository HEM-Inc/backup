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

# Fresh file every start: a fixed path left over from a previous run (restart
# keeps the container's writable layer) is owned by backup after the chown
# below, and root can't reopen it in sticky /tmp when CAP_DAC_OVERRIDE is
# dropped or fs.protected_regular is set -- "Permission denied" restart loop.
CRONTAB_FILE=$(mktemp /tmp/backup.crontab.XXXXXX)
printf '%s /usr/local/bin/backup.sh\n' "$SCHEDULE" > "$CRONTAB_FILE"

# DRILL_SCHEDULE is optional -- a second, independent cron line running the
# lightweight integrity check (drill.sh) against the most recent backup.
# Unset means no drill runs at all.
if [ -n "${DRILL_SCHEDULE:-}" ]; then
    case "$DRILL_SCHEDULE" in
        *"$nl"*)
            printf 'ERROR: DRILL_SCHEDULE must not contain newlines\n' >&2
            exit 1 ;;
    esac
    printf '%s /usr/local/bin/drill.sh\n' "$DRILL_SCHEDULE" >> "$CRONTAB_FILE"
fi

chown backup:backup "$CRONTAB_FILE"

exec gosu backup supercronic "$CRONTAB_FILE"
