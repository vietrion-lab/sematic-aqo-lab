# PostgreSQL Benchmark Databases

This project sets up two benchmark datasets:

* **TPC-H (1GB)**
* **TPC-DS (1GB)**

Run the setup scripts:

```bash
./scripts/databases/01-setup-tpch-1gb.sh
./scripts/databases/02-setup-tpcds-1gb.sh
```

---

# Connect to PostgreSQL

TPC-H

```bash
sudo -u postgres /usr/local/pgsql/bin/psql -d tpch
```

TPC-DS

```bash
sudo -u postgres /usr/local/pgsql/bin/psql -d tpcds
```

---

# List all databases

```bash
sudo -u postgres /usr/local/pgsql/bin/psql -l
```

---

# List tables in current database

Inside `psql`:

```sql
\dt
```

---

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
