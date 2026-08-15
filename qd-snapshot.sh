#!/bin/sh
set -e
# Qdrant-specific backup — creates a snapshot of each collection via the Qdrant
# REST API, archives each into the tiered retention structure, then prunes each
# collection's internal snapshot list.
#
# Per-collection, not full-storage: full-storage snapshots (POST /snapshots) can
# only be restored via a CLI flag at Qdrant startup — there is no REST API for
# restoring them. Per-collection snapshots support REST API recovery
# (PUT /collections/{name}/snapshots/recover) against a live, running instance,
# so backups are taken per-collection to keep restore possible without downtime.
#
# The created snapshot is fetched via HTTP download (GET .../snapshots/{name}),
# not read directly off a shared filesystem mount: Qdrant creates the file (and
# its collection-named subdirectory) as its own container user, which this
# container's unprivileged backup user can't read directly.
#
# Mounts expected:
#   /archive — tiered backup archive (daily/, weekly/, monthly/)

QDRANT_URL="${QDRANT_URL:-http://qdrant:6333}"
ARCHIVE="${BACKUP_ARCHIVE:-/archive}"
PREFIX="${BACKUP_PREFIX:-qdrant}"
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"

COLLECTIONS_FILE=$(mktemp)
trap 'rm -f "$COLLECTIONS_FILE"' EXIT

curl -sf "${QDRANT_URL}/collections" | jq -r '.result.collections[].name' > "$COLLECTIONS_FILE"
[ -s "$COLLECTIONS_FILE" ] || { echo "ERROR: No collections found (or could not list collections)"; exit 1; }

while IFS= read -r COLLECTION; do
    [ -n "$COLLECTION" ] || continue

    case "$COLLECTION" in
        */* | *..*) printf 'ERROR: unexpected collection name: %s\n' "$COLLECTION" >&2; exit 1 ;;
    esac

    echo "Creating snapshot for collection: ${COLLECTION}..."
    RESPONSE=$(curl -sf -X POST "${QDRANT_URL}/collections/${COLLECTION}/snapshots")
    SNAP_NAME=$(echo "$RESPONSE" | jq -r '.result.name')

    [ -n "$SNAP_NAME" ] && [ "$SNAP_NAME" != "null" ] \
        || { echo "ERROR: Could not read snapshot name for ${COLLECTION}"; exit 1; }

    case "$SNAP_NAME" in
        */* | *..*) printf 'ERROR: unexpected snapshot name: %s\n' "$SNAP_NAME" >&2; exit 1 ;;
    esac

    echo "Snapshot created: ${SNAP_NAME}"

    COLL_PREFIX="${PREFIX}_${COLLECTION}"
    DEST="${ARCHIVE}/daily/${COLL_PREFIX}_$(date +%Y%m%d).snapshot"
    mkdir -p "${ARCHIVE}/daily"
    # Download over HTTP rather than cp from the shared snapshots mount: Qdrant
    # creates the file (and its collection-named subdirectory) as its own
    # container user, which the unprivileged backup user can't read directly.
    curl -sf -o "$DEST" "${QDRANT_URL}/collections/${COLLECTION}/snapshots/${SNAP_NAME}" \
        || { echo "ERROR: Failed to download snapshot ${SNAP_NAME}"; rm -f "$DEST"; exit 1; }
    echo "Archived to: ${DEST}"

    # Shared tiered retention (weekly / monthly promotion + daily pruning), scoped per collection
    BACKUP_ARCHIVE="$ARCHIVE" BACKUP_PREFIX="$COLL_PREFIX" \
        BACKUP_KEEP_DAILY="$KEEP_DAILY" \
        BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-}" \
        BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-}" \
        /usr/local/bin/retention.sh "$DEST"

    # Prune this collection's internal snapshot list — keep KEEP_DAILY most recent
    echo "Pruning Qdrant internal snapshot list for ${COLLECTION} (keeping ${KEEP_DAILY})..."
    curl -sf "${QDRANT_URL}/collections/${COLLECTION}/snapshots" \
        | jq -r '.result | sort_by(.creation_time) | .[].name' \
        | head -n "-${KEEP_DAILY}" \
        | while read -r name; do
              [ -n "$name" ] || continue
              case "$name" in
                  */* | *..*) echo "Skipping unsafe snapshot name: ${name}"; continue ;;
              esac
              curl -sf -X DELETE "${QDRANT_URL}/collections/${COLLECTION}/snapshots/${name}" >/dev/null
              echo "Deleted from Qdrant: ${name}"
          done

    echo "---"
done < "$COLLECTIONS_FILE"
