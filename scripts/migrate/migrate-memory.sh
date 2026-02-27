#!/bin/bash
set -e

# Migration script for memory data from OpenClaw to ZeptoClaw
# Source: /home/user/.openclaw/workspace/memory/
# Target: /home/user/zeptoclaw/memory/

SOURCE_DIR="/home/user/.openclaw/workspace/memory"
TARGET_DIR="/home/user/zeptoclaw/memory"

echo "==> Migrating memory data..."

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

mkdir -p "$TARGET_DIR"

# Copy memory files including embeddings, FAISS index, etc.
if ls "$SOURCE_DIR"/* >/dev/null 2>&1; then
    cp -rv "$SOURCE_DIR"/. "$TARGET_DIR/"
else
    echo "  No memory files found"
fi

echo "✓ Memory migration complete"
echo "  Files copied to: $TARGET_DIR"
