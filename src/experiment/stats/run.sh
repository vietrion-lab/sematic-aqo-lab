#!/usr/bin/env bash
# =============================================================================
# STATS-CEB Experiment Runner  (standalone, with checkpoint/resume)
#
# Runs 2 modes × N iterations: no_aqo (baseline) & with_aqo (semantic AQO)
# Results written to experiment/stats/results/
# Completed phases are skipped on re-run.  Use --force to re-run everything.
#
# Usage:  bash experiment/stats/run.sh [iterations] [--force]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config (override via env or CLI arg) ─────────────────────────────────
DB="${STATS_DB:-stats}"
BENCH="STATS"
QUERY_DIR="$SCRIPT_DIR/queries"

# ── Parse args ───────────────────────────────────────────────────────────
ITERS="${ITERATIONS:-20}"
FORCE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_FLAG="--force" ;;
        *)       ITERS="$arg" ;;
    esac
done
[ -n "${FORCE:-}" ] && FORCE_FLAG="--force"

# ── Stable results dir (checkpoint-friendly) ─────────────────────────────
RESULTS_DIR="$SCRIPT_DIR/results"
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
