#!/usr/bin/env bash
# ============================================================
# 03-rebuild-and-testing-extension.sh
#
# Copies the semantic-aqo extension source into the PostgreSQL
# contrib tree, builds, installs, and runs integration tests.
# ============================================================
set -euo pipefail

# ---- Configuration ----
WORKSPACE_DIR="/workspaces/app"
EXTENSION_SRC="${WORKSPACE_DIR}/semantic-aqo/extensions/semantic-aqo"
POSTGRES_SRC="${WORKSPACE_DIR}/postgresql-15.15"
CONTRIB_DST="${POSTGRES_SRC}/contrib/semantic_aqo"
PG_BIN="/usr/local/pgsql/bin"
PG_DATA="/usr/local/pgsql/data"
CONF_FILE="${PG_DATA}/postgresql.conf"
PSQL="${PG_BIN}/psql"
PG_CTL="${PG_BIN}/pg_ctl"
TEST_DB="test"

export PATH="${PG_BIN}:${PATH}"

echo "========================================================"
echo "  semantic_aqo — Rebuild & Integration Test"
echo "========================================================"

# ============================================================
# Step 1: Copy extension source into contrib/
# ============================================================
echo ""
echo "Step 1: Copying extension source → ${CONTRIB_DST} ..."

rm -rf "${CONTRIB_DST}"
mkdir -p "${CONTRIB_DST}"
cd "${EXTENSION_SRC}"
find . -not -path './.git/*' -not -name '.git' \
       -not -name '*.o' -not -name '*.so' | while read -r f; do
    if [ -d "$f" ]; then
        mkdir -p "${CONTRIB_DST}/$f"
    else
        cp "$f" "${CONTRIB_DST}/$f"
    fi
done

echo "✅ Source copied"

# ============================================================
# Step 2: Build & install the extension
# ============================================================
echo ""
echo "Step 2: Building semantic_aqo extension ..."

cd "${CONTRIB_DST}"
export PATH="/usr/local/pgsql/bin:${PATH}"
make clean  2>/dev/null || true
make -j"$(nproc)"
sudo bash -c 'export PATH="/usr/local/pgsql/bin:${PATH}" && make install'

echo "✅ Extension built and installed"

# ============================================================
# Step 3: Configure shared_preload_libraries
# ============================================================
echo ""
echo "Step 3: Configuring shared_preload_libraries ..."

if grep -q "semantic_aqo" "${CONF_FILE}" 2>/dev/null; then
    echo "  semantic_aqo already present in postgresql.conf"
else
    # Backup config
    sudo cp "${CONF_FILE}" "${CONF_FILE}.bak.$(date +%s)"

    if grep -q "^shared_preload_libraries" "${CONF_FILE}"; then
        # Append to existing value
        sudo sed -i "s/^shared_preload_libraries = '\(.*\)'/shared_preload_libraries = '\1,semantic_aqo'/" "${CONF_FILE}"
        # Clean up double commas / leading commas
        sudo sed -i "s/= ',/= '/; s/,,/,/g" "${CONF_FILE}"
    else
        echo "shared_preload_libraries = 'semantic_aqo'" | sudo tee -a "${CONF_FILE}" > /dev/null
    fi
    echo "✅ shared_preload_libraries updated"
fi

# ============================================================
# Step 4: Restart PostgreSQL
# ============================================================
echo ""
echo "Step 4: Restarting PostgreSQL ..."

sudo -u postgres "${PG_CTL}" -D "${PG_DATA}" stop  2>/dev/null || true
sleep 2
sudo -u postgres "${PG_CTL}" -D "${PG_DATA}" -l "${PG_DATA}/logfile" start
sleep 3

echo "✅ PostgreSQL restarted"

# ============================================================
# Step 5: Create / recreate the extension
# ============================================================
echo ""
echo "Step 5: Installing extension in database '${TEST_DB}' ..."

sudo -u postgres "${PSQL}" "${TEST_DB}" <<'SQL'
DROP EXTENSION IF EXISTS semantic_aqo CASCADE;
CREATE EXTENSION semantic_aqo;

-- Verify objects exist
SELECT extname, extversion FROM pg_extension WHERE extname = 'semantic_aqo';

-- Show the stats table columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'semantic_aqo_stats'
ORDER BY ordinal_position;
SQL

echo "✅ Extension created"

echo ""
echo "========================================================"
echo "  ✅ semantic_aqo — Rebuild COMPLETE"
echo "========================================================"
echo ""
echo "  Next step: Run ./04-test-extension.sh to test the extension"
echo ""
