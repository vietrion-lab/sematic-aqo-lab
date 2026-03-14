#!/usr/bin/env bash
# =============================================================================
# 04-standard-aqo-build.sh
#
# Clone postgrespro/aqo (stable15), build & install it as the ACTIVE aqo
# extension, then back up both binaries for switching:
#   /usr/local/pgsql/lib/aqo_std.so      ← standard AQO
#   /usr/local/pgsql/lib/aqo_semantic.so ← semantic AQO backup
#
# This script runs AFTER semantic-aqo experiments are done.
# It does a full aqo_reset + DROP EXTENSION on each DB before switching.
#
# Usage: bash scripts/04-standard-aqo-build.sh
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
PG_SRC="$WORKSPACE_DIR/postgresql-15.15"
POSTGRES_BIN=/usr/local/pgsql/bin
POSTGRES_LIB=/usr/local/pgsql/lib
POSTGRES_SHARE=/usr/local/pgsql/share/extension
POSTGRES_DATA=/usr/local/pgsql/data
LOGFILE="$POSTGRES_DATA/logfile"

STANDARD_AQO_URL="https://github.com/postgrespro/aqo.git"
STANDARD_AQO_BRANCH="stable15"
STANDARD_AQO_DIR="$WORKSPACE_DIR/aqo-standard"
AQO_CONTRIB_LINK="$PG_SRC/contrib/aqo"

PSQL="sudo -u postgres $POSTGRES_BIN/psql"
pg_stop()  { sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" stop  2>/dev/null || true; sleep 2; }
pg_start() { sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" -l "$LOGFILE" start; sleep 3; }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       Standard AQO (postgrespro/aqo stable15) Build      ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── 1. Clone ─────────────────────────────────────────────────────────────────
echo ""
echo "📦 Step 1: Clone postgrespro/aqo (stable15)..."
if [[ -d "$STANDARD_AQO_DIR" ]]; then
    echo "   Already cloned — pulling latest..."
    cd "$STANDARD_AQO_DIR"
    git fetch origin
    git checkout "$STANDARD_AQO_BRANCH"
    git pull origin "$STANDARD_AQO_BRANCH"
else
    git clone -b "$STANDARD_AQO_BRANCH" --single-branch \
        "$STANDARD_AQO_URL" "$STANDARD_AQO_DIR"
fi
echo "   ✅ Repo ready at $STANDARD_AQO_DIR"

# ── 2. Verify PG source exists ───────────────────────────────────────────────
echo ""
echo "🔍 Step 2: Checking PostgreSQL source tree..."
[[ -d "$PG_SRC" ]] || { echo "❌ $PG_SRC not found"; exit 1; }
echo "   ✅ Found $PG_SRC"

# ── 2.5. Fix any broken symlinks in PG source (from devcontainer migration) ──
echo ""
echo "🔗 Step 2.5: Fixing broken PG source symlinks..."
FIXED=0
while IFS= read -r -d '' lnk; do
    if [[ ! -e "$lnk" ]]; then
        rel=$(readlink "$lnk" | sed 's|.*/postgresql-[0-9.]*\/\(.*\)|\1|')
        if [[ -f "$PG_SRC/$rel" ]]; then
            rm -f "$lnk"; ln -s "$PG_SRC/$rel" "$lnk"; FIXED=$((FIXED+1))
        fi
    fi
done < <(find "$PG_SRC/src/include" -type l -print0 2>/dev/null)
echo "   Fixed $FIXED broken symlinks"

# ── 3. Swap contrib/aqo symlink to standard AQO ──────────────────────────────
echo ""
echo "🔗 Step 3: Pointing contrib/aqo → standard AQO..."
rm -rf "$AQO_CONTRIB_LINK"
ln -sfn "$STANDARD_AQO_DIR" "$AQO_CONTRIB_LINK"
echo "   contrib/aqo → $STANDARD_AQO_DIR"

# ── 4. Build (GCC 14 safe: suppress pointer-type error, no code changes) ─────
echo ""
echo "🔨 Step 4: Building standard AQO..."
cd "$STANDARD_AQO_DIR"
make top_builddir="$PG_SRC" clean 2>/dev/null || true
# PG_CFLAGS override suppresses GCC 14 incompatible-pointer-types default error.
# This is a compiler flag, not a source code change.
make top_builddir="$PG_SRC" -j"$(nproc)" \
    PG_CFLAGS="-Wno-incompatible-pointer-types"
echo "   ✅ Build successful"

# ── 5. Save standard AQO .so aside (backup semantic .so too) ─────────────────
echo ""
echo "💾 Step 5: Saving binaries..."
sudo cp "$STANDARD_AQO_DIR/aqo.so"  "$POSTGRES_LIB/aqo_std.so"
echo "   Saved: $POSTGRES_LIB/aqo_std.so"
if [[ -f "$POSTGRES_LIB/aqo.so" ]]; then
    sudo cp "$POSTGRES_LIB/aqo.so" "$POSTGRES_LIB/aqo_semantic.so"
    echo "   Saved: $POSTGRES_LIB/aqo_semantic.so"
fi

# Save SQL/control for each variant
sudo mkdir -p "$POSTGRES_SHARE/aqo_std_sql"
sudo cp "$STANDARD_AQO_DIR"/*.sql "$POSTGRES_SHARE/aqo_std_sql/" 2>/dev/null || true
sudo cp "$STANDARD_AQO_DIR"/*.control "$POSTGRES_SHARE/aqo_std_sql/" 2>/dev/null || true

SEMANTIC_EXT="$WORKSPACE_DIR/semantic-aqo-main/extension"
sudo mkdir -p "$POSTGRES_SHARE/aqo_semantic_sql"
sudo cp "$SEMANTIC_EXT"/*.sql "$POSTGRES_SHARE/aqo_semantic_sql/" 2>/dev/null || true
sudo cp "$SEMANTIC_EXT"/*.control "$POSTGRES_SHARE/aqo_semantic_sql/" 2>/dev/null || true
echo "   ✅ SQL/control files backed up"

# ── 6. Switch active .so to standard AQO ─────────────────────────────────────
echo ""
echo "🔄 Step 6: Installing standard AQO as active aqo.so..."
pg_stop
sudo cp "$POSTGRES_LIB/aqo_std.so" "$POSTGRES_LIB/aqo.so"
sudo cp "$POSTGRES_SHARE/aqo_std_sql"/*.sql     "$POSTGRES_SHARE/" 2>/dev/null || true
sudo cp "$POSTGRES_SHARE/aqo_std_sql"/*.control "$POSTGRES_SHARE/" 2>/dev/null || true
pg_start
echo "   ✅ Standard AQO installed and PostgreSQL restarted"

# ── 7. Restore contrib/aqo → semantic AQO for future builds ──────────────────
rm -f "$AQO_CONTRIB_LINK"
ln -sfn "$SEMANTIC_EXT" "$AQO_CONTRIB_LINK"
echo ""
echo "   Restored contrib/aqo → semantic-aqo-main/extension"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Standard AQO is now the active aqo.so               ║"
echo "║                                                          ║"
echo "║  Use switch-aqo.sh to swap at any time:                 ║"
echo "║    bash scripts/switch-aqo.sh standard                  ║"
echo "║    bash scripts/switch-aqo.sh semantic                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
