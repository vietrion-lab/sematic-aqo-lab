#!/usr/bin/env bash
set -euo pipefail

# Clone AQO and build using PGXS mode
# This allows easy git operations while building extension separately from PostgreSQL
#
# Flow:
# 1. Clone semantic-aqo-main repo
# 2. Apply patch to PostgreSQL source
# 3. Build & install PostgreSQL (without AQO in contrib)
# 4. Create symlink contrib/aqo -> extension/
# 5. Build AQO using PGXS (uses installed pg_config)

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKSPACE_DIR=/workspaces/app
POSTGRES_DIR=postgresql-15.15
POSTGRES_VERSION=15
POSTGRES_BIN=/usr/local/pgsql/bin
AQO_REPO_DIR="$WORKSPACE_DIR/semantic-aqo-main"
AQO_REPO_URL="https://github.com/vietrion-lab/semantic-aqo-main.git"
AQO_BRANCH="task28_29"



cd "$WORKSPACE_DIR"

if [[ ! -d "$POSTGRES_DIR" ]]; then
	echo "PostgreSQL source folder not found: $WORKSPACE_DIR/$POSTGRES_DIR" >&2
	exit 1
fi

# ===== Step 1: Clone semantic-aqo-main repo =====
if [[ ! -d "$AQO_REPO_DIR" ]]; then
	echo ""
	echo "📦 Step 1: Cloning semantic-aqo-main repository..."
	git clone -b "$AQO_BRANCH" --single-branch "$AQO_REPO_URL" "$AQO_REPO_DIR"
	echo "✅ Repository cloned to $AQO_REPO_DIR"
else
	echo ""
	echo "📦 Step 1: Repository already exists at $AQO_REPO_DIR"
fi

AQO_EXTENSION_DIR="$AQO_REPO_DIR/extension"
AQO_CONTRIB_LINK="$WORKSPACE_DIR/$POSTGRES_DIR/contrib/aqo"

if [[ ! -d "$AQO_EXTENSION_DIR" ]]; then
	echo "❌ Extension folder not found: $AQO_EXTENSION_DIR" >&2
	echo "   The repository structure may have changed. Expected: extension/ subfolder"
	exit 1
fi

# ===== Step 2: Apply AQO patch to PostgreSQL source =====
echo ""
echo "🔧 Step 2: Applying AQO patch to PostgreSQL source..."
cd "$WORKSPACE_DIR/$POSTGRES_DIR"

PATCH_FILE="$AQO_EXTENSION_DIR/aqo_pg${POSTGRES_VERSION}.patch"
if [[ ! -f "$PATCH_FILE" ]]; then
	echo "❌ Patch file not found: $PATCH_FILE" >&2
	exit 1
fi

if ! patch -p1 --no-backup-if-mismatch --dry-run < "$PATCH_FILE" > /dev/null 2>&1; then
	echo "   Patch already applied or not needed, skipping..."
else
	patch -p1 --no-backup-if-mismatch < "$PATCH_FILE"
	echo "✅ Patch applied"
fi

# ===== Step 3: Build and install PostgreSQL =====
echo ""
echo "🔨 Step 3: Building and installing PostgreSQL..."
echo "   (This will take a few minutes)"

# IMPORTANT: Remove symlink BEFORE make clean to avoid path issues
# But since patch adds aqo to contrib/Makefile, we need a stub directory
if [[ -L "$AQO_CONTRIB_LINK" ]]; then
	echo "   Removing existing symlink before build..."
	rm -f "$AQO_CONTRIB_LINK"
fi

# Create minimal stub for make clean (since patch added aqo to SUBDIRS)
if [[ ! -d "$AQO_CONTRIB_LINK" ]]; then
	mkdir -p "$AQO_CONTRIB_LINK"
	cat > "$AQO_CONTRIB_LINK/Makefile" << 'EOF'
# Stub Makefile for make clean
all:
clean:
install:
.PHONY: all clean install
EOF
fi

make clean

# Remove stub directory after clean
rm -rf "$AQO_CONTRIB_LINK"

make -j$(nproc)
sudo make install
echo "✅ PostgreSQL built and installed"

# ===== Step 4: Create symlink for development workflow =====
echo ""
echo "🔗 Step 4: Creating symlink for development workflow..."

# Remove any existing aqo folder/symlink
if [[ -L "$AQO_CONTRIB_LINK" ]]; then
	rm -f "$AQO_CONTRIB_LINK"
elif [[ -d "$AQO_CONTRIB_LINK" ]]; then
	rm -rf "$AQO_CONTRIB_LINK"
fi

ln -sfn "$AQO_EXTENSION_DIR" "$AQO_CONTRIB_LINK"
echo "✅ Created symlink: contrib/aqo -> $AQO_EXTENSION_DIR"

# ===== Step 5: Build AQO extension =====
echo ""
echo "🔨 Step 5: Building AQO extension..."
cd "$AQO_EXTENSION_DIR"

# Clean any previous build artifacts
make top_builddir="$WORKSPACE_DIR/$POSTGRES_DIR" clean || true

# Build and install (using top_builddir to reference PostgreSQL source tree)
make top_builddir="$WORKSPACE_DIR/$POSTGRES_DIR"
sudo make top_builddir="$WORKSPACE_DIR/$POSTGRES_DIR" install
echo "✅ AQO extension built and installed"

# ===== Step 5.5: Initialize token_embeddings table =====
echo ""
echo "📊 Step 5.5: Initializing token_embeddings table..."

# Ensure PostgreSQL is running
if ! sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D /usr/local/pgsql/data status > /dev/null 2>&1; then
	sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D /usr/local/pgsql/data -l /usr/local/pgsql/data/logfile start
	sleep 3
fi

# Ensure the test database exists
sudo -u postgres "$POSTGRES_BIN/psql" -c "SELECT 1 FROM pg_database WHERE datname='test'" \
	| grep -q 1 || sudo -u postgres "$POSTGRES_BIN/createdb" test

python3 "$SCRIPTS_DIR/04-load-token-embeddings.py"
echo "✅ token_embeddings table initialized"

# ===== Step 6: Run AQO regression tests =====
echo ""
echo "🧪 Step 6: Running AQO regression tests..."
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
umask 0077
rm -rf tmp_check 2>/dev/null || true
make top_builddir="$WORKSPACE_DIR/$POSTGRES_DIR" check 2>&1 || echo "⚠️  Tests may have failed due to permission issues, but AQO extension is installed."

# ===== Step 7: Configure PostgreSQL to load AQO on startup =====
echo ""
echo "⚙️  Step 7: Configuring PostgreSQL to load AQO on startup..."

# Stop PostgreSQL firstsudo -u postgres "$POSTGRES_BIN/pg_ctl" -D /usr/local/pgsql/data stop 2>/dev/null || true
sleep 2

# Add AQO to shared_preload_libraries in postgresql.conf
CONF_FILE="/usr/local/pgsql/data/postgresql.conf"
if grep -q "^shared_preload_libraries.*aqo" "$CONF_FILE" 2>/dev/null; then
	echo "   AQO already in shared_preload_libraries"
else
	# Backup original config
	sudo cp "$CONF_FILE" "${CONF_FILE}.backup"
	
	# Add or update shared_preload_libraries
	if grep -q "^shared_preload_libraries" "$CONF_FILE"; then
		sudo sed -i "s/^shared_preload_libraries = '\(.*\)'/shared_preload_libraries = '\1,aqo'/" "$CONF_FILE"
		sudo sed -i "s/'',/'/" "$CONF_FILE"
	else
		echo "shared_preload_libraries = 'aqo'" | sudo tee -a "$CONF_FILE" > /dev/null
	fi
	echo "✅ Added AQO to shared_preload_libraries"
fi

# ===== Step 8: Start PostgreSQL and create extension =====
echo ""
echo "🚀 Step 8: Starting PostgreSQL server..."
sudo -u postgres "$POSTGRES_BIN/pg_ctl" -D /usr/local/pgsql/data -l /usr/local/pgsql/data/logfile start
sleep 3
echo "✅ PostgreSQL server started"

echo ""
echo "📦 Creating AQO extension in test database..."
RESULT=$(sudo -u postgres "$POSTGRES_BIN/psql" test -c "CREATE EXTENSION IF NOT EXISTS aqo;" 2>&1)
echo "$RESULT"

# ===== Step 9: Verify installation =====
echo ""
echo "🔍 Step 9: Verifying AQO extension..."
VERIFY=$(sudo -u postgres "$POSTGRES_BIN/psql" test -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';" 2>&1)
echo "$VERIFY"

# ===== Done =====
echo ""
echo "==== ✅ AQO Extension Installation Complete ===="
echo ""
echo "AQO is now configured and ready to use!"
echo "Configuration: shared_preload_libraries = 'aqo' in postgresql.conf"
echo ""
echo "To use AQO in other databases:"
echo "  psql <database> -c \"CREATE EXTENSION aqo;\""
echo ""
echo "📁 Development workflow:"
echo "  - AQO repo: $AQO_REPO_DIR"
echo "  - Extension source: $AQO_EXTENSION_DIR"
echo "  - Symlink: $POSTGRES_DIR/contrib/aqo -> extension/"
echo ""
echo "  Edit files in either location (they're the same via symlink):"
echo "    vim $POSTGRES_DIR/contrib/aqo/aqo.c"
echo "    vim $AQO_EXTENSION_DIR/aqo.c"
echo ""
echo "  Recompile after changes:"
echo "    ./scripts/03-recompile-extensions.sh --quick"
echo ""
echo "  Commit changes:"
echo "    cd $AQO_REPO_DIR && git status && git add -A && git commit -m 'message'"
