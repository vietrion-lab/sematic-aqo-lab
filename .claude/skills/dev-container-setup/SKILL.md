---
name: dev-container-setup
description: Bootstrap the full SAQO dev environment in a container — runs scripts 00 through 03 to install deps, build PG15, clone+build Semantic AQO, and verify.
user-invocable: true
allowed-tools: ["Bash"]
---

# Dev Container Setup

Bootstrap a complete Semantic AQO development environment from scratch inside the devcontainer.

## Prerequisites

- Running inside the devcontainer (workspace at `/workspaces/app`)
- Internet access (downloads PG source + clones semantic-aqo-main)
- `sudo` available (installs system packages, creates postgres user)

## Execution Sequence

Run the 4 scripts in order from the project root. Each script is idempotent — safe to re-run if interrupted.

### Step 1: Install System Dependencies

```bash
bash src/scripts/00-system-setup.sh
```

Installs: `build-essential`, `git`, `wget`, `curl`, `libreadline-dev`, `zlib1g-dev`, `bison`, `flex`, `python3`, `python3-pip`, `python3-venv`.

### Step 2: Build & Install PostgreSQL 15

```bash
bash src/scripts/01-postgres-clone-and-build.sh
```

Downloads PG 15.15 source, configures (`--prefix=/usr/local/pgsql`), builds with all cores, installs, creates `postgres` user, inits cluster, starts server, creates `test` database, adds PG binaries to PATH.

### Step 3: Clone & Build Semantic AQO

```bash
bash src/scripts/02-semantic-aqo-clone-and-build.sh
```

Clones `semantic-aqo-main` repo (branch `stable15`), applies AQO patch to PG source, rebuilds PG, symlinks extension into `contrib/aqo`, builds+installs AQO, configures `shared_preload_libraries = 'aqo'`, creates extension in `test` db, loads token embeddings.

### Step 4: Verify Recompile Workflow

```bash
bash src/scripts/03-recompile-extensions.sh --quick
```

Quick-rebuilds AQO only (no PG rebuild, no tests). Verifies the recompile pipeline works.

## Post-Setup Verification

```bash
# Check PG is running
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data status

# Check AQO extension is loaded
sudo -u postgres psql test -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';"

# Check token embeddings are loaded
sudo -u postgres psql test -c "SELECT count(*) FROM token_embeddings;"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Port 5432 already in use | `sudo -u postgres pg_ctl -D /usr/local/pgsql/data stop` then retry |
| Patch already applied | Script detects this automatically and skips |
| Missing `postgres` user | Script 01 creates it; if it fails, run `sudo adduser --system --no-create-home --group postgres` |
| `make check` fails | Check `src/postgresql-15.15/contrib/aqo/regression.diffs` for details |
