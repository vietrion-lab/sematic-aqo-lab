#!/bin/bash
set -e

echo "==== PostgreSQL Download, Build and Installation ===="

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Version variable (configurable)
POSTGRES_VERSION=${POSTGRES_VERSION:-15.15}

echo "Installing PostgreSQL version: $POSTGRES_VERSION"
echo ""

# Step 1: Download PostgreSQL source
echo "Step 1: Downloading PostgreSQL $POSTGRES_VERSION..."
cd "$PARENT_DIR"
TARBALL="postgresql-${POSTGRES_VERSION}.tar.gz"
SOURCE_DIR="postgresql-${POSTGRES_VERSION}"

if [ ! -f "$TARBALL" ]; then
    wget "https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/${TARBALL}"
else
    echo "Tarball already exists, skipping download"
fi

# Step 2: Extract source
echo "Step 2: Extracting source code..."
if [ -d "$SOURCE_DIR" ]; then
    echo "Source directory already exists, skipping extraction"
else
    tar xf "$TARBALL"
fi

cd "$SOURCE_DIR"

# Clean up tarball after successful extraction
if [ -d "$SOURCE_DIR" ]; then
    rm -f "$PARENT_DIR/$TARBALL"
    echo "✅ Tarball removed"
fi

# Step 3: Configure
echo "Step 3: Configuring PostgreSQL..."
./configure --prefix=/usr/local/pgsql

# Step 4: Build
echo "Step 4: Building PostgreSQL (using $(nproc) cores)..."
make -j$(nproc)

# Step 5: Install (requires root)
echo "Step 5: Installing PostgreSQL..."
sudo make install

# Step 6: Create postgres user (if not exists)
echo "Step 6: Creating postgres user..."
if id "postgres" &>/dev/null; then
    echo "User postgres already exists"
else
    sudo adduser --system --no-create-home --group postgres || sudo useradd -r -s /bin/bash postgres
    echo "✅ User postgres created"
fi

# Step 7: Create data directory and set permissions
echo "Step 7: Setting up data directory..."
sudo mkdir -p /usr/local/pgsql/data
sudo chown postgres:postgres /usr/local/pgsql/data
sudo chmod 700 /usr/local/pgsql/data
echo "✅ Data directory ready: /usr/local/pgsql/data"

# Step 8: Initialize database
echo "Step 8: Initializing database..."
sudo -u postgres /usr/local/pgsql/bin/initdb -D /usr/local/pgsql/data
echo "✅ Database initialized"

# Step 9: Start PostgreSQL server
echo "Step 9: Starting PostgreSQL server..."
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data -l /usr/local/pgsql/data/logfile start
sleep 2
echo "✅ PostgreSQL server started"

# Step 10: Create test database
echo "Step 10: Creating test database..."
sudo -u postgres /usr/local/pgsql/bin/createdb test
echo "✅ Test database created"

# Step 11: Verify installation
echo "Step 11: Verifying installation..."
RESULT=$(sudo -u postgres /usr/local/pgsql/bin/psql test -c "SELECT version();" 2>&1 || true)
echo "$RESULT"

# ===== Step 12: Add PostgreSQL binaries to PATH =====
echo "Step 12: Adding PostgreSQL binaries to PATH..."

# Line to add
EXPORT_LINE='export PATH=/usr/local/pgsql/bin:$PATH'

# Check if already in ~/.bashrc
if grep -Fxq "$EXPORT_LINE" ~/.bashrc; then
    echo "✅ PATH already configured in ~/.bashrc"
else
    echo "$EXPORT_LINE" >> ~/.bashrc
    echo "✅ PATH added to ~/.bashrc"
fi

# Source ~/.bashrc so current session knows PATH (optional)
source ~/.bashrc
echo "✅ PATH updated for current session"
echo "You can now run 'psql' without full path"

echo ""
echo "==== ✅ PostgreSQL $POSTGRES_VERSION Installation Complete ===="
echo ""
echo "Usage tips:"
echo "  Connect to database: /usr/local/pgsql/bin/psql -U postgres test"
echo "  Start server: sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data start"
echo "  Stop server: sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data stop"
echo "  Check status: sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data status"