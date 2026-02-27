#!/bin/bash
set -e

# Master migration script - runs all migration scripts in order
# Usage: ./migrate-all.sh [--dry-run] [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
FORCE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo "========================================"
echo "ZeptoClaw Data Migration"
echo "========================================"
echo ""

# Check if source OpenClaw directories exist
if [ $FORCE -eq 0 ]; then
    if [ ! -d "/home/user/.openclaw" ]; then
        echo "ERROR: OpenClaw data directory not found: /home/user/.openclaw"
        echo "       Make sure OpenClaw is installed and has data."
        exit 1
    fi
fi

SCRIPTS=(
    "migrate-credentials.sh"
    "migrate-sessions.sh"
    "migrate-memory.sh"
    "migrate-secrets.sh"
)

for script in "${SCRIPTS[@]}"; do
    echo ""
    echo "--- Running $script ---"
    if [ $DRY_RUN -eq 1 ]; then
        echo "[DRY RUN] Would execute: $SCRIPT_DIR/$script"
    else
        bash "$SCRIPT_DIR/$script"
    fi
done

echo ""
echo "========================================"
echo "Migration completed successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Verify migrated data in /home/user/zeptoclaw/"
echo "2. Update ZeptoClaw configuration if needed"
echo "3. Test ZeptoClaw functionality"
echo ""
