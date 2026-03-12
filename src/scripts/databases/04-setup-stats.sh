#!/usr/bin/env bash
set -e

DB="stats"
WORK_DIR="/tmp/stats-build"

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
CREATEDB="sudo -u postgres /usr/local/pgsql/bin/createdb"

echo "=================================="
echo "STATS Setup"
echo "=================================="

echo "1. Install dependencies"
sudo apt update
sudo apt install -y build-essential git

echo "2. Prepare directories"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "3. Clone End-to-End-CardEst-Benchmark repo"
git clone https://github.com/Nathaniel-Han/End-to-End-CardEst-Benchmark.git "$WORK_DIR"

echo "4. Recreate database"

$PSQL -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$DB' AND pid <> pg_backend_pid();
" || true

$PSQL -c "DROP DATABASE IF EXISTS $DB;"
$CREATEDB $DB

echo "5. Create schema"
cd "$WORK_DIR"
$PSQL $DB -f "$WORK_DIR/datasets/stats_simplified/stats.sql"

echo "6. Load data"
$PSQL $DB -f "$WORK_DIR/scripts/sql/stats_load.sql"

echo "7. Create indexes"
$PSQL $DB -f "$WORK_DIR/scripts/sql/stats_index.sql"

echo "8. Analyze tables"
$PSQL $DB -c "ANALYZE;"

echo ""
echo "=================================="
echo "STATS Setup Completed"
echo "Database: $DB"
echo "=================================="