#!/usr/bin/env bash
# ============================================================
# 04-test-extension.sh
#
# Run test queries against the semantic_aqo extension
# and verify captured cardinality statistics.
# ============================================================
set -euo pipefail

# ---- Configuration ----
WORKSPACE_DIR="/workspaces/app"
PG_BIN="/usr/local/pgsql/bin"
PSQL="${PG_BIN}/psql"
TEST_DB="test"

export PATH="${PG_BIN}:${PATH}"

echo "========================================================"
echo "  semantic_aqo — Test & Verify Statistics"
echo "========================================================"

# ============================================================
# Step 1: Run test queries
# ============================================================
echo ""
echo "Step 1: Running sample queries to populate stats ..."

sudo -u postgres "${PSQL}" "${TEST_DB}" <<'SQL'

-- 1.1 Simple SELECT
SELECT * FROM pg_class LIMIT 10;

-- 1.2 WHERE clause
SELECT relname FROM pg_class WHERE relkind = 'r';

-- 1.3 JOIN
SELECT c.relname, n.nspname
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
LIMIT 20;

-- 1.4 Subquery
SELECT relname
FROM pg_class
WHERE oid IN (SELECT typrelid FROM pg_type WHERE typrelid <> 0);

-- 1.5 Aggregate
SELECT relkind, count(*)
FROM pg_class
GROUP BY relkind
ORDER BY count(*) DESC;

-- 1.6 Multi-table join with filter
SELECT c.relname, a.attname, t.typname
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid
JOIN pg_type t ON a.atttypid = t.oid
WHERE c.relkind = 'r'
  AND a.attnum > 0
LIMIT 30;

SQL

echo "✅ Test queries executed"

# ============================================================
# Step 2: Verify captured statistics
# ============================================================
echo ""
echo "Step 2: Verifying captured cardinality statistics ..."
echo ""

sudo -u postgres "${PSQL}" "${TEST_DB}" <<'SQL'

-- Show all captured stats
SELECT id,
       left(query_text, 80) AS query_short,
       est_rows,
       actual_rows,
       round(error_ratio::numeric, 4) AS error_ratio,
       captured_at
FROM semantic_aqo_stats
ORDER BY captured_at DESC;

-- Summary
SELECT count(*) AS total_captured,
       round(avg(error_ratio)::numeric, 4) AS avg_error_ratio,
       min(captured_at) AS first_capture,
       max(captured_at) AS last_capture
FROM semantic_aqo_stats;

SQL

echo ""
echo "========================================================"
echo "  ✅ semantic_aqo — Test & Verify COMPLETE"
echo "========================================================"
echo ""
echo "  Stats table  : SELECT * FROM semantic_aqo_stats;"
echo "  Summary view : SELECT * FROM semantic_aqo_stats_summary;"
echo "  Clear stats  : SELECT aqo_clear_stats();"
echo "  Disable      : SET semantic_aqo.enabled = off;"
echo ""
