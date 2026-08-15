#!/bin/sh
set -e
# Generic volume backup — tars a mounted volume and writes to the daily archive,
# then applies tiered retention.

SOURCE="${BACKUP_SOURCE:-/data}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-backup}"

[ -d "$SOURCE" ] || { printf 'ERROR: BACKUP_SOURCE "%s" is not a directory\n' "$SOURCE" >&2; exit 1; }

DEST="${ARCHIVE}/daily/${PREFIX}_$(date +%Y%m%d).tar.gz"

mkdir -p "${ARCHIVE}/daily"
echo "Backing up ${SOURCE} to ${DEST}..."
tar -czf "$DEST" -C "${SOURCE}" .

/usr/local/bin/retention.sh "$DEST"
