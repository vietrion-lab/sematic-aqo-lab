# PostgreSQL Cardinality Extraction Extension — semantic_aqo

## Overview

The `semantic_aqo` extension is designed to **automatically capture cardinality statistics** (estimated vs actual row counts) after each SQL query execution in PostgreSQL. This data is persisted to the `semantic_aqo_stats` table for analysis and machine learning model training to improve the query optimizer.

### Objectives

- **Capture estimated rows** (`plan_rows`) from the planner
- **Capture actual rows** (`es_processed`) from the executor
- **Calculate error ratio** = actual / estimated
- **Persistent storage** in a PostgreSQL table
- **Zero impact** on user query performance

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PostgreSQL Backend                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─────────────┐     ┌──────────────┐     ┌─────────────────────┐ │
│   │   Parser    │────▶│   Planner    │────▶│     Executor        │ │
│   └─────────────┘     └──────┬───────┘     └──────────┬──────────┘ │
│                              │                        │            │
│                    ┌─────────▼─────────┐    ┌────────▼─────────┐  │
│                    │  planner_hook     │    │ ExecutorEnd_hook │  │
│                    │  (saqo_planner)   │    │ (saqo_executor)  │  │
│                    └─────────┬─────────┘    └────────┬─────────┘  │
│                              │                        │            │
│                              │  est_rows              │ actual_rows│
│                              │  query_string          │            │
│                              │                        │            │
│                              └────────────┬───────────┘            │
│                                           │                        │
│                                  ┌────────▼────────┐               │
│                                  │  storage.c      │               │
│                                  │  (SPI INSERT)   │               │
│                                  └────────┬────────┘               │
│                                           │                        │
│                                  ┌────────▼────────┐               │
│                                  │ semantic_aqo_   │               │
│                                  │ stats (TABLE)   │               │
│                                  └─────────────────┘               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
semantic-aqo/extensions/semantic-aqo/
├── Makefile                    # PGXS build configuration
├── semantic_aqo.c              # Main entry point, PG_MODULE_MAGIC
├── semantic_aqo.control        # Extension metadata
├── semantic_aqo--1.0.sql       # SQL install script (CREATE TABLE, etc.)
│
├── hooks/
│   ├── hooks_manager.c         # _PG_init/_PG_fini, GUC registration
│   ├── planner_hook.c          # Intercept planner, capture est_rows
│   ├── executor_hooks.c        # Intercept ExecutorEnd, capture actual_rows
│   └── cardinality_hooks.c     # Placeholder for Phase 2 (model inference)
│
├── storage/
│   ├── storage.c               # SPI-based INSERT into stats table
│   └── storage.h               # Header declarations
│
└── utils/
    ├── hash.c                  # FNV-1a query fingerprinting
    ├── hash.h
    ├── utils.c                 # Helper functions (is_select_query)
    ├── utils.h
    ├── calc.c                  # Math utilities
    ├── context_extractor.c     # Token extraction for training
    └── sql_preprocessor.c      # SQL tokenization/normalization
```

---

## Implementation Details

### 1. hooks/hooks_manager.c — Entry Point

This is the most critical file, containing `_PG_init()` which PostgreSQL calls when loading the shared library.

```c
/* Global hook pointers - saved for chaining */
planner_hook_type        saqo_prev_planner_hook = NULL;
ExecutorEnd_hook_type    saqo_prev_executor_end = NULL;

/* GUC variable to enable/disable capture */
bool saqo_enabled = true;

void _PG_init(void)
{
    /* Register GUC: semantic_aqo.enabled */
    DefineCustomBoolVariable(
        "semantic_aqo.enabled",
        "Enable cardinality statistics capture",
        NULL,
        &saqo_enabled,
        true,                    /* default = on */
        PGC_USERSET,            /* can be changed per-session */
        0, NULL, NULL, NULL
    );

    /* Save previous hooks for chaining */
    saqo_prev_planner_hook = planner_hook;
    saqo_prev_executor_end = ExecutorEnd_hook;

    /* Install our hooks */
    planner_hook     = saqo_planner_hook;
    ExecutorEnd_hook = saqo_executor_end_hook;

    elog(LOG, "semantic_aqo: hooks registered");
}

void _PG_fini(void)
{
    /* Restore previous hooks on unload */
    planner_hook     = saqo_prev_planner_hook;
    ExecutorEnd_hook = saqo_prev_executor_end;
}
```

**Key Points:**
- `planner_hook` and `ExecutorEnd_hook` are PostgreSQL's global function pointers
- We **save** the old hooks, **install** our new hooks, and **chain** when calling
- GUC `semantic_aqo.enabled` allows enabling/disabling capture at runtime

---

### 2. hooks/planner_hook.c — Capture Estimated Rows

```c
/* Per-backend state shared with executor hook */
double        saqo_last_est_rows     = 0.0;
const char   *saqo_last_query_string = NULL;
bool          saqo_planner_done      = false;

PlannedStmt *
saqo_planner_hook(Query *parse,
                  const char *query_string,
                  int cursorOptions,
                  ParamListInfo boundParams)
{
    PlannedStmt *result;

    /* Chain to previous hook or standard planner */
    if (saqo_prev_planner_hook)
        result = saqo_prev_planner_hook(parse, query_string,
                                        cursorOptions, boundParams);
    else
        result = standard_planner(parse, query_string,
                                  cursorOptions, boundParams);

    /* Capture stats when enabled */
    if (saqo_enabled && result && result->planTree)
    {
        saqo_last_est_rows     = result->planTree->plan_rows;
        saqo_last_query_string = query_string;
        saqo_planner_done      = true;
    }

    return result;
}
```

**Key Points:**
- `result->planTree->plan_rows` contains the estimated row count from the top-level plan node
- `query_string` is the original SQL text
- Static variables are used to pass data to the executor hook (same backend process)

---

### 3. hooks/executor_hooks.c — Capture Actual Rows & Persist

```c
void
saqo_executor_end_hook(QueryDesc *queryDesc)
{
    if (saqo_enabled && saqo_planner_done && queryDesc)
    {
        /* Only capture SELECT statements */
        if (queryDesc->operation == CMD_SELECT)
        {
            uint64      actual_rows = queryDesc->estate->es_processed;
            const char *sql_text    = queryDesc->sourceText;

            if (sql_text == NULL)
                sql_text = saqo_last_query_string;

            /* Skip our own stats queries to prevent infinite recursion */
            if (sql_text && strstr(sql_text, "semantic_aqo_stats") == NULL)
            {
                /* Persist to database */
                storage_save_query_stats(sql_text,
                                         saqo_last_est_rows,
                                         (int64) actual_rows);
            }
        }

        /* Reset state for next query */
        saqo_planner_done      = false;
        saqo_last_est_rows     = 0.0;
        saqo_last_query_string = NULL;
    }

    /* Chain to previous hook */
    if (saqo_prev_executor_end)
        saqo_prev_executor_end(queryDesc);
    else
        standard_ExecutorEnd(queryDesc);
}
```

**Key Points:**
- `queryDesc->estate->es_processed` = actual rows returned/affected
- `queryDesc->operation` indicates the command type (SELECT, INSERT, UPDATE, DELETE)
- Only capture SELECT to avoid noise
- Skip queries containing "semantic_aqo_stats" to prevent infinite recursion

---

### 4. storage/storage.c — SPI-based Persistence

```c
static bool saqo_saving_in_progress = false;  /* Recursion guard */

void
storage_save_query_stats(const char *sql, double est_rows, int64 actual_rows)
{
    int             ret;
    StringInfoData  buf;
    double          error_ratio;
    bool            spi_connected = false;
    bool            snapshot_pushed = false;

    /* Prevent recursion */
    if (saqo_saving_in_progress)
        return;

    if (sql == NULL || sql[0] == '\0')
        return;

    /* Skip our own bookkeeping queries */
    if (strstr(sql, "semantic_aqo_stats") != NULL)
        return;

    saqo_saving_in_progress = true;

    PG_TRY();
    {
        /* Compute error ratio */
        error_ratio = (est_rows > 0.0) 
                    ? (double) actual_rows / est_rows 
                    : 0.0;

        /* Connect to SPI */
        ret = SPI_connect();
        if (ret != SPI_OK_CONNECT)
        {
            saqo_saving_in_progress = false;
            return;
        }
        spi_connected = true;

        /* Build INSERT statement */
        initStringInfo(&buf);
        appendStringInfo(&buf,
            "INSERT INTO public.semantic_aqo_stats "
            "(query_text, est_rows, actual_rows, error_ratio) "
            "VALUES (%s, %f, %ld, %f)",
            quote_literal_cstr(sql),  /* Escape SQL injection */
            est_rows,
            (long) actual_rows,
            error_ratio);

        /* Push snapshot for SPI execution */
        PushActiveSnapshot(GetTransactionSnapshot());
        snapshot_pushed = true;

        /* Execute INSERT */
        ret = SPI_execute(buf.data, false, 0);

        PopActiveSnapshot();
        snapshot_pushed = false;

        pfree(buf.data);
        SPI_finish();
        spi_connected = false;
    }
    PG_CATCH();
    {
        /* Cleanup on error */
        if (snapshot_pushed)
            PopActiveSnapshot();
        if (spi_connected)
            SPI_finish();
        FlushErrorState();  /* Swallow error, don't break user query */
    }
    PG_END_TRY();

    saqo_saving_in_progress = false;
}
```

**Key Points:**
- **SPI (Server Programming Interface)** allows executing SQL from C code
- **PushActiveSnapshot()** is required for SPI_execute to have a snapshot context
- **Recursion guard** `saqo_saving_in_progress` prevents infinite loops
- **PG_TRY/PG_CATCH** ensures proper cleanup and doesn't crash user queries
- **quote_literal_cstr()** escapes SQL text to prevent injection attacks

---

### 5. semantic_aqo--1.0.sql — SQL Schema

```sql
-- Main stats table
CREATE TABLE IF NOT EXISTS semantic_aqo_stats (
    id          SERIAL PRIMARY KEY,
    query_text  TEXT,
    est_rows    FLOAT8,
    actual_rows BIGINT,
    error_ratio FLOAT8,
    captured_at TIMESTAMPTZ DEFAULT now()
);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_saqo_stats_captured_at 
ON semantic_aqo_stats (captured_at DESC);

-- Summary view
CREATE OR REPLACE VIEW semantic_aqo_stats_summary AS
SELECT 
    count(*)                           AS total_queries,
    round(avg(error_ratio)::numeric,4) AS avg_error_ratio,
    round(min(error_ratio)::numeric,4) AS min_error,
    round(max(error_ratio)::numeric,4) AS max_error,
    min(captured_at)                   AS first_capture,
    max(captured_at)                   AS last_capture
FROM semantic_aqo_stats;

-- Clear function
CREATE OR REPLACE FUNCTION aqo_clear_stats()
RETURNS VOID AS $$
BEGIN
    TRUNCATE semantic_aqo_stats;
END;
$$ LANGUAGE plpgsql;
```

---

### 6. Makefile — PGXS Build

```makefile
MODULES = semantic_aqo
EXTENSION = semantic_aqo
DATA = semantic_aqo--1.0.sql
PGFILEDESC = "semantic_aqo - cardinality statistics capture"

OBJS = semantic_aqo.o \
       hooks/hooks_manager.o \
       hooks/planner_hook.o \
       hooks/executor_hooks.o \
       hooks/cardinality_hooks.o \
       storage/storage.o \
       utils/calc.o \
       utils/hash.o \
       utils/utils.o \
       utils/context_extractor.o \
       utils/sql_preprocessor.o

PG_CPPFLAGS = -I$(srcdir)

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```

---

## Usage Guide

### Build & Install

```bash
# 1. Copy source to contrib/
cp -r semantic-aqo/extensions/semantic-aqo postgresql-15.15/contrib/semantic_aqo

# 2. Build
cd postgresql-15.15/contrib/semantic_aqo
make

# 3. Install (requires sudo if prefix is /usr/local)
sudo make install

# 4. Configure shared_preload_libraries
echo "shared_preload_libraries = 'semantic_aqo'" >> /usr/local/pgsql/data/postgresql.conf

# 5. Restart PostgreSQL
pg_ctl -D /usr/local/pgsql/data restart

# 6. Create extension in database
psql -U postgres -d mydb -c "CREATE EXTENSION semantic_aqo;"
```

### Usage Examples

```sql
-- Enable/disable capture (session-level)
SET semantic_aqo.enabled = true;   -- Enable
SET semantic_aqo.enabled = false;  -- Disable

-- View captured statistics
SELECT id, 
       left(query_text, 80) as query,
       est_rows,
       actual_rows,
       round(error_ratio::numeric, 4) as error_ratio,
       captured_at
FROM semantic_aqo_stats
ORDER BY captured_at DESC
LIMIT 20;

-- View summary statistics
SELECT * FROM semantic_aqo_stats_summary;

-- Clear all stats
SELECT aqo_clear_stats();

-- Find queries with poor estimates (high error)
SELECT query_text, est_rows, actual_rows, error_ratio
FROM semantic_aqo_stats
WHERE error_ratio > 10 OR error_ratio < 0.1
ORDER BY error_ratio DESC;
```

---

## Table Schema: semantic_aqo_stats

| Column      | Type                     | Description                                    |
|-------------|--------------------------|------------------------------------------------|
| id          | SERIAL (PK)              | Auto-increment primary key                     |
| query_text  | TEXT                     | Full SQL query string                          |
| est_rows    | FLOAT8                   | Estimated rows from planner (plan_rows)        |
| actual_rows | BIGINT                   | Actual rows from executor (es_processed)       |
| error_ratio | FLOAT8                   | Ratio: actual_rows / est_rows                  |
| captured_at | TIMESTAMPTZ              | Timestamp when the query was captured          |

---

## Troubleshooting

### 1. Extension Not Loading

```bash
# Check shared_preload_libraries configuration
grep shared_preload /usr/local/pgsql/data/postgresql.conf

# Check PostgreSQL logs
tail -f /usr/local/pgsql/data/logfile
# Should see: "semantic_aqo: hooks registered"
```

### 2. No Data in Stats Table

```sql
-- Check if extension is enabled
SHOW semantic_aqo.enabled;

-- Enable if needed
SET semantic_aqo.enabled = true;

-- Run a SELECT query
SELECT * FROM pg_class LIMIT 5;

-- Check stats table
SELECT count(*) FROM semantic_aqo_stats;
```

### 3. Warning "transaction left non-empty SPI stack"

This warning does not affect functionality. It can be safely ignored or suppressed:

```sql
SET client_min_messages = ERROR;
```

---

## Roadmap — Phase 2

Phase 2 will implement **cardinality_hooks.c** to:

1. **Load a trained model** from a binary file
2. **Intercept** at `set_baserel_size_estimates()`
3. **Override** `rel->rows` with model predictions
4. Help PostgreSQL optimizer achieve more accurate cardinality estimates

---

## Technical Deep Dive

### Why Hooks?

PostgreSQL provides a hook-based extension mechanism that allows external code to intercept and modify the query processing pipeline without patching the core source code. The key hooks used are:

| Hook                 | Location              | Purpose                                |
|----------------------|-----------------------|----------------------------------------|
| `planner_hook`       | Before plan execution | Access to estimated row counts         |
| `ExecutorEnd_hook`   | After query execution | Access to actual row counts            |

### Why SPI?

SPI (Server Programming Interface) is PostgreSQL's internal API for executing SQL queries from C code. It provides:

- **Transaction integration** — INSERTs are part of the user's transaction
- **Memory management** — Automatic cleanup via memory contexts
- **Catalog access** — Full access to system catalogs

### Snapshot Management

When executing SQL via SPI inside a hook, there may not be an active snapshot. The snapshot is required for:

- Reading table data (MVCC visibility)
- Accessing system catalogs
- Executing any DML statements

Solution: Manually push/pop a transaction snapshot:

```c
PushActiveSnapshot(GetTransactionSnapshot());
// ... SPI operations ...
PopActiveSnapshot();
```

---

## References

- [PostgreSQL Source: src/backend/optimizer/path/costsize.c](https://github.com/postgres/postgres/blob/master/src/backend/optimizer/path/costsize.c)
- [PostgreSQL Hooks Documentation](https://wiki.postgresql.org/wiki/PostgresServerHooks)
- [SPI - Server Programming Interface](https://www.postgresql.org/docs/current/spi.html)
- [PGXS Build Infrastructure](https://www.postgresql.org/docs/current/extend-pgxs.html)
- [PostgreSQL Extension Development](https://www.postgresql.org/docs/current/extend-extensions.html)

---

*Last updated: February 26, 2026*
