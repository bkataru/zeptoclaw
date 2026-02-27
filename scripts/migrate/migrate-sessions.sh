#!/bin/bash
set -e

# Migration script for session data from OpenClaw to ZeptoClaw
# Source: /home/user/.openclaw/agents/main/sessions/
# Target: /home/user/zeptoclaw/sessions/

SOURCE_DIR="/home/user/.openclaw/agents/main/sessions"
TARGET_DIR="/home/user/zeptoclaw/sessions"

echo "==> Migrating session data..."

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

mkdir -p "$TARGET_DIR"

# Copy session files (typically JSON files)
if ls "$SOURCE_DIR"/*.json >/dev/null 2>&1; then
    cp -v "$SOURCE_DIR"/*.json "$TARGET_DIR/"
else
    echo "  No JSON session files found"
fi

# Copy session database or other files
if ls "$SOURCE_DIR"/*.db >/dev/null 2>&1; then
    cp -v "$SOURCE_DIR"/*.db "$TARGET_DIR/"
fi

# Copy session log files
if ls "$SOURCE_DIR"/*.log >/dev/null 2>&1; then
    cp -v "$SOURCE_DIR"/*.log "$TARGET_DIR/"
fi

# Copy all other files
if ls "$SOURCE_DIR"/* >/dev/null 2>&1; then
    for file in "$SOURCE_DIR"/*; do
        if [ -f "$file" ]; then
            cp -v "$file" "$TARGET_DIR/"
        fi
    done
fi

echo "✓ Session migration complete"
echo "  Files copied to: $TARGET_DIR"
