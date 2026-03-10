#!/bin/bash
#
# 04-test-node-context.sh
#
# Test script for the AQO Node Context Extractor feature.
# Tests single-table scans, two-table joins, and multi-table joins,
# then logs all collected node context data to a timestamped log file.
#
set -e

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
PG_CTL="sudo -u postgres /usr/local/pgsql/bin/pg_ctl"
PG_DATA="/usr/local/pgsql/data"
AQO_DIR="/workspaces/app/postgresql-15.15/contrib/aqo"
LOG_DIR="/workspaces/app/logs"
LOG_FILE="${LOG_DIR}/nce-test-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

# Tee all output to both terminal and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  AQO Node Context Extractor - Test Script"
echo "  $(date)"
echo "============================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Recreate AQO extension (apply new schema)
# ------------------------------------------------------------------
echo "[1/5] Recreating AQO extension with new schema..."
$PSQL -c "DROP EXTENSION IF EXISTS aqo CASCADE;" 2>/dev/null || true
$PSQL -c "CREATE EXTENSION aqo;"
echo "  -> Extension recreated."
echo ""

# ------------------------------------------------------------------
# Step 2: Create test tables with sample data
# ------------------------------------------------------------------
echo "[2/5] Creating test tables and sample data..."
$PSQL <<'SQL'
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- Users table
CREATE TABLE users (
    id      SERIAL PRIMARY KEY,
    name    TEXT NOT NULL,
    age     INTEGER NOT NULL,
    city    TEXT,
    tier    TEXT DEFAULT 'standard'
);

-- Products table
CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(10,2) NOT NULL
);

-- Orders table
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER REFERENCES users(id),
    total       NUMERIC(10,2),
    status      TEXT,
    created_at  DATE DEFAULT CURRENT_DATE
);

-- Order items (line items)
CREATE TABLE order_items (
    id          SERIAL PRIMARY KEY,
    order_id    INTEGER REFERENCES orders(id),
    product_id  INTEGER REFERENCES products(id),
    quantity    INTEGER NOT NULL DEFAULT 1,
    unit_price  NUMERIC(10,2) NOT NULL
);

-- Populate users (10K)
INSERT INTO users (name, age, city, tier)
SELECT
    'user_' || i,
    20 + (i % 60),
    (ARRAY['Hanoi','HCMC','Danang','Haiphong','Cantho'])[1 + (i % 5)],
    (ARRAY['standard','premium','vip'])[1 + (i % 3)]
FROM generate_series(1, 10000) AS i;

-- Populate products (500)
INSERT INTO products (name, category, price)
SELECT
    'product_' || i,
    (ARRAY['Electronics','Books','Clothing','Food','Sports'])[1 + (i % 5)],
    (10 + random() * 490)::numeric(10,2)
FROM generate_series(1, 500) AS i;

-- Populate orders (50K)
INSERT INTO orders (user_id, total, status, created_at)
SELECT
    (i % 10000) + 1,
    (random() * 1000)::numeric(10,2),
    (ARRAY['pending','paid','shipped','delivered','cancelled'])[1 + (i % 5)],
    CURRENT_DATE - (i % 365)
FROM generate_series(1, 50000) AS i;

-- Populate order_items (150K)
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    (i % 50000) + 1,
    (i % 500) + 1,
    1 + (i % 5),
    (10 + random() * 200)::numeric(10,2)
FROM generate_series(1, 150000) AS i;

ANALYZE;
SQL
echo "  -> Tables created: users(10K), products(500), orders(50K), order_items(150K)."
echo ""

# ------------------------------------------------------------------
# Step 3: Run test queries with NCE enabled
# ------------------------------------------------------------------
echo "[3/5] Running test queries with NCE enabled..."
echo ""

$PSQL <<'SQL'
SET aqo.mode = 'learn';
SET aqo.nce_enabled = true;
SET aqo.join_threshold = 0;
SELECT aqo_node_context_reset();

-- =====================================================================
-- SINGLE TABLE QUERIES
-- =====================================================================

\echo '--- [Single Table 1] users: age range + city filter ---'
EXPLAIN ANALYZE
SELECT * FROM users WHERE age >= 40 AND city = 'Hanoi';

\echo ''
\echo '--- [Single Table 2] orders: status + amount range ---'
EXPLAIN ANALYZE
SELECT * FROM orders WHERE status = 'paid' AND total > 500;

\echo ''
\echo '--- [Single Table 3] products: category + price range ---'
EXPLAIN ANALYZE
SELECT * FROM products WHERE category = 'Electronics' AND price BETWEEN 50 AND 200;

\echo ''
\echo '--- [Single Table 4] users: tier + age (premium VIPs over 50) ---'
EXPLAIN ANALYZE
SELECT * FROM users WHERE tier = 'vip' AND age > 50;

-- =====================================================================
-- TWO-TABLE JOIN QUERIES
-- =====================================================================

\echo ''
\echo '--- [Two-Table Join 1] users JOIN orders: top spenders from Hanoi ---'
EXPLAIN ANALYZE
SELECT u.name, SUM(o.total) AS spent
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE u.city = 'Hanoi' AND o.status = 'delivered'
GROUP BY u.name
ORDER BY spent DESC
LIMIT 10;

\echo ''
\echo '--- [Two-Table Join 2] orders JOIN order_items: large orders ---'
EXPLAIN ANALYZE
SELECT o.id, o.status, COUNT(oi.id) AS items, SUM(oi.unit_price * oi.quantity) AS line_total
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.total > 200
GROUP BY o.id, o.status
HAVING COUNT(oi.id) > 2
LIMIT 20;

\echo ''
\echo '--- [Two-Table Join 3] users JOIN orders: subquery (IN) ---'
EXPLAIN ANALYZE
SELECT * FROM orders
WHERE user_id IN (SELECT id FROM users WHERE city = 'Danang' AND age < 30);

-- =====================================================================
-- MULTI-TABLE JOIN QUERIES (3+ tables)
-- =====================================================================

\echo ''
\echo '--- [Multi Join 1] users + orders + order_items: full chain ---'
EXPLAIN ANALYZE
SELECT u.city, COUNT(DISTINCT o.id) AS orders, SUM(oi.quantity) AS total_items
FROM users u
JOIN orders o ON o.user_id = u.id
JOIN order_items oi ON oi.order_id = o.id
WHERE u.age BETWEEN 25 AND 35
  AND o.status IN ('paid', 'shipped')
GROUP BY u.city
ORDER BY total_items DESC;

\echo ''
\echo '--- [Multi Join 2] users + orders + order_items + products: 4-table ---'
EXPLAIN ANALYZE
SELECT u.city, p.category,
       COUNT(*) AS purchase_count,
       ROUND(AVG(oi.unit_price)::numeric, 2) AS avg_price
FROM users u
JOIN orders o ON o.user_id = u.id
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON p.id = oi.product_id
WHERE u.tier = 'premium'
  AND o.created_at >= CURRENT_DATE - 180
  AND p.price > 100
GROUP BY u.city, p.category
ORDER BY purchase_count DESC
LIMIT 20;

\echo ''
\echo '--- [Multi Join 3] 3-table with aggregation + HAVING ---'
EXPLAIN ANALYZE
SELECT u.name, p.category, SUM(oi.quantity) AS qty
FROM users u
JOIN orders o ON o.user_id = u.id
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON p.id = oi.product_id
WHERE u.city = 'HCMC'
  AND o.status = 'delivered'
GROUP BY u.name, p.category
HAVING SUM(oi.quantity) > 5
ORDER BY qty DESC
LIMIT 15;

-- =====================================================================
-- Run key queries a second time (AQO learns from repetition)
-- =====================================================================
\echo ''
\echo '--- [Repeat] Single table: users WHERE age >= 40 AND city = Hanoi ---'
EXPLAIN ANALYZE
SELECT * FROM users WHERE age >= 40 AND city = 'Hanoi';

\echo ''
\echo '--- [Repeat] Two-table join: top spenders from Hanoi ---'
EXPLAIN ANALYZE
SELECT u.name, SUM(o.total) AS spent
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE u.city = 'Hanoi' AND o.status = 'delivered'
GROUP BY u.name
ORDER BY spent DESC
LIMIT 10;

\echo ''
\echo '--- [Repeat] 4-table join: city x category purchase stats ---'
EXPLAIN ANALYZE
SELECT u.city, p.category,
       COUNT(*) AS purchase_count,
       ROUND(AVG(oi.unit_price)::numeric, 2) AS avg_price
FROM users u
JOIN orders o ON o.user_id = u.id
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON p.id = oi.product_id
WHERE u.tier = 'premium'
  AND o.created_at >= CURRENT_DATE - 180
  AND p.price > 100
GROUP BY u.city, p.category
ORDER BY purchase_count DESC
LIMIT 20;
SQL
echo ""
echo "  -> All test queries executed."
echo ""

# ------------------------------------------------------------------
# Step 4: Display extracted node context data
# ------------------------------------------------------------------
echo "[4/5] Displaying extracted node context data..."
echo ""

echo "============================================"
echo "  SINGLE TABLE NODE CONTEXTS"
echo "============================================"
$PSQL <<'SQL'
\x on
SELECT
    id,
    node_type,
    CASE WHEN length(clause_text) > 120
         THEN left(clause_text, 120) || '...'
         ELSE clause_text
    END AS clause_text,
    selectivities,
    round(estimated_cardinality::numeric, 2) AS est_card,
    round(actual_cardinality::numeric, 2) AS actual_card,
    relations
FROM aqo_node_context
WHERE array_length(relations, 1) = 1
  AND node_type IN ('SeqScan', 'IndexScan', 'IndexOnlyScan', 'BitmapHeapScan')
ORDER BY id;
\x off
SQL

echo ""
echo "============================================"
echo "  JOIN NODE CONTEXTS"
echo "============================================"
$PSQL <<'SQL'
\x on
SELECT
    id,
    node_type,
    join_type,
    CASE WHEN length(clause_text) > 120
         THEN left(clause_text, 120) || '...'
         ELSE clause_text
    END AS clause_text,
    selectivities,
    round(estimated_cardinality::numeric, 2) AS est_card,
    round(actual_cardinality::numeric, 2) AS actual_card,
    relations
FROM aqo_node_context
WHERE node_type IN ('HashJoin', 'MergeJoin', 'NestLoop')
ORDER BY id;
\x off
SQL

echo ""
echo "============================================"
echo "  AGGREGATE / LIMIT / OTHER NODES"
echo "============================================"
$PSQL <<'SQL'
\x on
SELECT
    id,
    node_type,
    round(estimated_cardinality::numeric, 2) AS est_card,
    round(actual_cardinality::numeric, 2) AS actual_card,
    relations
FROM aqo_node_context
WHERE node_type NOT IN ('SeqScan', 'IndexScan', 'IndexOnlyScan',
                        'BitmapHeapScan', 'HashJoin', 'MergeJoin', 'NestLoop')
ORDER BY id;
\x off
SQL

# ------------------------------------------------------------------
# Step 5: Summary statistics
# ------------------------------------------------------------------
echo ""
echo "============================================"
echo "  SUMMARY BY NODE TYPE"
echo "============================================"
$PSQL <<'SQL'
SELECT
    node_type,
    COUNT(*) AS cnt,
    ROUND(AVG(estimated_cardinality)::numeric, 1) AS avg_est,
    ROUND(AVG(actual_cardinality)::numeric, 1) AS avg_actual,
    ROUND(AVG(
        CASE WHEN actual_cardinality > 0 AND estimated_cardinality > 0
             THEN ABS(ln(estimated_cardinality) - ln(actual_cardinality))
             ELSE NULL
        END
    )::numeric, 4) AS avg_q_error
FROM aqo_node_context
GROUP BY node_type
ORDER BY cnt DESC;
SQL

echo ""
echo "============================================"
echo "  SUMMARY BY NUMBER OF RELATIONS"
echo "============================================"
$PSQL <<'SQL'
SELECT
    COALESCE(array_length(relations, 1), 0) AS num_rels,
    COUNT(*) AS cnt,
    COUNT(*) FILTER (WHERE clause_text <> '' AND clause_text NOT LIKE '{%') AS readable_clauses,
    COUNT(*) FILTER (WHERE clause_text LIKE '{%') AS nodetostring_clauses,
    COUNT(*) FILTER (WHERE clause_text = '' OR clause_text IS NULL) AS no_clause
FROM aqo_node_context
GROUP BY COALESCE(array_length(relations, 1), 0)
ORDER BY num_rels;
SQL

echo ""
echo "============================================"
echo "  TOKENIZED CLAUSE_TEXT (all non-empty)"
echo "============================================"
$PSQL <<'SQL'
SELECT
    id,
    node_type,
    clause_text,
    relations
FROM aqo_node_context
WHERE clause_text <> ''
ORDER BY id;
SQL

echo ""
echo "============================================"
echo "  TOKEN USAGE SUMMARY"
echo "============================================"
$PSQL <<'SQL'
SELECT
    'Total clauses'                                              AS metric,
    COUNT(*) FILTER (WHERE clause_text <> '')                    AS value
FROM aqo_node_context
UNION ALL
SELECT
    'With <NUM>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<NUM>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <STR>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<STR>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <DATE>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<DATE>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <TIMESTAMP>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<TIMESTAMP>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <BOOL_TRUE>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<BOOL_TRUE>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <BOOL_FALSE>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<BOOL_FALSE>%')
FROM aqo_node_context
UNION ALL
SELECT
    'With <NULL>',
    COUNT(*) FILTER (WHERE clause_text LIKE '%<NULL>%')
FROM aqo_node_context
UNION ALL
SELECT
    'Join-only (no tokens)',
    COUNT(*) FILTER (WHERE clause_text <> ''
                       AND clause_text NOT LIKE '%<%')
FROM aqo_node_context;
SQL

echo ""
echo "============================================"
echo "  DISTINCT CLAUSE PATTERNS"
echo "============================================"
$PSQL <<'SQL'
SELECT
    clause_text AS pattern,
    COUNT(*) AS occurrences,
    array_agg(DISTINCT node_type) AS node_types
FROM aqo_node_context
WHERE clause_text <> ''
GROUP BY clause_text
ORDER BY occurrences DESC, pattern;
SQL

echo ""
TOTAL=$($PSQL -t -c "SELECT COUNT(*) FROM aqo_node_context;")
echo "Total entries collected: $TOTAL"
echo ""
echo "============================================"
echo "  Test Complete!"
echo "  Log saved to: $LOG_FILE"
echo "============================================"
