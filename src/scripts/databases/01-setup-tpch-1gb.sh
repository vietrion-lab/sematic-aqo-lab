#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DB="tpch"
WORK_DIR="/tmp/tpch-build"
DATA_DIR="/tmp/tpch-data"

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
CREATEDB="sudo -u postgres /usr/local/pgsql/bin/createdb"

echo "=================================="
echo "TPC-H 1GB Setup"
echo "=================================="

echo "1. Install dependencies"
sudo apt update
sudo apt install -y build-essential git

echo "2. Prepare directories"
rm -rf $WORK_DIR $DATA_DIR
mkdir -p $WORK_DIR
mkdir -p $DATA_DIR

echo "3. Download tpch-dbgen"
git clone https://github.com/electrum/tpch-dbgen.git $WORK_DIR

echo "4. Build dbgen"
cd $WORK_DIR
make

echo "5. Generate data (SF=1)"
./dbgen -s 1 -f

echo "6. Move data files"
mv *.tbl $DATA_DIR

echo "7. Fix trailing delimiter in TPC-H files"
for f in $DATA_DIR/*.tbl; do
  sed -i 's/|$//' "$f"
done

echo "8. Create database"
$CREATEDB $DB 2>/dev/null || {
    $PSQL -c "DROP DATABASE IF EXISTS $DB;"
    $CREATEDB $DB
}

echo "9. Create schema"

$PSQL $DB <<'SQL'

CREATE TABLE region (
r_regionkey int,
r_name char(25),
r_comment varchar(152)
);

CREATE TABLE nation (
n_nationkey int,
n_name char(25),
n_regionkey int,
n_comment varchar(152)
);

CREATE TABLE part (
p_partkey int,
p_name varchar(55),
p_mfgr char(25),
p_brand char(10),
p_type varchar(25),
p_size int,
p_container char(10),
p_retailprice decimal,
p_comment varchar(23)
);

CREATE TABLE supplier (
s_suppkey int,
s_name char(25),
s_address varchar(40),
s_nationkey int,
s_phone char(15),
s_acctbal decimal,
s_comment varchar(101)
);

CREATE TABLE partsupp (
ps_partkey int,
ps_suppkey int,
ps_availqty int,
ps_supplycost decimal,
ps_comment varchar(199)
);

CREATE TABLE customer (
c_custkey int,
c_name varchar(25),
c_address varchar(40),
c_nationkey int,
c_phone char(15),
c_acctbal decimal,
c_mktsegment char(10),
c_comment varchar(117)
);

CREATE TABLE orders (
o_orderkey bigint,
o_custkey int,
o_orderstatus char(1),
o_totalprice decimal,
o_orderdate date,
o_orderpriority char(15),
o_clerk char(15),
o_shippriority int,
o_comment varchar(79)
);

CREATE TABLE lineitem (
l_orderkey bigint,
l_partkey int,
l_suppkey int,
l_linenumber int,
l_quantity decimal,
l_extendedprice decimal,
l_discount decimal,
l_tax decimal,
l_returnflag char(1),
l_linestatus char(1),
l_shipdate date,
l_commitdate date,
l_receiptdate date,
l_shipinstruct char(25),
l_shipmode char(10),
l_comment varchar(44)
);

SQL

echo "10. Load data"

for t in region nation part supplier partsupp customer orders lineitem
do
    echo "Loading $t..."
    $PSQL $DB -c "\copy $t FROM '$DATA_DIR/$t.tbl' DELIMITER '|'"
done

echo "11. Analyze tables"

$PSQL $DB -c "ANALYZE;"

echo "12. Generate query seeds (all templates x 20 seeds)"

QUERY_DIR="$REPO_ROOT/experiment/tpch/queries"
TMPQUERY_DIR=$(mktemp -d /tmp/tpch-queries-XXXXXX)
chmod 755 "$TMPQUERY_DIR"
mkdir -p "$QUERY_DIR"

# 20 diverse random seeds
SEEDS=(42 17 99 7 1337 2024 55 123 456 789 321 654 987 111 222 333 444 555 666 777)

# All 22 TPC-H query templates
for tmpl in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
    for seed in "${SEEDS[@]}"; do
        fname="q$(printf '%02d' "$tmpl")_s${seed}.sql"
        (
            cd "$WORK_DIR"
            DSS_QUERY=./queries ./qgen -s 1 -r "$seed" "$tmpl" 2>/dev/null
        ) \
        | grep -v "^--" \
        | grep -v "^where rownum" \
        | sed "s/interval '\([0-9]*\)' day ([0-9]\+)/interval '\1 days'/g" \
        | sed '/^[[:space:]]*$/d' \
        > "$TMPQUERY_DIR/$fname"
        # remove empty files
        [ -s "$TMPQUERY_DIR/$fname" ] || rm -f "$TMPQUERY_DIR/$fname"
    done
    echo "  Q$tmpl done (${#SEEDS[@]} variants)"
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
echo "TPC-H Setup Completed"
echo "Database: $DB"
echo "=================================="