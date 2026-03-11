#!/usr/bin/env bash
set -e

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

echo ""
echo "=================================="
echo "TPC-H Setup Completed"
echo "Database: $DB"
echo "=================================="