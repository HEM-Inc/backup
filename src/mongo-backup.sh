#!/bin/sh
set -e
# MongoDB backup via mongodump --archive --gzip -- waits for the database to
# be ready, dumps a single gzip-compressed archive to the daily archive,
# then applies tiered retention.
#
# Mounts expected:
#   /archive — tiered backup archive (daily/, weekly/, monthly/)

MONGO_HOST="${MONGO_HOST:-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"
MONGO_DB="${MONGO_DB:-}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-mongodb}"

echo "Waiting for mongodb at ${MONGO_HOST}:${MONGO_PORT}..."
until nc -z "$MONGO_HOST" "$MONGO_PORT" 2>/dev/null; do
    sleep 5
done

DEST="${ARCHIVE}/daily/${PREFIX}_$(date +%Y%m%d).archive.gz"
mkdir -p "${ARCHIVE}/daily"

set -- mongodump --host="$MONGO_HOST" --port="$MONGO_PORT" --archive="$DEST" --gzip

if [ -n "$MONGO_USER" ]; then
    # Write credentials to a temp config file rather than the command line,
    # same reasoning as mariadb-backup.sh's --defaults-extra-file.
    CONFIG_FILE=$(mktemp)
    printf 'authenticationDatabase: %s\nusername: %s\npassword: %s\n' \
        "$MONGO_AUTH_DB" "$MONGO_USER" "$MONGO_PASSWORD" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    trap 'rm -f "$CONFIG_FILE"' EXIT
    set -- "$@" --config="$CONFIG_FILE"
fi

if [ -n "$MONGO_DB" ]; then
    echo "Dumping database ${MONGO_DB} to ${DEST}..."
    set -- "$@" --db="$MONGO_DB"
else
    echo "Dumping all databases to ${DEST}..."
fi

"$@"

/usr/local/bin/retention.sh "$DEST"
