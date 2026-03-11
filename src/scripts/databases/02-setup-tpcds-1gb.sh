#!/usr/bin/env bash
set -e

DB="tpcds"
WORK_DIR="/tmp/tpcds-build"
DATA_DIR="/tmp/tpcds-data"
SCALE=1

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
CREATEDB="sudo -u postgres /usr/local/pgsql/bin/createdb"

echo "=================================="
echo "TPC-DS Setup (SF=$SCALE)"
echo "=================================="

echo "1. Install dependencies"
sudo apt update
sudo apt install -y build-essential git

echo "2. Prepare directories"
rm -rf $WORK_DIR $DATA_DIR
mkdir -p $WORK_DIR
mkdir -p $DATA_DIR

echo "3. Download tpcds-kit"
git clone https://github.com/gregrahn/tpcds-kit.git $WORK_DIR

echo "4. Fix GCC >= 10 build issue"
sed -i 's/-g -Wall/-g -Wall -fcommon/' $WORK_DIR/tools/makefile

echo "5. Build dsdgen"
cd $WORK_DIR/tools
make

echo "6. Generate TPC-DS data"
./dsdgen -scale $SCALE -force -dir $DATA_DIR

echo "7. Fix trailing delimiter"
for f in $DATA_DIR/*.dat
do
  sed -i 's/|$//' "$f"
done

echo "8. Recreate database"

$PSQL -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname='$DB' AND pid <> pg_backend_pid();
" || true

$PSQL -c "DROP DATABASE IF EXISTS $DB;"
$CREATEDB $DB

echo "9. Create schema"
$PSQL $DB -f $WORK_DIR/tools/tpcds.sql

echo "10. Load data"

for f in $DATA_DIR/*.dat
do
  table=$(basename "$f" .dat)
  echo "Loading $table"

  $PSQL $DB \
  -c "\copy $table FROM '$f' DELIMITER '|' NULL ''"
done

echo "11. Analyze tables"
$PSQL $DB -c "ANALYZE;"

echo ""
echo "=================================="
echo "TPC-DS Setup Completed"
echo "Database: $DB"
echo "=================================="
