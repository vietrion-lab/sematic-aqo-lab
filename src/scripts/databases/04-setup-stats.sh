#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

if [ "${SKIP_QUERY_SETUP:-0}" = "1" ]; then
    echo "9-10. Skipping query extraction/validation (SKIP_QUERY_SETUP=1)"
else

echo "9. Extract STATS-CEB queries"

QUERY_DIR="$REPO_ROOT/experiment/stats/queries"
mkdir -p "$QUERY_DIR"

# STATS-CEB workload: each line is "true_card||SELECT ...;"
# Split into individual SQL files: q001.sql, q002.sql, ...
_idx=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    _idx=$((_idx+1))
    _fname="q$(printf '%03d' "$_idx").sql"
    # Strip the true cardinality prefix (everything before ||)
    echo "${line#*||}" > "$QUERY_DIR/$_fname"
done < "$WORK_DIR/workloads/stats_CEB/stats_CEB.sql"

echo "  Extracted $_idx queries"

echo "10. Validate queries (drop errors and queries > 55s)"
echo "    (55s statement_timeout + 60s hard kill)"

CHECKPOINT_FILE="$QUERY_DIR/.checkpoint"

# Load checkpoint — skip previously validated queries
declare -A _done
if [ -f "$CHECKPOINT_FILE" ]; then
    while IFS= read -r line; do
        _done["$line"]=1
    done < "$CHECKPOINT_FILE"
    echo "  Resuming from checkpoint (${#_done[@]} queries already processed)"
fi

_valid=0; _err=0; _slow=0; _skip=0
_total=$(ls "$QUERY_DIR"/*.sql 2>/dev/null | wc -l)
_i=0
for _qfile in "$QUERY_DIR"/*.sql; do
    [ -f "$_qfile" ] || continue
    _i=$((_i+1))
    _qname=$(basename "$_qfile")

    # Checkpoint: skip already-processed queries
    if [[ -v "_done[$_qname]" ]]; then
        _skip=$((_skip+1))
        _valid=$((_valid+1))
        continue
    fi

    printf "  [%d/%d] %-36s" "$_i" "$_total" "$_qname"

    _stderr_file=$(mktemp)
    _t0=$SECONDS
    _rc=0
    sudo -u postgres timeout --kill-after=5 60 \
        /usr/local/pgsql/bin/psql -d "$DB" -v ON_ERROR_STOP=1 -X -q \
        -c "SET statement_timeout = '55s';" \
        -f "$_qfile" \
        > /dev/null 2>"$_stderr_file" || _rc=$?
    _elapsed=$(( SECONDS - _t0 ))

    if [ $_rc -eq 0 ]; then
        printf "OK          %3ds\n" "$_elapsed"
        _valid=$((_valid+1))
    elif [ $_rc -eq 124 ] || [ $_rc -eq 137 ] || grep -q "canceling statement due to statement timeout" "$_stderr_file" 2>/dev/null; then
        printf "SKIP (>55s) %3ds\n" "$_elapsed"
        rm -f "$_qfile"
        _slow=$((_slow+1))
    else
        _reason=$(grep -i 'error' "$_stderr_file" | head -1 | cut -c1-60)
        printf "SKIP %-20s %3ds\n" "(${_reason})" "$_elapsed"
        rm -f "$_qfile"
        _err=$((_err+1))
    fi
    rm -f "$_stderr_file"

    echo "$_qname" >> "$CHECKPOINT_FILE"
done

rm -f "$CHECKPOINT_FILE"

if [ $_skip -gt 0 ]; then
    echo "  (skipped $_skip previously validated queries)"
fi
echo ""
echo "  Kept: $_valid | Skipped (error): $_err | Skipped (timeout): $_slow"
echo "  Final query count: $(ls "$QUERY_DIR"/*.sql 2>/dev/null | wc -l)"

fi # end SKIP_QUERY_SETUP guard

echo ""
echo "=================================="
echo "STATS Setup Completed"
echo "Database: $DB"
echo "=================================="