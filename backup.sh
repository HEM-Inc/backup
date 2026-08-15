#!/bin/sh
set -e

BACKUP_MODE="${BACKUP_MODE:-tar}"

case "$BACKUP_MODE" in
    qdrant)   exec /usr/local/bin/qd-snapshot.sh ;;
    tar)      exec /usr/local/bin/tar-backup.sh ;;
    postgres) exec /usr/local/bin/pg-backup.sh ;;
    mariadb)  exec /usr/local/bin/mariadb-backup.sh ;;
    surreal)  exec /usr/local/bin/surreal-backup.sh ;;
    *)
        printf 'ERROR: Unknown BACKUP_MODE "%s". Valid: qdrant, tar, postgres, mariadb, surreal\n' "$BACKUP_MODE" >&2
        exit 1
        ;;
esac
