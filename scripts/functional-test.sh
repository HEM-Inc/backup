#!/usr/bin/env bash
set -euo pipefail
# Functional test suite for the backup image -- proves each mode actually
# produces a restorable backup, not just that the image builds. Run via
# scripts/functional-test.sh locally, or by .github/workflows/test.yml in
# CI. Requires Docker. Not meant to run against production -- fixtures are
# ephemeral, throwaway services, never real data.
#
# Covers postgres/mariadb/mongo/tar/qdrant -- every restore path the
# operator scripts offer. surreal is not covered (see
# docker-compose.test.yml's comment).

cd "$(dirname "$0")/.."

PROJECT=backup-functest
COMPOSE="docker compose -p $PROJECT -f docker-compose.test.yml"
NETWORK="${PROJECT}_default"
QDRANT_IMAGE=qdrant/qdrant:v1.19.1

cleanup() {
    echo "--- cleaning up ---"
    $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
    docker rm -f functest-pg-restore functest-mariadb-restore functest-mongo-restore \
        functest-qdrant-restore >/dev/null 2>&1 || true
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
# tar: a plain directory is a fine proxy for a mounted volume -- it
# exercises tar-backup.sh + retention + the extract-based restore path.
$COMPOSE exec -T backup sh -c 'mkdir -p /data && echo tar-canary > /data/canary.txt'
# qdrant: wait for the distroless fixture (no shell of its own) via curl
# from the backup container, then create a collection + one point.
$COMPOSE exec -T backup sh -c '
    until curl -fsS http://qdrant:6333/healthz >/dev/null 2>&1; do sleep 1; done
    curl -fsS -X PUT http://qdrant:6333/collections/canary \
        -H "Content-Type: application/json" \
        -d "{\"vectors\":{\"size\":4,\"distance\":\"Dot\"}}" >/dev/null
    curl -fsS -X PUT "http://qdrant:6333/collections/canary/points?wait=true" \
        -H "Content-Type: application/json" \
        -d "{\"points\":[{\"id\":1,\"vector\":[0.1,0.2,0.3,0.4]}]}" >/dev/null
'

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
run_backup tar -e BACKUP_SOURCE=/data -e BACKUP_PREFIX=tartest
run_backup qdrant -e QDRANT_URL=http://qdrant:6333 -e BACKUP_PREFIX=qdranttest

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

echo "--- restore-verify: tar ---"
TAR_FILE=$($COMPOSE exec -T backup sh -c 'ls -t /archive/daily/tartest_*.tar.gz | head -1' | tr -d '\r')
RESULT=$($COMPOSE exec -T backup sh -c "rm -rf /tmp/trestore && mkdir /tmp/trestore && tar xzf '$TAR_FILE' -C /tmp/trestore && cat /tmp/trestore/canary.txt" | tr -d '\r')
[ "$RESULT" = "tar-canary" ] && echo "PASS: tar restore verified" || { echo "FAIL: tar restore returned '$RESULT'"; FAIL=1; }

echo "--- restore-verify: qdrant ---"
docker run -d --name functest-qdrant-restore --network "$NETWORK" "$QDRANT_IMAGE" >/dev/null
QD_FILE=$($COMPOSE exec -T backup sh -c 'ls -t /archive/daily/qdranttest_canary_*.snapshot | head -1' | tr -d '\r')
$COMPOSE exec -T backup sh -c "
    until curl -fsS http://functest-qdrant-restore:6333/healthz >/dev/null 2>&1; do sleep 1; done
    curl -fsS -X POST -F 'snapshot=@$QD_FILE' \
        'http://functest-qdrant-restore:6333/collections/canary/snapshots/upload?priority=snapshot' >/dev/null
"
RESULT=$($COMPOSE exec -T backup sh -c 'curl -fsS http://functest-qdrant-restore:6333/collections/canary | jq -r .result.points_count' | tr -d '\r')
[ "$RESULT" = "1" ] && echo "PASS: qdrant restore verified" || { echo "FAIL: qdrant restore returned '$RESULT'"; FAIL=1; }

echo "--- drill.sh sanity check ---"
for p in pgtest tartest qdranttest; do
    $COMPOSE exec -T -e BACKUP_PREFIX="$p" backup gosu backup /usr/local/bin/drill.sh \
        || { echo "FAIL: drill.sh failed for $p"; FAIL=1; }
done

if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL FUNCTIONAL TESTS PASSED ==="
else
    echo "=== FUNCTIONAL TESTS FAILED ==="
fi
exit "$FAIL"
