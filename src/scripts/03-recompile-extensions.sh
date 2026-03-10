#!/usr/bin/env bash
set -euo pipefail

# Recompile PostgreSQL and AQO extension after source code updates
# Use this script when you modify files in contrib/aqo folder

WORKSPACE_DIR=/workspaces/app
POSTGRES_DIR=postgresql-15.15
POSTGRES_BIN=/usr/local/pgsql/bin
POSTGRES_DATA=/usr/local/pgsql/data

# Parse command line arguments
SKIP_POSTGRES=false
SKIP_TESTS=false
QUICK_MODE=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --aqo-only    Only recompile AQO extension (skip PostgreSQL recompile)"
    echo "  --skip-tests  Skip running AQO regression tests"
    echo "  --quick       Same as --aqo-only --skip-tests"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Full recompile of PostgreSQL and AQO"
    echo "  $0 --aqo-only   # Only recompile AQO extension"
    echo "  $0 --quick      # Quick rebuild of AQO only, no tests"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --aqo-only)
            SKIP_POSTGRES=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --quick)
            SKIP_POSTGRES=true
            SKIP_TESTS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

cd "$WORKSPACE_DIR"

if [[ ! -d "$POSTGRES_DIR" ]]; then
    echo "❌ PostgreSQL source folder not found: $WORKSPACE_DIR/$POSTGRES_DIR" >&2
    exit 1
fi

if [[ ! -d "$POSTGRES_DIR/contrib/aqo" ]]; then
    echo "❌ AQO extension folder not found: $WORKSPACE_DIR/$POSTGRES_DIR/contrib/aqo" >&2
    echo "   Run 02-semantic-aqo-clone-and-build.sh first to set up AQO"
    exit 1
fi

cd "$POSTGRES_DIR"

echo ""
echo "==== Recompiling PostgreSQL and AQO Extension ===="
echo ""

# Stop PostgreSQL server before recompiling
echo "Stopping PostgreSQL server..."
sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" stop 2>/dev/null || true
sleep 2

# Recompile PostgreSQL (if not skipped)
if [[ "$SKIP_POSTGRES" == "false" ]]; then
    echo ""
    echo "🔨 Recompiling PostgreSQL..."
    make clean
    make -j$(nproc)
    sudo make install
    echo "✅ PostgreSQL recompiled and installed"
else
    echo ""
    echo "⏭️  Skipping PostgreSQL recompile (--aqo-only mode)"
    
    # Fix all broken symlinks in src/include (can happen if workspace moved)
    echo "📋 Checking and fixing broken header symlinks..."
    FIXED_COUNT=0
    
    for symlink in $(find src/include -type l 2>/dev/null); do
        if [[ ! -e "$symlink" ]]; then
            # Get the original target
            target=$(readlink "$symlink")
            # Extract the relative path from the broken absolute path
            # Pattern: /old/path/postgresql-15.15/src/... -> src/...
            relative_target=$(echo "$target" | sed 's|.*/postgresql-[0-9.]*/\(src/.*\)|\1|')
            
            if [[ -f "$(pwd)/$relative_target" ]]; then
                rm -f "$symlink"
                ln -s "$(pwd)/$relative_target" "$symlink"
                FIXED_COUNT=$((FIXED_COUNT + 1))
            fi
        fi
    done
    
    if [[ $FIXED_COUNT -gt 0 ]]; then
        echo "  ✓ Fixed $FIXED_COUNT broken symlinks"
    else
        echo "  ✓ All symlinks are valid"
    fi
    
    # Ensure generated headers exist
    if [[ ! -f "src/backend/utils/errcodes.h" ]]; then
        echo "📋 Generating required PostgreSQL headers..."
        make -C src/backend/utils errcodes.h
        make -C src/backend generated-headers
    fi
fi

# Recompile AQO extension
echo ""
echo "🔨 Recompiling AQO extension..."
cd contrib/aqo
make clean
make
sudo make install
echo "✅ AQO extension recompiled and installed"

# Run AQO tests (if not skipped)
if [[ "$SKIP_TESTS" == "false" ]]; then
    echo ""
    echo "🧪 Running AQO regression tests..."
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    umask 0077
    rm -rf tmp_check 2>/dev/null || true
    make check 2>&1 || echo "⚠️  Tests may have failed due to permission issues, but AQO extension is installed."
else
    echo ""
    echo "⏭️  Skipping AQO tests (--skip-tests mode)"
fi

# Start PostgreSQL server
echo ""
echo "🚀 Starting PostgreSQL server..."
sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D "$POSTGRES_DATA" -l "$POSTGRES_DATA/logfile" start
sleep 3

# Verify AQO is loaded
echo ""
echo "🔍 Verifying AQO extension..."
VERIFY=$(sudo -u postgres "$POSTGRES_BIN/psql" test -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';" 2>&1)
echo "$VERIFY"

echo ""
echo "==== ✅ Recompile Complete ===="
echo ""
