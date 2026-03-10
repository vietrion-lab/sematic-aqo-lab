#!/usr/bin/env bash
set -euo pipefail

# Master setup script - runs all setup scripts in sequence (00-02)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "====================================="
echo "PostgreSQL + AQO Full Setup"
echo "====================================="

# Array of setup scripts to run
SCRIPTS=(
	"00-system-setup.sh"
	"01-postgres-clone-and-build.sh"
	"02-semantic-aqo-clone-and-build.sh"
)

# Run each script
for script in "${SCRIPTS[@]}"; do
	SCRIPT_PATH="$SCRIPT_DIR/$script"
	
	if [[ ! -f "$SCRIPT_PATH" ]]; then
		echo "Error: Script not found: $SCRIPT_PATH" >&2
		exit 1
	fi
	
	echo ""
	echo "====================================="
	echo "Running: $script"
	echo "====================================="
	
	if bash "$SCRIPT_PATH"; then
		echo "✓ $script completed successfully"
	else
		echo "✗ $script failed with exit code $?" >&2
		exit 1
	fi
done

echo ""
echo "====================================="
echo "✓ All setup scripts completed!"
echo "====================================="
