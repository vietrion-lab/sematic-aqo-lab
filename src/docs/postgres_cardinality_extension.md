# PostgreSQL Cardinality Extraction Extension — semantic_aqo

## Tổng Quan

Extension `semantic_aqo` được phát triển để **tự động thu thập thống kê cardinality** (số dòng ước tính vs thực tế) sau mỗi lần thực thi truy vấn SQL trong PostgreSQL. Dữ liệu này được lưu vào bảng `semantic_aqo_stats` để phục vụ phân tích và huấn luyện mô hình machine learning cải thiện query optimizer.

### Mục Tiêu

- **Capture estimated rows** (`plan_rows`) từ planner
- **Capture actual rows** (`es_processed`) từ executor
- **Tính error ratio** = actual / estimated
- **Lưu trữ persistent** vào PostgreSQL table
- **Không ảnh hưởng** đến performance của user queries

---

## Kiến Trúc Tổng Quan

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

## Cấu Trúc File

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

## Chi Tiết Implementation

### 1. hooks/hooks_manager.c — Entry Point

Đây là file quan trọng nhất, chứa `_PG_init()` được PostgreSQL gọi khi load shared library.

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
- `planner_hook` và `ExecutorEnd_hook` là global function pointers của PostgreSQL
- Chúng ta **save** hook cũ, **install** hook mới, và **chain** khi gọi
- GUC `semantic_aqo.enabled` cho phép bật/tắt capture runtime

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
- `result->planTree->plan_rows` chứa estimated row count từ top-level plan node
- `query_string` là original SQL text
- Dùng static variables để truyền data sang executor hook (same backend)

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

            /* Skip our own stats queries */
            if (sql_text && strstr(sql_text, "semantic_aqo_stats") == NULL)
            {
                /* Persist to database */
                storage_save_query_stats(sql_text,
                                         saqo_last_est_rows,
                                         (int64) actual_rows);
            }
        }

        /* Reset for next query */
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
- `queryDesc->operation` cho biết loại command (SELECT, INSERT, UPDATE, DELETE)
- Chỉ capture SELECT để tránh noise
- Skip queries chứa "semantic_aqo_stats" để tránh infinite recursion

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
- **SPI (Server Programming Interface)** cho phép execute SQL từ C code
- **PushActiveSnapshot()** cần thiết để SPI_execute có snapshot context
- **Recursion guard** `saqo_saving_in_progress` ngăn infinite loop
- **PG_TRY/PG_CATCH** đảm bảo cleanup và không crash user queries
- **quote_literal_cstr()** escape SQL text để tránh injection

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

## Cách Sử Dụng

### Build & Install

```bash
# 1. Copy source vào contrib/
cp -r semantic-aqo/extensions/semantic-aqo postgresql-15.15/contrib/semantic_aqo

# 2. Build
cd postgresql-15.15/contrib/semantic_aqo
make

# 3. Install (cần sudo nếu prefix là /usr/local)
sudo make install

# 4. Configure shared_preload_libraries
echo "shared_preload_libraries = 'semantic_aqo'" >> /usr/local/pgsql/data/postgresql.conf

# 5. Restart PostgreSQL
pg_ctl -D /usr/local/pgsql/data restart

# 6. Create extension trong database
psql -U postgres -d mydb -c "CREATE EXTENSION semantic_aqo;"
```

### Sử Dụng

```sql
-- Bật/tắt capture (session-level)
SET semantic_aqo.enabled = true;   -- Enable
SET semantic_aqo.enabled = false;  -- Disable

-- Xem statistics đã capture
SELECT id, 
       left(query_text, 80) as query,
       est_rows,
       actual_rows,
       round(error_ratio::numeric, 4) as error_ratio,
       captured_at
FROM semantic_aqo_stats
ORDER BY captured_at DESC
LIMIT 20;

-- Xem summary
SELECT * FROM semantic_aqo_stats_summary;

-- Clear all stats
SELECT aqo_clear_stats();

-- Xem queries có error cao (bad estimates)
SELECT query_text, est_rows, actual_rows, error_ratio
FROM semantic_aqo_stats
WHERE error_ratio > 10 OR error_ratio < 0.1
ORDER BY error_ratio DESC;
```

---

## Schema Bảng semantic_aqo_stats

| Column      | Type                     | Description                              |
|-------------|--------------------------|------------------------------------------|
| id          | SERIAL (PK)              | Auto-increment ID                        |
| query_text  | TEXT                     | Full SQL query string                    |
| est_rows    | FLOAT8                   | Estimated rows from planner (plan_rows)  |
| actual_rows | BIGINT                   | Actual rows from executor (es_processed) |
| error_ratio | FLOAT8                   | actual_rows / est_rows                   |
| captured_at | TIMESTAMPTZ              | Timestamp when captured                  |

---

## Troubleshooting

### 1. Extension không load

```bash
# Kiểm tra shared_preload_libraries
grep shared_preload /usr/local/pgsql/data/postgresql.conf

# Kiểm tra log
tail -f /usr/local/pgsql/data/logfile
# Phải thấy: "semantic_aqo: hooks registered"
```

### 2. Không có data trong stats table

```sql
-- Kiểm tra extension đã enable chưa
SHOW semantic_aqo.enabled;

-- Bật lên nếu cần
SET semantic_aqo.enabled = true;

-- Chạy một SELECT query
SELECT * FROM pg_class LIMIT 5;

-- Kiểm tra lại
SELECT count(*) FROM semantic_aqo_stats;
```

### 3. Warning "transaction left non-empty SPI stack"

Đây là warning không ảnh hưởng functionality. Có thể bỏ qua hoặc giảm log level:

```sql
SET client_min_messages = ERROR;
```

---

## Roadmap - Phase 2

Phase 2 sẽ implement **cardinality_hooks.c** để:

1. **Load trained model** từ file binary
2. **Intercept** tại `set_baserel_size_estimates()` 
3. **Override** `rel->rows` với model prediction
4. Giúp PostgreSQL optimizer có cardinality estimate chính xác hơn

---

## References

- [PostgreSQL Source: src/backend/optimizer/path/costsize.c](https://github.com/postgres/postgres/blob/master/src/backend/optimizer/path/costsize.c)
- [PostgreSQL Hooks Documentation](https://wiki.postgresql.org/wiki/PostgresServerHooks)
- [SPI - Server Programming Interface](https://www.postgresql.org/docs/current/spi.html)
- [PGXS Build Infrastructure](https://www.postgresql.org/docs/current/extend-pgxs.html)

---

*Last updated: February 26, 2026*
