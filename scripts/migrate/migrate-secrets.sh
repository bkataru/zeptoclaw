#!/bin/bash
set -e

# Migration script for secrets from OpenClaw to ZeptoClaw
# Source: /home/user/.openclaw/.webhook-secret
# Target: /home/user/zeptoclaw/secrets/

SOURCE_SECRET="/home/user/.openclaw/.webhook-secret"
TARGET_DIR="/home/user/zeptoclaw/secrets"
TARGET_SECRET="$TARGET_DIR/webhook-secret"
TARGET_SECRET_NEW="$TARGET_DIR/webhook-secret.new"

echo "==> Migrating secrets..."

mkdir -p "$TARGET_DIR"

# Check if source secret exists
if [ ! -f "$SOURCE_SECRET" ]; then
    echo "WARNING: Source webhook secret not found: $SOURCE_SECRET"
    echo "  Skipping migration. You may need to generate a new secret."
else
    # Copy existing webhook secret
    echo "  Copying existing webhook secret..."
    cp -v "$SOURCE_SECRET" "$TARGET_SECRET"

    # Generate a new backup secret (for rotation)
    echo "  Generating new backup secret..."
    openssl rand -hex 32 > "$TARGET_SECRET_NEW" 2>/dev/null || head -c 32 /dev/urandom | base64 > "$TARGET_SECRET_NEW"

    chmod 600 "$TARGET_SECRET" "$TARGET_SECRET_NEW"

    echo "✓ Secrets migration complete"
    echo "  Primary secret: $TARGET_SECRET"
    echo "  Backup secret:  $TARGET_SECRET_NEW"
    echo ""
    echo "NOTE: Rotate secrets by replacing the primary secret with the backup:"
    echo "  mv $TARGET_SECRET_NEW $TARGET_SECRET"
else
    echo "  To generate a new webhook secret:"
    echo "  openssl rand -hex 32 > $TARGET_SECRET"
    echo ""
    echo "✓ No secrets to migrate"
fi
