#!/usr/bin/env bash
# =============================================================================
# JOB (Join Order Benchmark) Experiment Runner  (standalone)
#
# Runs 2 modes × N iterations: no_aqo (baseline) & with_aqo (semantic AQO)
# Results written to experiment/job/results/<timestamp>/
#
# Usage:  bash experiment/job/run.sh [iterations]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config (override via env or CLI arg) ─────────────────────────────────
DB="${JOB_DB:-imdb}"
BENCH="JOB"
ITERS="${1:-${ITERATIONS:-20}}"
QUERY_DIR="$SCRIPT_DIR/queries"

# ── Derived paths ────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

echo "══════════════════════════════════════════════════════════"
echo "  ${BENCH} experiment  |  DB: ${DB}  |  Iterations: ${ITERS}"
echo "  Results → ${RESULTS_DIR}"
echo "══════════════════════════════════════════════════════════"

/usr/bin/python3 "$EXPERIMENT_DIR/runner.py" \
    "$DB" "$QUERY_DIR" "$RESULTS_DIR" \
    --iterations "$ITERS" $FORCE_FLAG

/usr/bin/python3 "$EXPERIMENT_DIR/analyze.py" \
    "$RESULTS_DIR" --title "$BENCH"

echo ""
echo "Done. Results: $RESULTS_DIR"
