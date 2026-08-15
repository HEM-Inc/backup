#!/bin/sh
set -e
# MariaDB/MySQL backup via mariadb-dump — waits for the database to be ready,
# dumps and compresses to the daily archive, then applies tiered retention.
#
# Mounts expected:
#   /archive — tiered backup archive (daily/, weekly/, monthly/)

MARIADB_HOST="${MARIADB_HOST:-mariadb}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_USER="${MARIADB_USER:?MARIADB_USER is required}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:?MARIADB_PASSWORD is required}"
MARIADB_DB="${MARIADB_DB:-}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-mariadb}"

# Write a temp defaults-extra-file so the password doesn't appear in the
# process list or get passed on the command line.  Must be the first argument
# to mariadb-dump / mariadb-admin.
CNF_FILE=$(mktemp)
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
    "$MARIADB_HOST" "$MARIADB_PORT" "$MARIADB_USER" "$MARIADB_PASSWORD" \
    > "$CNF_FILE"
chmod 600 "$CNF_FILE"
trap 'rm -f "$CNF_FILE"' EXIT

echo "Waiting for mariadb at ${MARIADB_HOST}:${MARIADB_PORT}..."
until mariadb-admin --defaults-extra-file="$CNF_FILE" ping --silent 2>/dev/null; do
    sleep 5
done

DEST="${ARCHIVE}/daily/${PREFIX}_$(date +%Y%m%d).sql.gz"
mkdir -p "${ARCHIVE}/daily"

if [ -n "$MARIADB_DB" ]; then
    echo "Dumping database ${MARIADB_DB} to ${DEST}..."
    mariadb-dump --defaults-extra-file="$CNF_FILE" \
        --single-transaction --add-drop-table \
        "$MARIADB_DB" | gzip > "$DEST"
else
    echo "Dumping all databases to ${DEST}..."
    mariadb-dump --defaults-extra-file="$CNF_FILE" \
        --single-transaction --add-drop-table \
        --all-databases | gzip > "$DEST"
fi

/usr/local/bin/retention.sh "$DEST"