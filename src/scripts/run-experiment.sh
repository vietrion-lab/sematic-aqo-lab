#!/usr/bin/env bash
# =============================================================================
# run-experiment.sh — Full AQO Experiment Pipeline
#
# Controls the entire flow:
#   1. Ensure databases exist (load if needed)
#   2. Run selected benchmarks (no_aqo vs with_aqo, 20 iterations each)
#   3. Figures are auto-generated per benchmark
#
# Usage:
#   ./scripts/run-experiment.sh [--tpch-only | --tpcds-only | --job-only | --stats-only] [--skip-load] [--force]
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPERIMENT_DIR="$REPO_ROOT/experiment"
SCRIPTS_DIR="$REPO_ROOT/scripts"

source "$EXPERIMENT_DIR/config.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
RUN_TPCH=true
RUN_TPCDS=true
RUN_JOB=true
RUN_STATS=true
SKIP_LOAD=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --tpch-only)   RUN_TPCDS=false; RUN_JOB=false; RUN_STATS=false ;;
        --tpcds-only)  RUN_TPCH=false;  RUN_JOB=false; RUN_STATS=false ;;
        --job-only)    RUN_TPCH=false;  RUN_TPCDS=false; RUN_STATS=false ;;
        --stats-only)  RUN_TPCH=false;  RUN_TPCDS=false; RUN_JOB=false ;;
        --skip-load)   SKIP_LOAD=true ;;
        --force)       FORCE=true ;;
        --help|-h)
            echo "Usage: $0 [--tpch-only | --tpcds-only | --job-only | --stats-only] [--skip-load] [--force]"
            echo ""
            echo "Options:"
            echo "  --tpch-only    Run only TPC-H benchmark"
            echo "  --tpcds-only   Run only TPC-DS benchmark"
            echo "  --job-only     Run only JOB (IMDB) benchmark"
            echo "  --stats-only   Run only STATS-CEB benchmark"
            echo "  --skip-load    Skip database loading (assume DBs exist)"
            echo "  --force        Discard checkpoints and re-run all phases"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         AQO Full Experiment Pipeline                     ║"
echo "║                                                          ║"
echo "║  TPC-H  : $([ "$RUN_TPCH" = true ] && echo "YES" || echo "SKIP")"
echo "║  TPC-DS : $([ "$RUN_TPCDS" = true ] && echo "YES" || echo "SKIP")"
echo "║  JOB    : $([ "$RUN_JOB" = true ] && echo "YES" || echo "SKIP")"
echo "║  STATS  : $([ "$RUN_STATS" = true ] && echo "YES" || echo "SKIP")"
echo "║  Iters  : $ITERATIONS per mode"
echo "║  Force  : $([ "$FORCE" = true ] && echo "YES" || echo "NO (resume)")"
echo "║  Skip DB: $([ "$SKIP_LOAD" = true ] && echo "YES" || echo "NO")"
echo "╚═══════════════════════════════════════════════════════════╝"

# ── Step 1: Ensure databases are loaded ──────────────────────────────────────
db_exists() {
    $PSQL -lqt | cut -d \| -f 1 | grep -qw "$1"
}

if [ "$SKIP_LOAD" = false ]; then
    echo ""
    echo "━━━ Step 1: Database Setup ━━━"

    if [ "$RUN_TPCH" = true ] && ! db_exists "$TPCH_DB"; then
        echo "  Loading TPC-H database..."
        if [ -f "$SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh" ]; then
            bash "$SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh not found"
            exit 1
        fi
    elif [ "$RUN_TPCH" = true ]; then
        echo "  TPC-H database '$TPCH_DB' already exists."
    fi

    if [ "$RUN_TPCDS" = true ] && ! db_exists "$TPCDS_DB"; then
        echo "  Loading TPC-DS database..."
        if [ -f "$SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh" ]; then
            bash "$SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh not found"
            exit 1
        fi
    elif [ "$RUN_TPCDS" = true ]; then
        echo "  TPC-DS database '$TPCDS_DB' already exists."
    fi

    if [ "$RUN_JOB" = true ] && ! db_exists "$JOB_DB"; then
        echo "  Loading JOB (IMDB) database..."
        if [ -f "$SCRIPTS_DIR/databases/03-setup-job-imdb.sh" ]; then
            bash "$SCRIPTS_DIR/databases/03-setup-job-imdb.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/03-setup-job-imdb.sh not found"
            exit 1
        fi
    elif [ "$RUN_JOB" = true ]; then
        echo "  JOB database '$JOB_DB' already exists."
    fi

    if [ "$RUN_STATS" = true ] && ! db_exists "$STATS_DB"; then
        echo "  Loading STATS database..."
        if [ -f "$SCRIPTS_DIR/databases/04-setup-stats.sh" ]; then
            bash "$SCRIPTS_DIR/databases/04-setup-stats.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/04-setup-stats.sh not found"
            exit 1
        fi
    elif [ "$RUN_STATS" = true ]; then
        echo "  STATS database '$STATS_DB' already exists."
    fi
else
    echo ""
    echo "━━━ Step 1: Database Setup — SKIPPED ━━━"
fi

FORCE_ARG=""
[ "$FORCE" = true ] && FORCE_ARG="--force"

# ── Step 2: Run Experiments ──────────────────────────────────────────────────
if [ "$RUN_TPCH" = true ]; then
    echo ""
    echo "━━━ Step 2: TPC-H Benchmark ━━━"
    bash "$EXPERIMENT_DIR/tpch/run.sh" $FORCE_ARG
fi

if [ "$RUN_TPCDS" = true ]; then
    echo ""
    echo "━━━ Step 3: TPC-DS Benchmark ━━━"
    bash "$EXPERIMENT_DIR/tpcds/run.sh" $FORCE_ARG
fi

if [ "$RUN_JOB" = true ]; then
    echo ""
    echo "━━━ Step 4: JOB (IMDB) Benchmark ━━━"
    bash "$EXPERIMENT_DIR/job/run.sh" $FORCE_ARG
fi

if [ "$RUN_STATS" = true ]; then
    echo ""
    echo "━━━ Step 5: STATS-CEB Benchmark ━━━"
    bash "$EXPERIMENT_DIR/stats/run.sh" $FORCE_ARG
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Full experiment pipeline complete."
echo "════════════════════════════════════════════════════════════"
