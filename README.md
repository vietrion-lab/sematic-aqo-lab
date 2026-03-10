# semantic-aqo-lab

Lab environment for building, testing, and validating the **Semantic AQO** PostgreSQL extension. This repository provides comprehensive setup scripts and testing utilities for compiling PostgreSQL 15 with the Adaptive Query Optimization (AQO) extension from source.

## Overview

**Adaptive Query Optimization (AQO)** is a PostgreSQL extension that enhances query execution by learning from actual query performance. The extension uses machine learning (k-NN) to improve cardinality estimation, allowing the query planner to make better decisions about execution strategies (join methods, sort techniques, memory allocation, etc.).

This lab environment provides:

- **Dev Container** for reproducible development on Ubuntu 22.04
- **Setup scripts** to install dependencies, build PostgreSQL 15 from source, and compile the AQO extension
- **Recompilation & testing scripts** for iterative AQO development
- **Documentation** explaining AQO modes, configuration, and best practices
- **PostgreSQL management guides** for common operations

## Repository Structure

```
semantic-aqo-lab/
├── README.md                               # This file
├── .devcontainer/
│   ├── Dockerfile                          # Ubuntu 22.04 dev container image
│   └── devcontainer.json                   # VS Code Dev Container configuration
├── src/
│   ├── .github/
│   │   └── copilot-instructions.md         # Copilot project guidelines
│   ├── .vscode/
│   │   └── settings.json                   # VS Code workspace settings
│   ├── scripts/                            # Environment setup & testing scripts
│   │   ├── 00-system-setup.sh              # Install system dependencies, Python 3, venv
│   │   ├── 01-postgres-clone-and-build.sh  # Download & compile PostgreSQL 15
│   │   ├── 02-semantic-aqo-clone-and-build.sh  # Clone & build AQO extension
│   │   ├── 03-recompile-extensions.sh      # Recompile PostgreSQL/AQO after source changes
│   │   ├── 04-test-node-context.sh         # Test AQO Node Context Extractor feature
│   │   └── setup-all.sh                    # Run all setup scripts in sequence
│   ├── docs/
│   │   ├── aqo-testing-explain.md          # Detailed AQO usage guide (Vietnamese)
│   │   ├── learning-report.md              # AQO internals & PostgreSQL APIs report
│   │   └── resources/                      # Architecture diagrams
│   │       ├── aqo_architecture-ADKNN - Syntactic Approach.png
│   │       ├── aqo_architecture-Concept.png
│   │       └── aqo_architecture-Semantic AQO.png
│   ├── logs/                               # Test output logs (timestamped)
│   ├── postgresql-15.15/                   # PostgreSQL 15 source (created after setup)
│   │   └── contrib/aqo/                    # Semantic AQO extension source
│   └── README.md                           # PostgreSQL management commands
```

## Quick Start

### 1. Dev Container (Recommended)

Open this repository in VS Code and use the **Dev Containers** extension to launch the pre-configured Ubuntu 22.04 environment with all build dependencies.

### 2. Environment Setup

```bash
# Run all setup scripts in sequence
cd src/scripts
bash setup-all.sh

# Or run individually:
bash 00-system-setup.sh                    # Install build tools, Python 3, venv
bash 01-postgres-clone-and-build.sh        # Download & compile PostgreSQL 15
bash 02-semantic-aqo-clone-and-build.sh    # Clone & build Semantic AQO extension
```

**Note**: The scripts are designed to run on Ubuntu/Debian systems (or inside the Dev Container).

### 3. Recompile After Changes

```bash
cd src/scripts

# Full rebuild (PostgreSQL + AQO + tests)
bash 03-recompile-extensions.sh

# Quick rebuild (AQO only, skip PostgreSQL rebuild)
bash 03-recompile-extensions.sh --quick

# Rebuild AQO with tests
bash 03-recompile-extensions.sh --aqo-only
```

### 4. Test Node Context Extractor

```bash
cd src/scripts
bash 04-test-node-context.sh
# Logs saved to src/logs/nce-test-<timestamp>.log
```

## How AQO Works

### Basic Workflow

```
Query arrives → PostgreSQL estimates cardinality
                    ↓
         AQO intervention: apply ML predictions
                    ↓
         Choose optimized execution plan
                    ↓
         Execute query → collect actual rows vs estimated
                    ↓
         Update ML model for future queries
```

### Key Concepts

| Concept              | Definition                                                      |
| -------------------- | --------------------------------------------------------------- |
| **Query Hash**       | Normalized query without constants (same structure = same hash) |
| **Feature Space**    | ML model for a group of similar queries (one per queryid)       |
| **Feature Subspace** | ML model for individual plan nodes (Seq Scan, Hash Join, etc)   |
| **k-NN Learning**    | Machine learning algorithm that predicts cardinality errors     |
| **Cardinality**      | Number of rows estimated vs actual at each plan node            |

### AQO Modes

| Mode          | Behavior                                       | Use Case                   |
| ------------- | ---------------------------------------------- | -------------------------- |
| `disabled`    | AQO off, PostgreSQL uses base optimizer        | Temporarily disable AQO    |
| `controlled`  | Optimize only known queries (from aqo_queries) | **Production (default)**   |
| `learn`       | Auto-add new queries, collect statistics       | Learning phase for queries |
| `intelligent` | Auto-learn with automatic tuning               | Development/testing        |
| `forced`      | Dynamic workloads (shared feature space)       | Highly variable queries    |

## Documentation

- **[aqo-testing-explain.md](src/docs/aqo-testing-explain.md)** — Comprehensive guide on AQO usage, configuration, testing (Vietnamese)
  - AQO architecture and modes
  - Internal views (aqo_queries, aqo_query_stat, aqo_data, aqo_query_texts)
  - GUC parameters and configuration
  - Real-world usage patterns
  - Test script breakdown
  - Reading EXPLAIN ANALYZE output

- **[learning-report.md](src/docs/learning-report.md)** — AQO internals & PostgreSQL APIs
  - Hook system (planner_hook, ExecutorEnd_hook, etc.)
  - GUC configuration system
  - Shared memory management
  - ML pipeline details

- **[src/README.md](src/README.md)** — PostgreSQL management commands
  - Server management (start, stop, restart)
  - Database operations (create, drop, connect)
  - Configuration files
  - psql shortcuts and commands

## Common Tasks

### Configure PostgreSQL Server

```bash
# Start server
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data start

# Connect to database
psql -U postgres -d postgres

# View server logs
tail -f /usr/local/pgsql/data/logfile
```

### Enable AQO for a Query

```sql
-- Session: Set learning mode for a specific query
BEGIN;
SET aqo.mode = 'learn';
EXPLAIN ANALYZE <slow_query>;  -- Run multiple times
EXPLAIN ANALYZE <slow_query>;  -- AQO learns cardinality patterns
SET aqo.mode = 'controlled';
COMMIT;

-- View AQO prediction details
SET aqo.show_details = 'on';
SET aqo.show_hash = 'on';
EXPLAIN ANALYZE <query>;
```

### Monitor AQO Performance

```sql
-- Check which queries AQO is optimizing
SELECT queryid, learn_aqo, use_aqo, auto_tuning
FROM aqo_queries
WHERE queryid != 0;

-- Compare performance with/without AQO
SELECT
    queryid,
    executions_with_aqo,
    cardinality_error_with_aqo[1:3] AS errors_with_aqo,
    cardinality_error_without_aqo[1:3] AS errors_without_aqo
FROM aqo_query_stat;

-- View AQO ML models
SELECT fs, fss, nfeatures, array_length(features, 1) as sample_count
FROM aqo_data;
```

## Project Links

- **AQO Extension**: [vietrion-lab/semantic-aqo-main](https://github.com/vietrion-lab/semantic-aqo-main) (branch: stable15)
- **Semantic AQO**: [vietrion-lab/semantic-aqo](https://github.com/vietrion-lab/semantic-aqo)
- **Original AQO Paper**: [arxiv.org/abs/1711.08330](https://arxiv.org/abs/1711.08330)

## Testing

### Node Context Extractor Tests

```bash
cd src/scripts
bash 04-test-node-context.sh
```

Tests single-table scans, two-table joins, and multi-table joins, then logs all collected node context data. Output is saved to `src/logs/nce-test-<timestamp>.log`.

### AQO Extension Tests (make check)

```bash
cd src/postgresql-15.15/contrib/aqo
make check
```

## System Requirements

- **OS**: Ubuntu/Debian (Linux) — or use the included Dev Container
- **CPU**: Multi-core for faster compilation
- **Memory**: ≥8GB (16GB recommended)
- **Disk**: ≥5GB free space
- **Tools**: gcc, make, Python 3, git

## Troubleshooting

**PostgreSQL build fails:**

- Ensure build-essential, libreadline-dev, zlib1g-dev installed
- Check `/usr/local/pgsql/src/config.log` for details

**AQO extension not loading:**

- Verify `shared_preload_libraries = 'aqo'` in postgresql.conf
- Restart PostgreSQL server after modifying config
- Check `/usr/local/pgsql/data/logfile` for errors

**Tests fail:**

- Confirm PostgreSQL server is running: `pg_ctl status -D /usr/local/pgsql/data`
- Ensure postgres user has permissions: `sudo chown postgres:postgres /usr/local/pgsql/data`
- Run tests with: `bash -x 04-test-node-context.sh` for debugging

## License

See individual repository licenses (AQO extension, PostgreSQL)
