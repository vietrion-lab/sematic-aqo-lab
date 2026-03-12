# Semantic-AQO: Adaptive Query Optimization with Word2Vec Embeddings

A research project extending PostgreSQL's query optimizer with **semantic understanding** of SQL queries. Built on top of [AQO](https://github.com/postgrespro/aqo) (Adaptive Query Optimization) by PostgresPro, this system uses Word2Vec embeddings to capture the semantic structure of SQL predicates, enabling better cardinality estimation and faster query execution.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────┐
│                    PostgreSQL 15.15                        │
│                                                           │
│  ┌─────────────┐    ┌──────────────────────────────────┐  │
│  │ PG Planner  │───▶│  Semantic-AQO Extension (aqo)    │  │
│  │             │◀───│                                  │  │
│  └─────────────┘    │  sql_preprocessor                │  │
│                     │    → Normalize & tokenize SQL     │  │
│                     │  w2v_embedding_extractor          │  │
│                     │    → Aggregate token embeddings   │  │
│                     │  w2v_inference                    │  │
│                     │    → Lookup pre-trained W2V model │  │
│                     │  machine_learning (k-NN)          │  │
│                     │    → 17-dim features → cardinality│  │
│                     │    → [w2v[16] + selectivity[1]]   │  │
│                     └──────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

**Feature vector**: 17 dimensions = 16-dim W2V embedding + 1 log(selectivity)
**W2V vocabulary**: 301 tokens × 16 dimensions, auto-loaded on `CREATE EXTENSION aqo`
**ML model**: k-NN regression (OkNNr) trained online during query execution

## Repository Structure

```
.
├── semantic-aqo-main/          # Semantic-AQO source code
│   └── extension/              # PostgreSQL extension (C code)
│       ├── aqo.c               # Extension entry point, GUC registration
│       ├── machine_learning.c  # k-NN regression model (OkNNr)
│       ├── cardinality_*.c     # Hooks into PG planner
│       ├── w2v_*.c             # Word2Vec inference & embedding extraction
│       ├── sql_preprocessor.c  # SQL normalization & tokenization
│       ├── context_extractor.c # Training pair generation (offline)
│       ├── aqo--1.6.sql        # Extension SQL (schema + 301 token embeddings)
│       ├── sql/                # Regression test SQL files (23 tests)
│       └── expected/           # Expected regression test outputs
├── postgresql-15.15/           # PostgreSQL source (patched for AQO hooks)
├── experiment/                 # Benchmarking framework
│   ├── runner.py               # Python experiment engine
│   ├── analyze.py              # Figure generation (matplotlib)
│   ├── config.sh               # Shared configuration
│   ├── lib/bench_runner.sh     # Bash wrapper for runner.py
│   ├── tpch/                   # TPC-H benchmark (22 templates × 20 seeds)
│   │   ├── queries/            # Generated & validated query files
│   │   ├── test_queries/       # 3 simple queries for quick testing
│   │   └── results/            # Timestamped experiment results
│   └── tpcds/                  # TPC-DS benchmark (99 templates × 20 seeds)
│       ├── queries/            # Generated & validated query files
│       ├── test_queries/       # 3 simple queries for quick testing
│       └── results/            # Timestamped experiment results
├── scripts/                    # Setup & automation
│   ├── setup-all.sh            # One-command full setup (runs 00-02)
│   ├── 00-system-setup.sh      # Install OS dependencies
│   ├── 01-postgres-clone-and-build.sh  # Build PostgreSQL 15.15
│   ├── 02-semantic-aqo-clone-and-build.sh  # Patch PG, build AQO extension
│   ├── 03-recompile-extensions.sh  # Dev rebuild (after code changes)
│   ├── run-experiment.sh       # Full experiment pipeline
│   └── databases/              # TPC-H & TPC-DS database setup
│       ├── 01-setup-tpch-1gb.sh    # Generate data + queries + validate
│       └── 02-setup-tpcds-1gb.sh   # Generate data + queries + validate
├── models/
│   └── sense_embeddings.bin    # Pre-trained W2V model (301 tokens × 16 dims)
├── config/db.conf              # Connection configuration
└── docs/                       # Research notes & documentation
```

## Quick Start

### 1. Full Setup (from scratch)

```bash
# Install everything: OS deps → PostgreSQL 15.15 → AQO extension
./scripts/setup-all.sh
```

This runs scripts `00`, `01`, `02` in sequence. Takes ~15 min on first run.

### 2. Load Benchmark Databases

```bash
# TPC-H (22 query templates × 20 random seeds, SF=1 ~1GB)
./scripts/databases/01-setup-tpch-1gb.sh

# TPC-DS (99 templates × 20 seeds, SF=1 ~1GB)
./scripts/databases/02-setup-tpcds-1gb.sh
```

Each script: creates DB → loads schema + data → generates queries → validates (60s timeout per query, stdout discarded to avoid OOM) → keeps only valid queries.

### 3. Run Experiments

```bash
# Full pipeline: both TPC-H and TPC-DS
./scripts/run-experiment.sh

# Or individually
./scripts/run-experiment.sh --tpch-only
./scripts/run-experiment.sh --tpcds-only

# Skip DB loading if databases already exist
./scripts/run-experiment.sh --skip-load
```

Each experiment runs **2 modes × 20 iterations**:
- **no_aqo**: PostgreSQL with AQO disabled (baseline)
- **with_aqo**: PostgreSQL with Semantic AQO in learn mode

Outputs per benchmark:
- `no_aqo_results.csv` / `with_aqo_results.csv`
- `fig1_cardinality_<name>.png` — Q-error over iterations
- `fig2_planning_time_<name>.png` — Planning overhead
- `fig3_execution_time_<name>.png` — Execution speedup

### 4. Quick Test (3 queries, fast)

```bash
# Quick TPC-H test with 3 iterations
source experiment/config.sh
python3 experiment/runner.py tpch experiment/tpch/test_queries /tmp/quick_test --iterations 3
python3 experiment/analyze.py /tmp/quick_test --title "TPC-H-Quick"
```

## Development Workflow

### Recompile after code changes

```bash
# Full recompile (PG + extension + tests)
./scripts/03-recompile-extensions.sh

# Extension only (skip PG recompile)
./scripts/03-recompile-extensions.sh --aqo-only

# Extension only, skip tests
./scripts/03-recompile-extensions.sh --quick
```

### Run regression tests

```bash
cd semantic-aqo-main/extension
LANG=C.UTF-8 make check top_builddir=/workspaces/app/postgresql-15.15
```

All 23 tests should pass.

### Build commands (manual)

```bash
cd semantic-aqo-main/extension

# Build
make top_builddir=/workspaces/app/postgresql-15.15

# Install
sudo make install top_builddir=/workspaces/app/postgresql-15.15

# Test
LANG=C.UTF-8 make check top_builddir=/workspaces/app/postgresql-15.15
```

### Connect to databases

```bash
# psql shorthand
sudo -u postgres /usr/local/pgsql/bin/psql -d tpch
sudo -u postgres /usr/local/pgsql/bin/psql -d tpcds

# Check AQO is loaded
SHOW shared_preload_libraries;  -- should show 'aqo'

# Check token embeddings
SELECT count(*) FROM token_embeddings;  -- should be 301

# AQO status
SELECT * FROM aqo_query_stat ORDER BY executions_with_aqo DESC LIMIT 10;
```

## PostgreSQL Server Management

```bash
# Start / Stop / Restart / Status
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data start
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data stop
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data restart
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data status

# View server logs
cat /usr/local/pgsql/data/logfile
```

## Key Configuration

| Setting | Value | Location |
|---------|-------|----------|
| PostgreSQL | 15.15 | `/usr/local/pgsql/` |
| Data dir | `/usr/local/pgsql/data` | `postgresql.conf` |
| Extension | aqo 1.6 | `shared_preload_libraries = 'aqo'` |
| W2V model | 301 tokens × 16 dims | `models/sense_embeddings.bin` |
| Feature vector | 17 dims | `[w2v[16] + log(selectivity)[1]]` |
| Parallel workers | 0 (disabled) | `experiment/config.sh` |
| Query timeout | 60s | Setup scripts (validation phase) |
| Benchmark scale | SF=1 (~1GB) | Setup scripts |
