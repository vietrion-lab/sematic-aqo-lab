#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

for f in "$DATA_DIR"/*.csv
do
  sed -i 's/|$//' "$f"
done

echo "10. Load data"

# IMDB CSV files from the CWI archive use backslash-escaped quotes (\")
# instead of the standard CSV double-quote escaping ("").
# Must specify ESCAPE '\' to parse correctly.
for f in "$DATA_DIR"/*.csv
do
    table=$(basename "$f" .csv)

    echo "Loading $table..."

    $PSQL $DB -c "\copy $table FROM '$f' CSV ESCAPE '\\'"
done

echo "11. Create foreign-key indexes (after load for speed)"

if [ -f "$WORK_DIR/fkindexes.sql" ]; then
    $PSQL $DB -f "$WORK_DIR/fkindexes.sql"
fi

echo "12. Analyze tables"
$PSQL $DB -c "ANALYZE;"

if [ "${SKIP_QUERY_SETUP:-0}" = "1" ]; then
    echo "13-14. Skipping query copy/validation (SKIP_QUERY_SETUP=1)"
else

echo "13. Copy JOB queries"

QUERY_DIR="$REPO_ROOT/experiment/job/queries"
mkdir -p "$QUERY_DIR"

# JOB has 113 hand-written queries (1a.sql – 33c.sql) in the repo root
_copied=0
for _qfile in "$WORK_DIR"/[0-9]*.sql; do
    [ -f "$_qfile" ] || continue
    cp "$_qfile" "$QUERY_DIR/$(basename "$_qfile")"
    _copied=$((_copied+1))
done
echo "  Copied $_copied query files"

echo "14. Validate queries (drop errors and queries > 55s)"
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

    # Two-layer timeout protection:
    #   Layer 1: PostgreSQL statement_timeout (55s) — query cancels itself cleanly
    #   Layer 2: timeout --kill-after=5 (60s SIGTERM, 65s SIGKILL) — hard kill fallback
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

    # Record to checkpoint
    echo "$_qname" >> "$CHECKPOINT_FILE"
done

# Clean up checkpoint when all done
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
echo "JOB / IMDB Setup Completed"
echo "Database: $DB"
echo "=================================="