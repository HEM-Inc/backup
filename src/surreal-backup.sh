#!/bin/sh
set -e
# SurrealDB backup via the HTTP /export endpoint — produces a logical SurrealQL
# dump (the same mechanism as SurrealDB's own `surreal export` CLI), then
# applies tiered retention.
#
# Fetched over HTTP rather than tarring the RocksDB storage directory directly:
# a live tar of RocksDB files carries real risk of capturing a torn write, and
# SurrealDB's own docs recommend logical exports over raw storage-engine copies.
#
# Mounts expected:
#   /archive — tiered backup archive (daily/, weekly/, monthly/)

SURREAL_URL="${SURREAL_URL:-http://surrealdb:8000}"
SURREAL_USER="${SURREAL_USER:?SURREAL_USER is required}"
SURREAL_PASSWORD="${SURREAL_PASSWORD:?SURREAL_PASSWORD is required}"
SURREAL_NAMESPACE="${SURREAL_NAMESPACE:?SURREAL_NAMESPACE is required}"
SURREAL_DATABASE="${SURREAL_DATABASE:?SURREAL_DATABASE is required}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-surreal}"

echo "Waiting for surrealdb at ${SURREAL_URL}..."
until curl -sf "${SURREAL_URL}/health" >/dev/null; do
    sleep 5
done

DEST="${ARCHIVE}/daily/${PREFIX}_$(date +%Y%m%d).surql.gz"

mkdir -p "${ARCHIVE}/daily"
echo "Exporting ${SURREAL_NAMESPACE}/${SURREAL_DATABASE} to ${DEST}..."
curl -sf -X GET \
    -u "${SURREAL_USER}:${SURREAL_PASSWORD}" \
    -H "Surreal-NS: ${SURREAL_NAMESPACE}" \
    -H "Surreal-DB: ${SURREAL_DATABASE}" \
    -H "Accept: application/json" \
    "${SURREAL_URL}/export" \
    | gzip > "$DEST"

/usr/local/bin/retention.sh "$DEST"
