---
name: makefile-pgxs
description: PGXS dual-mode Makefile for PG extensions: key variables, build/install/check commands, .control file, SQL migration naming, test config.
user-invocable: false
---

# Makefile & PGXS Build System

## Dual-Mode Makefile Template

Supports both in-tree (`contrib/`) and external (`USE_PGXS=1`) builds:

```makefile
MODULE_big = myext
OBJS = myext.o utils.o $(WIN32RES)

EXTENSION = myext
DATA = myext--1.0.sql myext--1.0--1.1.sql
PGFILEDESC = "My Cool Extension"

REGRESS = init mytest1 mytest2
# EXTRA_REGRESS_OPTS = --temp-config=$(top_srcdir)/contrib/myext/myext.conf

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/myext
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
```

## Key Variables

| Variable | Purpose | Example |
| :--- | :--- | :--- |
| `MODULES` | Simple extensions (1 C file = 1 SO file) | `MODULES = simple_ext` |
| `MODULE_big` | Complex extensions (Multiple C files -> 1 SO file) | `MODULE_big = myext` |
| `OBJS` | List of object files to compile (Use with `MODULE_big`) | `OBJS = a.o b.o c.o` |
| `EXTENSION` | The extension name (Must match `.control` file) | `EXTENSION = aqo` |
| `DATA` | SQL script files to install in `share/extension` | `DATA = aqo--1.0.sql aqo--1.0--1.1.sql` |
| `REGRESS` | List of SQL regression tests in `sql/` (Without `.sql`) | `REGRESS = test_basic test_advanced` |
| `TAP_TESTS` | Run Perl TAP tests in `t/` | `TAP_TESTS = 1` |
| `PG_CPPFLAGS` | Extra C compiler flags (e.g. Include paths) | `PG_CPPFLAGS = -I$(libpq_srcdir)` |
| `EXTRA_INSTALL` | Other extensions needed for `make check` | `EXTRA_INSTALL = contrib/pg_stat_statements` |
| `EXTRA_REGRESS_OPTS` | Custom configuration for `pg_regress` | `--temp-config=aqo.conf` |

## Build Commands

| Command | Action |
| :--- | :--- |
| `make` | Compile the extension locally |
| `make install` | Copy `.so`, `.control`, and `.sql` files to PostgreSQL installation |
| `make check` | Run regression tests in a temporary database instance |
| `make clean` | Remove compiled object files |

## The `.control` File Format

Must be named `myext.control`.

```ini
# myext extension
comment = 'My custom PostgreSQL extension'
default_version = '1.0'
module_pathname = '$libdir/myext'
relocatable = true
```

*   `relocatable = true`: Allows `ALTER EXTENSION myext SET SCHEMA new_schema;`
*   `relocatable = false`: Extension must stay in the schema it was installed into (Required if your extension creates objects that depend on a specific schema).

## SQL Script Naming Conventions

*   **Initial Install**: `myext--1.0.sql` (Matches `default_version` in `.control`)
*   **Update**: `myext--1.0--1.1.sql` (Executed when user runs `ALTER EXTENSION myext UPDATE TO '1.1';`)

## Regression Testing Configuration

If your extension requires custom `postgresql.conf` settings to run tests (e.g., `shared_preload_libraries`), create a config file:

**myext.conf**:
```ini
shared_preload_libraries = 'myext'
myext.mode = 'auto'
```

And reference it in the `Makefile`:
```makefile
EXTRA_REGRESS_OPTS = --temp-config=$(top_srcdir)/contrib/myext/myext.conf
```

## Quick Recompile Workflow (SAQO Specific)

When iterating on C code in SAQO, use the provided script to skip the full PG compile step:

```bash
cd src/scripts
./03-recompile-extensions.sh --quick
```

This only recompiles `contrib/aqo` and copies it over, bypassing the main PG source tree.
