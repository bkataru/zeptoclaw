#!/bin/bash
set -e

# Migration script for WhatsApp credentials from OpenClaw to ZeptoClaw
# Source: /home/user/.openclaw/credentials/
# Target: /home/user/zeptoclaw/credentials/whatsapp/

SOURCE_DIR="/home/user/.openclaw/credentials"
TARGET_DIR="/home/user/zeptoclaw/credentials/whatsapp"

echo "==> Migrating WhatsApp credentials..."

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

mkdir -p "$TARGET_DIR"

# Copy all credential files (excluding .webhook-secret which is handled separately)
if ls "$SOURCE_DIR"/*.json >/dev/null 2>&1; then
    cp -v "$SOURCE_DIR"/*.json "$TARGET_DIR/" 2>/dev/null || true
fi

if ls "$SOURCE_DIR"/*.env >/dev/null 2>&1; then
    cp -v "$SOURCE_DIR"/*.env "$TARGET_DIR/" 2>/dev/null || true
fi

# Copy any other credential files
if ls "$SOURCE_DIR"/* >/dev/null 2>&1; then
    for file in "$SOURCE_DIR"/*; do
        if [ -f "$file" ] && [[ ! "$file" =~ \.webhook-secret ]]; then
            cp -v "$file" "$TARGET_DIR/"
        fi
    done
fi

echo "✓ Credentials migration complete"
echo "  Files copied to: $TARGET_DIR"
