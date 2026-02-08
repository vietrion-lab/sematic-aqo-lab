# POSTGRES COMMAND GUIDANCES

## 1. Server Management Commands
```bash
# Start PostgreSQL server
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data start

# Stop PostgreSQL server
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data stop

# Restart PostgreSQL server
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data restart

# Check server status
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data status

# View server logs
cat /usr/local/pgsql/data/logfile

```


## 2. Connecting to PosgreSQL
```bash
# Connect to default database
psql -U postgres -d postgres

# Connect to a specific database
psql -U postgres -d test

# Connect with host and port
psql -h localhost -p 5432 -U postgres -d test

# Exit psql
\q

```


## 3. Database Management
```bash
# Create a new database
createdb -U postgres mydb
# Or in SQL
psql -U postgres -c "CREATE DATABASE mydb;"

# Drop a database
dropdb -U postgres mydb
# Or in SQL
psql -U postgres -c "DROP DATABASE mydb;"

# List all databases
psql -U postgres -c "\l"

```

## 4. PostgreSQL Configuration Files
- Main config: `/usr/local/pgsql/data/postgresql.conf`
- Authentication: `/usr/local/pgsql/data/pg_hba.conf`

```bash
# postgresql.conf
port = 5432
listen_addresses = 'localhost'
max_connections = 100
shared_buffers = 128MB
work_mem = 4MB
```

```bash
# pg_hba.conf (local authentication)
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
```

## 5. PostgreSQL Command Shortcuts
| Shortcut                                 | Description                                             |
| ---------------------------------------- | ------------------------------------------------------- |
| `\l` or `\list`                          | List all databases                                      |
| `\c dbname`                              | Connect to a specific database                          |
| `\dt`                                    | List all tables in the current database                 |
| `\d tablename`                           | Describe table structure, columns, indexes, constraints |
| `\dv`                                    | List views                                              |
| `\di`                                    | List indexes                                            |
| `\ds`                                    | List sequences                                          |
| `\df`                                    | List functions                                          |
| `\du`                                    | List all roles / users                                  |
| `\dn`                                    | List schemas                                            |
| `\dp`                                    | Show table privileges                                   |
| `\x`                                     | Toggle expanded output (nice for wide tables)           |
| `\q`                                     | Quit psql                                               |
| `\h`                                     | Show SQL syntax help (e.g., `\h CREATE TABLE`)          |
| `\copy table TO 'file.csv' CSV HEADER`   | Export table data to CSV                                |
| `\copy table FROM 'file.csv' CSV HEADER` | Import CSV into table                                   |
| `\timing`                                | Toggle query execution timing                           |
| `\set AUTOCOMMIT on/off`                 | Turn autocommit on or off                               |
| `\password username`                     | Set/change password for a user                          |
