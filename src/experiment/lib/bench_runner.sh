#!/usr/bin/env bash
# =============================================================================
# bench_runner.sh — Shared utilities for AQO experiments
# =============================================================================

set -euo pipefail

EXPERIMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── run_experiment: main entry called by tpch/run.sh and tpcds/run.sh ───────
#   $1 = db name
#   $2 = query dir
#   $3 = benchmark name (tpch/tpcds)
run_experiment() {
    local db="$1"
    local query_dir="$2"
    local bench_name="$3"
    local iters="${ITERATIONS:-20}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local results_dir
    results_dir="$(dirname "$query_dir")/results/${timestamp}"
    mkdir -p "$results_dir"

    # Run the Python experiment engine
    /usr/bin/python3 "$EXPERIMENT_DIR/runner.py" \
        "$db" "$query_dir" "$results_dir" \
        --iterations "$iters"

    # Analyze and generate figures
    /usr/bin/python3 "$EXPERIMENT_DIR/analyze.py" \
        "$results_dir" --title "$bench_name"

    echo "$results_dir"
}
