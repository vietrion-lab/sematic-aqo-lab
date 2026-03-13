#!/usr/bin/env bash
# =============================================================================
# Experiment Configuration — optional env overrides
#
# Each run.sh is standalone with its own defaults. Source this file (or export
# env vars) only when you want to override values across all benchmarks.
# =============================================================================

export PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
export PGBIN="/usr/local/pgsql/bin"
export PGDATA="/usr/local/pgsql/data"

# Databases (each run.sh has its own default; these override if exported)
export TPCH_DB="tpch"
export TPCDS_DB="tpcds"
export JOB_DB="imdb"
export STATS_DB="stats"

# Iterations — both modes run this many times
export ITERATIONS=15

# AQO settings
export AQO_JOIN_THRESHOLD=0
