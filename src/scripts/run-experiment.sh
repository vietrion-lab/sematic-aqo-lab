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

# ── Locale guard (devcontainer may lack en_US.UTF-8) ────────────────────────
if ! locale -a 2>/dev/null | grep -qi 'en_US\.utf.*8'; then
    export LC_ALL=C
    export LANG=C
fi

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

# ── Step 0: Ensure PATH includes PostgreSQL binaries ─────────────────────────
export PATH="/usr/local/pgsql/bin:$PATH"

# ── Step 0b: Ensure PostgreSQL server is running ─────────────────────────────
echo ""
echo "━━━ Pre-flight: Ensuring PostgreSQL is running ━━━"

PGDATA="${PGDATA:-/usr/local/pgsql/data}"
PGBIN="${PGBIN:-/usr/local/pgsql/bin}"
PGLOGFILE="$PGDATA/logfile"

pg_ensure_running() {
    NEED_FRESH_SETUP=false

    # ── initdb if data directory is empty / not initialised ──
    if ! sudo -u postgres test -f "$PGDATA/PG_VERSION"; then
        echo "  Data directory not initialised — running initdb..."
        sudo mkdir -p "$PGDATA"
        sudo chown postgres:postgres "$PGDATA"
        sudo chmod 700 "$PGDATA"
        sudo -u postgres env LC_ALL=C LANG=C "$PGBIN/initdb" -D "$PGDATA" --locale=C
        NEED_FRESH_SETUP=true
    fi

    # ── Ensure shared_preload_libraries includes 'aqo' ──
    CONF_FILE="$PGDATA/postgresql.conf"
    _need_restart=false
    if [ -f "$CONF_FILE" ] || sudo test -f "$CONF_FILE"; then
        if ! sudo grep -q "^shared_preload_libraries.*aqo" "$CONF_FILE" 2>/dev/null; then
            echo "  Configuring shared_preload_libraries = 'aqo' ..."
            echo "shared_preload_libraries = 'aqo'" | sudo tee -a "$CONF_FILE" > /dev/null
            echo "  ✅ AQO added to shared_preload_libraries"
            _need_restart=true
        fi
    fi

    # ── If PG is running but needs restart (config changed), restart it ──
    if sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
        if [ "$_need_restart" = true ]; then
            echo "  PostgreSQL is running but needs restart for config change..."
            sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGLOGFILE" restart
            sleep 3
            echo "  ✅ PostgreSQL restarted with AQO."
        else
            echo "  ✅ PostgreSQL is already running."
        fi
        # Post-init if needed
        if [ "$NEED_FRESH_SETUP" = true ]; then
            _do_post_init
        fi
        return 0
    fi

    # ── Start PostgreSQL ──
    echo "  PostgreSQL is not running — starting it now..."
    sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGLOGFILE" start
    sleep 3

    # Verify it came up
    if sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
        echo "  ✅ PostgreSQL started successfully."
    else
        echo "  ❌ Failed to start PostgreSQL. Check $PGLOGFILE" >&2
        sudo -u postgres tail -20 "$PGLOGFILE" 2>/dev/null || true
        exit 1
    fi

    # ── Post-init: create superuser role, test database, AQO extension ──
    if [ "$NEED_FRESH_SETUP" = true ]; then
        _do_post_init
    fi
}

_do_post_init() {
    echo "  Creating 'superuser' role for convenience..."
    sudo -u postgres "$PGBIN/psql" -c "
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'superuser') THEN
                CREATE ROLE superuser WITH LOGIN SUPERUSER;
            END IF;
        END
        \$\$;" 2>/dev/null || true

    echo "  Creating 'test' database..."
    sudo -u postgres "$PGBIN/createdb" test 2>/dev/null || true

    echo "  Creating AQO extension in 'test' database..."
    sudo -u postgres "$PGBIN/psql" test -c "CREATE EXTENSION IF NOT EXISTS aqo;" 2>/dev/null || true
    echo "  ✅ Fresh cluster initialised with AQO."
}

pg_ensure_running

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
    echo "━━━ Step 1: Database Setup (data only, queries pre-existing) ━━━"

    # Export flag so DB setup scripts skip query generation/validation
    export SKIP_QUERY_SETUP=1

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

    unset SKIP_QUERY_SETUP

    # ── Ensure queries are unchanged from git (restore if damaged) ──
    echo ""
    echo "━━━ Step 1b: Verifying query files exist ━━━"
    _query_dirs=()
    [ "$RUN_TPCH"  = true ] && _query_dirs+=("$EXPERIMENT_DIR/tpch/queries")
    [ "$RUN_TPCDS" = true ] && _query_dirs+=("$EXPERIMENT_DIR/tpcds/queries")
    [ "$RUN_JOB"   = true ] && _query_dirs+=("$EXPERIMENT_DIR/job/queries")
    [ "$RUN_STATS" = true ] && _query_dirs+=("$EXPERIMENT_DIR/stats/queries")

    for _qdir in "${_query_dirs[@]}"; do
        if [ ! -d "$_qdir" ]; then
            echo "  ERROR: $_qdir does not exist — queries must be pre-generated!"
            exit 1
        fi
        _count=$(ls "$_qdir"/*.sql 2>/dev/null | wc -l)
        if [ "$_count" -eq 0 ]; then
            echo "  ERROR: $_qdir has 0 SQL files — queries must be pre-generated!"
            exit 1
        fi
        echo "  ✅ $(basename "$(dirname "$_qdir")")/queries — $_count queries"
        # Restore from git if available (works when running on host or in a git repo)
        if command -v git &>/dev/null && git -C "$REPO_ROOT" rev-parse --git-dir &>/dev/null 2>&1; then
            _rel="${_qdir#$REPO_ROOT/}"
            _changed=$(cd "$REPO_ROOT" && git diff --name-only -- "$_rel" 2>/dev/null || true)
            if [ -n "$_changed" ]; then
                echo "    Restoring modified queries from git..."
                (cd "$REPO_ROOT" && git checkout -- "$_rel")
                echo "    ✅ Restored."
            fi
        fi
    done
else
    echo ""
    echo "━━━ Step 1: Database Setup — SKIPPED ━━━"
fi

FORCE_ARG=""
[ "$FORCE" = true ] && FORCE_ARG="--force"

# ── Step 1c: Ensure AQO extension exists in each target database ─────────────
echo ""
echo "━━━ Step 1c: Ensuring AQO extension in target databases ━━━"

ensure_aqo_in_db() {
    local _db="$1"
    $PSQL "$_db" -c "CREATE EXTENSION IF NOT EXISTS aqo;" 2>/dev/null && \
        echo "  ✅ AQO ready in '$_db'" || \
        echo "  ⚠️  Could not create AQO in '$_db' (may need switch-aqo first)"
}

[ "$RUN_TPCH"  = true ] && ensure_aqo_in_db "$TPCH_DB"
[ "$RUN_TPCDS" = true ] && ensure_aqo_in_db "$TPCDS_DB"
[ "$RUN_JOB"   = true ] && ensure_aqo_in_db "$JOB_DB"
[ "$RUN_STATS" = true ] && ensure_aqo_in_db "$STATS_DB"

# ── Step 1d: Ensure AQO variant .so files exist for switching ───────────────
echo ""
echo "━━━ Step 1d: Ensuring AQO variant binaries (standard + semantic) ━━━"

AQO_STD_SO="/usr/local/pgsql/lib/aqo_std.so"
AQO_SEM_SO="/usr/local/pgsql/lib/aqo_semantic.so"

if [[ ! -f "$AQO_STD_SO" ]] || [[ ! -f "$AQO_SEM_SO" ]]; then
    echo "  Missing AQO variant binaries:"
    [[ ! -f "$AQO_STD_SO" ]] && echo "    - $AQO_STD_SO"
    [[ ! -f "$AQO_SEM_SO" ]] && echo "    - $AQO_SEM_SO"
    echo "  Running 04-standard-aqo-build.sh to build both variants..."
    bash "$SCRIPTS_DIR/04-standard-aqo-build.sh"
    echo "  ✅ AQO variant binaries ready."
else
    echo "  ✅ Both variant binaries already exist."
fi

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
