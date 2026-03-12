#!/usr/bin/env bash
set -e

DB="imdb"
WORK_DIR="/tmp/job-build"
DATA_DIR="/tmp/job-data"
ARCHIVE_NAME="imdb.tgz"
ARCHIVE_URL="http://event.cwi.nl/da/job/imdb.tgz"

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
CREATEDB="sudo -u postgres /usr/local/pgsql/bin/createdb"

echo "=================================="
echo "JOB / IMDB Setup"
echo "=================================="

echo "1. Install dependencies"
sudo apt update
sudo apt install -y build-essential git wget tar

echo "2. Prepare directories"
rm -rf "$WORK_DIR" "$DATA_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$DATA_DIR"

echo "3. Clone join-order-benchmark repo"
git clone https://github.com/gregrahn/join-order-benchmark.git "$WORK_DIR"

echo "4. Download IMDB dataset archive"
wget -c -O "$WORK_DIR/$ARCHIVE_NAME" "$ARCHIVE_URL"

echo "5. Extract dataset"
tar -xzf "$WORK_DIR/$ARCHIVE_NAME" -C "$DATA_DIR"

echo "6. Recreate database"

$PSQL -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$DB' AND pid <> pg_backend_pid();
" || true

$PSQL -c "DROP DATABASE IF EXISTS $DB;"
$CREATEDB $DB

echo "7. PostgreSQL bulk load optimizations"

$PSQL $DB <<SQL
SET synchronous_commit = OFF;
SET maintenance_work_mem = '2GB';
SET work_mem = '256MB';
SQL

echo "8. Create schema"
$PSQL $DB -f "$WORK_DIR/schema.sql"

echo "9. Fix trailing delimiter"

for f in $DATA_DIR/*.csv
do
  sed -i 's/|$//' "$f"
done

echo "10. Load data"

for f in $DATA_DIR/*.csv
do
    table=$(basename "$f" .csv)

    echo "Loading $table..."

    $PSQL $DB -c "\copy $table FROM '$f' CSV"
done

echo "11. Create foreign-key indexes (after load for speed)"

if [ -f "$WORK_DIR/fkindexes.sql" ]; then
    $PSQL $DB -f "$WORK_DIR/fkindexes.sql"
fi

echo "12. Analyze tables"
$PSQL $DB -c "ANALYZE;"

echo ""
echo "=================================="
echo "JOB / IMDB Setup Completed"
echo "Database: $DB"
echo "=================================="