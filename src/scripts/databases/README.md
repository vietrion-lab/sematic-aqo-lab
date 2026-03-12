# Benchmark Database Setup

Scripts to create and populate TPC-H and TPC-DS benchmark databases for the Semantic-AQO experiment.

## Scripts

| Script | Database | Scale Factor | Data Size |
|--------|----------|-------------|-----------|
| `01-setup-tpch-1gb.sh` | `tpch` | SF=1 | ~1 GB |
| `02-setup-tpcds-1gb.sh` | `tpcds` | SF=1 | ~1 GB |

## What Each Script Does

1. **Install build dependencies** (`build-essential`, `git`)
2. **Download & build** data generator (`dbgen` for TPC-H, `dsqgen` for TPC-DS)
3. **Generate data** at the specified scale factor
4. **Create database** and load schema + data
5. **Analyze tables** (update PostgreSQL statistics)
6. **Generate query variants** — 22 templates × 20 seeds (TPC-H) or 99 templates × 20 seeds (TPC-DS)
7. **Validate queries** — each query is executed against the database:
   - Timeout: **60 seconds** per query (industry standard for SF=1)
   - stdout → `/dev/null` (avoids OOM from large result sets)
   - Only passing queries are copied to the final `queries/` directory
   - Failed/timed-out queries are skipped (not written)

## Usage

```bash
# From repo root
./scripts/databases/01-setup-tpch-1gb.sh
./scripts/databases/02-setup-tpcds-1gb.sh
```

Each script takes ~10-20 minutes depending on hardware (data generation + query validation).

## Output

- Database `tpch` or `tpcds` created in PostgreSQL
- Validated queries written to `experiment/tpch/queries/` or `experiment/tpcds/queries/`

## Connecting

```bash
# TPC-H
sudo -u postgres /usr/local/pgsql/bin/psql -d tpch

# TPC-DS
sudo -u postgres /usr/local/pgsql/bin/psql -d tpcds

# List all databases
sudo -u postgres /usr/local/pgsql/bin/psql -l
```

## Table Inspection

Inside `psql`:

```sql
\dt                    -- list tables
\d lineitem            -- describe a table
SELECT count(*) FROM lineitem;  -- check row counts
```

# Check row counts (sample)

TPC-H:

```sql
SELECT COUNT(*) FROM lineitem;
SELECT COUNT(*) FROM orders;
```

TPC-DS:

```sql
SELECT COUNT(*) FROM store_sales;
SELECT COUNT(*) FROM catalog_sales;
SELECT COUNT(*) FROM web_sales;
```

---

# Exit PostgreSQL

```sql
\q
```
