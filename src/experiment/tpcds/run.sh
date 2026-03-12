#!/usr/bin/env bash
# =============================================================================
# TPC-DS Experiment Runner
#
# Runs 2 modes × N iterations: no_aqo (baseline) & with_aqo (semantic AQO)
# Results written to experiment/tpcds/results/<timestamp>/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$EXPERIMENT_DIR/config.sh"
source "$EXPERIMENT_DIR/lib/bench_runner.sh"

run_experiment "${TPCDS_DB}" "$SCRIPT_DIR/queries" "TPC-DS"
