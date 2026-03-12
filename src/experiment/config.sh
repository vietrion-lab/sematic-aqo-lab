#!/usr/bin/env bash
# =============================================================================
# Experiment Configuration
# =============================================================================

export PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
export PGBIN="/usr/local/pgsql/bin"
export PGDATA="/usr/local/pgsql/data"

# Databases
export TPCH_DB="tpch"
export TPCDS_DB="tpcds"

# Iterations — both modes run this many times
export ITERATIONS=20

# AQO settings
export AQO_JOIN_THRESHOLD=0

# Parallelism (disabled during AQO learn for deterministic results)
export AQO_PARALLEL_WORKERS=0
