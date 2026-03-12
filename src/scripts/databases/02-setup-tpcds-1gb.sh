#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

echo "12. Generate query seeds (all templates x 20 seeds)"

QUERY_DIR="$REPO_ROOT/experiment/tpcds/queries"
TMPQUERY_DIR=$(mktemp -d /tmp/tpcds-queries-XXXXXX)
chmod 755 "$TMPQUERY_DIR"
mkdir -p "$QUERY_DIR"

# 20 diverse random seeds
SEEDS=(42 17 99 7 1337 2024 55 123 456 789 321 654 987 111 222 333 444 555 666 777)

# dsqgen is built into $WORK_DIR/tools/ during step 5 above
for tpl in "$WORK_DIR"/query_templates/query[0-9]*.tpl; do
    [ -f "$tpl" ] || continue
    qbase=$(basename "$tpl" .tpl)
    qnum="${qbase#query}"
    # skip non-numeric variants (e.g. 14a, 23a, 39a — included via their main template)
    [[ "$qnum" =~ ^[0-9]+$ ]] || continue
    for seed in "${SEEDS[@]}"; do
        fname="q$(printf '%02d' "$qnum")_s${seed}.sql"
        (
            cd "$WORK_DIR/tools"
            ./dsqgen \
                -template "../query_templates/${qbase}.tpl" \
                -directory ../query_templates \
                -rngseed "$seed" \
                -scale "$SCALE" \
                -dialect netezza \
                -filter Y \
                2>/dev/null
        ) | grep -v "^-- " > "$TMPQUERY_DIR/$fname" || true
        # remove empty files (template failed to generate)
        [ -s "$TMPQUERY_DIR/$fname" ] || rm -f "$TMPQUERY_DIR/$fname"
    done
    echo "  Q$qnum done (${#SEEDS[@]} variants)"
done

_generated=$(ls "$TMPQUERY_DIR"/*.sql 2>/dev/null | wc -l)
chmod 644 "$TMPQUERY_DIR"/*.sql 2>/dev/null || true
echo "  Generated $_generated query files → validating in temp dir"

echo "13. Validate queries (drop errors and queries > 60s)"
echo "    (60s timeout per query — standard for SF=1 industry benchmarks)"

# NOTE: stdout is redirected to /dev/null during validation to avoid
# capturing huge result sets in bash variables (which caused OOM crashes).
# Only stderr is captured for error messages.
_valid=0; _err=0; _slow=0
_total=$(ls "$TMPQUERY_DIR"/*.sql 2>/dev/null | wc -l)
_i=0
for _qfile in "$TMPQUERY_DIR"/*.sql; do
    [ -f "$_qfile" ] || continue
    _i=$((_i+1))
    _qname=$(basename "$_qfile")
    printf "  [%d/%d] %-36s" "$_i" "$_total" "$_qname"

    # Two-layer timeout protection:
    #   Layer 1: PostgreSQL statement_timeout (55s) — query cancels itself cleanly
    #   Layer 2: timeout --kill-after=5 (60s SIGTERM, 65s SIGKILL) — hard kill fallback
    _stderr_file=$(mktemp)
    _t0=$SECONDS
    sudo -u postgres timeout --kill-after=5 60 \
        /usr/local/pgsql/bin/psql -d "$DB" -v ON_ERROR_STOP=1 -X -q \
        -c "SET statement_timeout = '55s';" \
        -f "$_qfile" \
        > /dev/null 2>"$_stderr_file"
    _rc=$?
    _elapsed=$(( SECONDS - _t0 ))

    # rc=124: timeout SIGTERM, rc=137: timeout SIGKILL
    # Also check stderr for statement_timeout cancellation
    if [ $_rc -eq 0 ]; then
        printf "OK          %3ds\n" "$_elapsed"
        cp "$_qfile" "$QUERY_DIR/$_qname"
        _valid=$((_valid+1))
    elif [ $_rc -eq 124 ] || [ $_rc -eq 137 ] || grep -q "canceling statement due to statement timeout" "$_stderr_file" 2>/dev/null; then
        printf "SKIP (>55s) %3ds\n" "$_elapsed"
        _slow=$((_slow+1))
    else
        _reason=$(grep -i 'error' "$_stderr_file" | head -1 | cut -c1-60)
        printf "SKIP %-20s %3ds\n" "(${_reason})" "$_elapsed"
        _err=$((_err+1))
    fi
    rm -f "$_stderr_file"
done

rm -rf "$TMPQUERY_DIR"

echo ""
echo "  Kept: $_valid | Skipped (error): $_err | Skipped (timeout): $_slow"
echo "  Final query count: $(ls "$QUERY_DIR"/*.sql 2>/dev/null | wc -l)"

echo ""
echo "=================================="
echo "TPC-DS Setup Completed"
echo "Database: $DB"
echo "=================================="
