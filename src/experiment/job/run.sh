#!/usr/bin/env bash
# =============================================================================
# JOB Experiment Runner  (3-way: no_aqo | standard_aqo | semantic_aqo)
#
# Usage:
#   bash experiment/job/run.sh [iterations] [--force] [--modes=MODE1,MODE2,...]
#
# Modes (default: all three):
#   no_aqo          PostgreSQL default optimizer
#   standard_aqo    postgrespro/aqo stable15
#   semantic_aqo    semantic-aqo (w2v embeddings)
#
# Requires 04-standard-aqo-build.sh to have been run at least once for
# standard_aqo mode. Set SWITCH_AQO_SKIP=1 to skip AQO variant switching.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config ────────────────────────────────────────────────────────────────────
DB="${JOB_DB:-imdb}"
BENCH="JOB"
QUERY_DIR="$SCRIPT_DIR/queries"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

# ── Parse args ────────────────────────────────────────────────────────────────
ITERS="${ITERATIONS:-15}"
FORCE_FLAG=""
MODES_FLAG=""

for arg in "$@"; do
    case "$arg" in
        --force)         FORCE_FLAG="--force" ;;
        --modes=*)       MODES_FLAG="--modes=${arg#--modes=}" ;;
        *)               ITERS="$arg" ;;
    esac
done
[ -n "${FORCE:-}" ] && FORCE_FLAG="--force"

echo "══════════════════════════════════════════════════════════"
echo "  ${BENCH} 3-way experiment  |  DB: ${DB}  |  Iters: ${ITERS}"
echo "  Modes: ${MODES_FLAG:-all (no_aqo, standard_aqo, semantic_aqo)}"
echo "  Results → ${RESULTS_DIR}"
echo "══════════════════════════════════════════════════════════"

/usr/bin/python3 "$EXPERIMENT_DIR/runner.py" \
    "$DB" "$QUERY_DIR" "$RESULTS_DIR" \
    --iterations "$ITERS" $FORCE_FLAG $MODES_FLAG

/usr/bin/python3 "$EXPERIMENT_DIR/analyze.py" \
    "$RESULTS_DIR" --title "$BENCH"

echo ""
echo "Done. Results: $RESULTS_DIR"
