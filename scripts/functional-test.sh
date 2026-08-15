#!/usr/bin/env bash
set -euo pipefail
# Functional test suite for the backup image -- proves each mode actually
# produces a restorable backup, not just that the image builds. Run via
# scripts/functional-test.sh locally, or by .github/workflows/test.yml in
# CI. Requires Docker. Not meant to run against production -- fixtures are
# ephemeral, throwaway databases, never real data.
#
# Scoped to postgres/mariadb/mongo -- see docker-compose.test.yml's comment
# for why qdrant/tar/surreal aren't covered here.

cd "$(dirname "$0")/.."

PROJECT=backup-functest
COMPOSE="docker compose -p $PROJECT -f docker-compose.test.yml"
NETWORK="${PROJECT}_default"

cleanup() {
    echo "--- cleaning up ---"
    $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f functest-pg-restore functest-mariadb-restore functest-mongo-restore >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- starting fixtures ---"
$COMPOSE up -d --build --wait

echo "--- seeding test data ---"
$COMPOSE exec -T postgres psql -U testuser -d testdb -c \
    "CREATE TABLE canary (id serial primary key, note text); INSERT INTO canary (note) VALUES ('postgres-canary');"
$COMPOSE exec -T mariadb mariadb -utestuser -ptestpass testdb -e \
    "CREATE TABLE canary (id INT AUTO_INCREMENT PRIMARY KEY, note TEXT); INSERT INTO canary (note) VALUES ('mariadb-canary');"
$COMPOSE exec -T mongo mongosh --quiet --eval \
    'db.canary.insertOne({note: "mongo-canary"})' testdb

FAIL=0

run_backup() {
    local mode="$1"; shift
    echo "--- running $mode backup ---"
    $COMPOSE exec -T -e "BACKUP_MODE=$mode" "$@" backup sh -c \
        'mkdir -p /archive/daily /archive/weekly /archive/monthly && chown -R backup:backup /archive && gosu backup /usr/local/bin/backup.sh'
}

run_backup postgres -e POSTGRES_HOST=postgres -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=testdb -e BACKUP_PREFIX=pgtest
run_backup mariadb -e MARIADB_HOST=mariadb -e MARIADB_USER=testuser -e MARIADB_PASSWORD=testpass -e MARIADB_DB=testdb -e BACKUP_PREFIX=mariadbtest
run_backup mongo -e MONGO_HOST=mongo -e BACKUP_PREFIX=mongotest

echo "--- verifying archives exist ---"
$COMPOSE exec -T backup sh -c 'ls -la /archive/daily'

echo "--- restore-verify: postgres ---"
docker run -d --name functest-pg-restore --network "$NETWORK" \
    -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=testdb \
    postgres:16-alpine >/dev/null
# pg_isready alone isn't enough here: the official postgres image briefly
# accepts connections during its internal init-script phase, then restarts
# before the real, final startup -- pg_isready can catch that brief window
# and report ready right before the restart drops the connection. Retry an
# actual query instead of trusting a single readiness probe.
timeout 30 sh -c 'until docker exec functest-pg-restore psql -U testuser -d testdb -tAc "SELECT 1" >/dev/null 2>&1; do sleep 1; done'
PG_FILE=$($COMPOSE exec -T backup sh -c 'ls -t /archive/daily/pgtest_*.sql.gz | head -1' | tr -d '\r')
$COMPOSE exec -T backup sh -c "gunzip -c '$PG_FILE'" | docker exec -i functest-pg-restore psql -U testuser -d testdb -q
RESULT=$(docker exec functest-pg-restore psql -U testuser -d testdb -tAc "SELECT note FROM canary")
[ "$RESULT" = "postgres-canary" ] && echo "PASS: postgres restore verified" || { echo "FAIL: postgres restore returned '$RESULT'"; FAIL=1; }

echo "--- restore-verify: mariadb ---"
docker run -d --name functest-mariadb-restore --network "$NETWORK" \
    -e MARIADB_ROOT_PASSWORD=rootpass -e MARIADB_USER=testuser -e MARIADB_PASSWORD=testpass -e MARIADB_DATABASE=testdb \
    mariadb:10.11 >/dev/null
timeout 30 sh -c 'until docker exec functest-mariadb-restore healthcheck.sh --connect --innodb_initialized 2>/dev/null; do sleep 1; done'
MARIADB_FILE=$($COMPOSE exec -T backup sh -c 'ls -t /archive/daily/mariadbtest_*.sql.gz | head -1' | tr -d '\r')
$COMPOSE exec -T backup sh -c "gunzip -c '$MARIADB_FILE'" | docker exec -i functest-mariadb-restore mariadb -utestuser -ptestpass testdb
RESULT=$(docker exec functest-mariadb-restore mariadb -utestuser -ptestpass testdb -N -e "SELECT note FROM canary")
[ "$RESULT" = "mariadb-canary" ] && echo "PASS: mariadb restore verified" || { echo "FAIL: mariadb restore returned '$RESULT'"; FAIL=1; }

echo "--- restore-verify: mongo ---"
docker run -d --name functest-mongo-restore --network "$NETWORK" mongo:8.0 >/dev/null
timeout 30 sh -c 'until docker exec functest-mongo-restore mongosh --quiet --eval "db.adminCommand(\"ping\")" >/dev/null 2>&1; do sleep 1; done'
MONGO_FILE=$($COMPOSE exec -T backup sh -c 'ls -t /archive/daily/mongotest_*.archive.gz | head -1' | tr -d '\r')
$COMPOSE exec -T backup sh -c "cat '$MONGO_FILE'" | docker exec -i functest-mongo-restore mongorestore --archive --gzip
RESULT=$(docker exec functest-mongo-restore mongosh --quiet --eval 'print(db.canary.findOne().note)' testdb)
[ "$RESULT" = "mongo-canary" ] && echo "PASS: mongo restore verified" || { echo "FAIL: mongo restore returned '$RESULT'"; FAIL=1; }

echo "--- drill.sh sanity check ---"
$COMPOSE exec -T -e BACKUP_PREFIX=pgtest backup gosu backup /usr/local/bin/drill.sh || { echo "FAIL: drill.sh failed for pgtest"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL FUNCTIONAL TESTS PASSED ==="
else
    echo "=== FUNCTIONAL TESTS FAILED ==="
fi
exit "$FAIL"
