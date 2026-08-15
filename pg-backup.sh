#!/bin/sh
set -e
# Postgres backup via pg_dump — waits for the database to be ready,
# dumps and compresses to the daily archive, then applies tiered retention.

POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:?POSTGRES_USER is required}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
POSTGRES_DB="${POSTGRES_DB:?POSTGRES_DB is required}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-postgres}"

PGPASSFILE=$(mktemp)
printf '%s:%s:%s:%s:%s\n' \
    "$POSTGRES_HOST" "$POSTGRES_PORT" "$POSTGRES_DB" "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
    > "$PGPASSFILE"
chmod 600 "$PGPASSFILE"
export PGPASSFILE
trap 'rm -f "$PGPASSFILE"' EXIT

echo "Waiting for postgres at ${POSTGRES_HOST}:${POSTGRES_PORT}..."
until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -q; do
    sleep 5
done

DEST="${ARCHIVE}/daily/${PREFIX}_$(date +%Y%m%d).sql.gz"

mkdir -p "${ARCHIVE}/daily"
echo "Dumping ${POSTGRES_DB} to ${DEST}..."
pg_dump -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    | gzip > "$DEST"

/usr/local/bin/retention.sh "$DEST"
