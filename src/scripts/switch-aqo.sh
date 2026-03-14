#!/usr/bin/env bash
# =============================================================================
# switch-aqo.sh  {standard|semantic}
#
# Swaps the active AQO extension between two variants by:
#   1. Stopping PostgreSQL
#   2. Copying the selected .so → aqo.so
#   3. Copying matching SQL/control files to share/extension/
#   4. Starting PostgreSQL
#
# Prerequisites: Run 04-standard-aqo-build.sh first to populate:
#   /usr/local/pgsql/lib/aqo_std.so
#   /usr/local/pgsql/lib/aqo_semantic.so
#
# Usage:
#   bash scripts/switch-aqo.sh standard    # activate postgrespro/aqo
#   bash scripts/switch-aqo.sh semantic    # activate semantic-aqo
#   bash scripts/switch-aqo.sh status      # show which is currently active
# =============================================================================
set -euo pipefail

POSTGRES_BIN=/usr/local/pgsql/bin
POSTGRES_LIB=/usr/local/pgsql/lib
POSTGRES_SHARE=/usr/local/pgsql/share/extension
POSTGRES_DATA=/usr/local/pgsql/data
LOGFILE="$POSTGRES_DATA/logfile"

# ── Helpers ──────────────────────────────────────────────────────────────────
pg_stop()  { sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" stop  2>/dev/null || true; sleep 2; }
pg_start() { sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" -l "$LOGFILE" start; sleep 3; }

active_variant() {
    # Compare checksums of aqo.so against known variants
    if [[ ! -f "$POSTGRES_LIB/aqo.so" ]]; then
        echo "unknown (aqo.so missing)"
        return
    fi
    local md5_active md5_std md5_sem
    md5_active=$(md5sum "$POSTGRES_LIB/aqo.so" | awk '{print $1}')
    md5_std=$(md5sum "$POSTGRES_LIB/aqo_std.so"      2>/dev/null | awk '{print $1}' || echo "x")
    md5_sem=$(md5sum "$POSTGRES_LIB/aqo_semantic.so"  2>/dev/null | awk '{print $1}' || echo "y")

    if [[ "$md5_active" == "$md5_std" ]]; then
        echo "standard (postgrespro/aqo stable15)"
    elif [[ "$md5_active" == "$md5_sem" ]]; then
        echo "semantic (semantic-aqo)"
    else
        echo "unknown (modified or untracked .so)"
    fi
}

# ── Argument handling ─────────────────────────────────────────────────────────
VARIANT="${1:-}"
if [[ -z "$VARIANT" ]]; then
    echo "Usage: $0 {standard|semantic|status}" >&2
    exit 1
fi

if [[ "$VARIANT" == "status" ]]; then
    echo "Active AQO variant: $(active_variant)"
    exit 0
fi

if [[ "$VARIANT" != "standard" && "$VARIANT" != "semantic" ]]; then
    echo "Error: unknown variant '$VARIANT'. Use 'standard' or 'semantic'." >&2
    exit 1
fi

# ── Preflight checks ──────────────────────────────────────────────────────────
if [[ "$VARIANT" == "standard" ]]; then
    SO_SRC="$POSTGRES_LIB/aqo_std.so"
    SQL_DIR="$POSTGRES_SHARE/aqo_std_sql"
else
    SO_SRC="$POSTGRES_LIB/aqo_semantic.so"
    SQL_DIR="$POSTGRES_SHARE/aqo_semantic_sql"
fi

if [[ ! -f "$SO_SRC" ]]; then
    echo "❌ $SO_SRC not found." >&2
    echo "   Run: bash scripts/04-standard-aqo-build.sh" >&2
    exit 1
fi

echo "══════════════════════════════════════════════════════════"
echo "  Switching AQO → $VARIANT"
echo "  Source: $SO_SRC"
echo "══════════════════════════════════════════════════════════"

# ── 1. Stop PostgreSQL ────────────────────────────────────────────────────────
echo ""
echo "⏹  Stopping PostgreSQL..."
pg_stop
echo "   ✅ PostgreSQL stopped"

# ── 2. Swap .so ───────────────────────────────────────────────────────────────
echo ""
echo "🔄 Installing $VARIANT AQO binary..."
sudo cp "$SO_SRC" "$POSTGRES_LIB/aqo.so"
echo "   ✅ aqo.so replaced"

# ── 3. Swap SQL / control files ───────────────────────────────────────────────
if [[ -d "$SQL_DIR" ]] && ls "$SQL_DIR"/*.sql "$SQL_DIR"/*.control &>/dev/null 2>&1; then
    echo ""
    echo "📋 Updating SQL/control files..."
    sudo cp "$SQL_DIR"/*.sql     "$POSTGRES_SHARE/" 2>/dev/null || true
    sudo cp "$SQL_DIR"/*.control "$POSTGRES_SHARE/" 2>/dev/null || true
    echo "   ✅ SQL/control files updated"
else
    echo "   ⚠️  No SQL dir at $SQL_DIR — control files unchanged"
fi

# ── 4. Start PostgreSQL ───────────────────────────────────────────────────────
echo ""
echo "🚀 Starting PostgreSQL..."
pg_start
echo "   ✅ PostgreSQL started"

# ── 5. Verify ─────────────────────────────────────────────────────────────────
echo ""
echo "🔍 Verifying AQO extension is loaded..."
# AQO is a shared_preload_libraries extension — just check it loads
PSQL="sudo -u postgres $POSTGRES_BIN/psql"
if $PSQL -d postgres -c "SELECT aqo_version();" > /dev/null 2>&1; then
    VERSION=$($PSQL -d postgres -tAc "SELECT aqo_version();" 2>/dev/null || echo "(no aqo_version fn)")
    echo "   ✅ aqo_version(): $VERSION"
else
    echo "   ℹ️  aqo_version() not available (standard AQO doesn't export it) — checking extension table..."
    $PSQL -d postgres -c "SELECT extname, extversion FROM pg_extension WHERE extname='aqo';" 2>/dev/null || true
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  ✅  AQO switched to: $VARIANT"
echo "  Active variant check: $(active_variant)"
echo "══════════════════════════════════════════════════════════"
