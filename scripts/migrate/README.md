# ZeptoClaw Data Migration Guide

This directory contains scripts to migrate data from OpenClaw to ZeptoClaw.

## Directory Structure

```
scripts/migrate/
├── migrate-all.sh          # Master migration script (runs all migrations)
├── migrate-credentials.sh  # WhatsApp credentials migration
├── migrate-sessions.sh     # Session data migration
├── migrate-memory.sh       # Memory/embedding migration
├── migrate-secrets.sh      # Secrets migration with rotation
└── README.md              # This file

Target directories (created by scripts):
└── /home/user/zeptoclaw/
    ├── credentials/whatsapp/
    ├── sessions/
    ├── memory/
    └── secrets/
```

## Source Data

The scripts copy data from the following OpenClaw locations:

- **Credentials**: `~/.openclaw/credentials/` (JSON/ENV files)
- **Sessions**: `~/.openclaw/agents/main/sessions/` (session state)
- **Memory**: `~/.openclaw/workspace/memory/` (embeddings, FAISS index)
- **Secrets**: `~/.openclaw/.webhook-secret` (webhook verification)

## Usage

### 1. Dry Run (Recommended First)

Test the migration without making changes:

```bash
cd /home/user/zeptoclaw/scripts/migrate
./migrate-all.sh --dry-run
```

### 2. Full Migration

Run all migrations in sequence:

```bash
cd /home/user/zeptoclaw/scripts/migrate
./migrate-all.sh
```

### 3. Individual Migrations

Run specific migration scripts:

```bash
# Migrate credentials only
./migrate-credentials.sh

# Migrate sessions only
./migrate-sessions.sh

# Migrate memory only
./migrate-memory.sh

# Migrate secrets only
./migrate-secrets.sh
```

### 4. Force Mode

Skip source directory checks (use if OpenClaw directory is already removed):

```bash
./migrate-all.sh --force
```

## Post-Migration Steps

1. **Verify data**: Check that files exist in target directories:
   ```bash
   ls -la /home/user/zeptoclaw/credentials/whatsapp/
   ls -la /home/user/zeptoclaw/sessions/
   ls -la /home/user/zeptoclaw/memory/
   ```

2. **Update configuration**: Point ZeptoClaw config to the new locations:
   - Session path: `/home/user/zeptoclaw/sessions/`
   - Memory path: `/home/user/zeptoclaw/memory/`
   - Credentials path: `/home/user/zeptoclaw/credentials/whatsapp/`

3. **Test ZeptoClaw**: Start ZeptoClaw and verify functionality

4. **Secret verification**: Check webhook secret if using webhooks:
   ```bash
   cat /home/user/zeptoclaw/secrets/webhook-secret
   ```

## Troubleshooting

### "Source directory does not exist"
- Ensure OpenClaw is installed and data exists at `~/.openclaw/`
- Check directory permissions

### "No session/credential files found"
- OpenClaw may not have generated data yet
- Verify that OpenClaw has been used before migration

### Permission errors
- Run scripts with appropriate permissions
- Check that you have read access to source and write access to target

### Memory files missing
- Memory directory may be empty if no conversations have been processed
- This is normal for fresh installations

## Security Notes

- Secrets (`.webhook-secret`) are copied with restricted permissions (0600)
- A backup secret is generated during secret migration:
  - Primary: `/home/user/zeptoclaw/secrets/webhook-secret`
  - Backup: `/home/user/zeptoclaw/secrets/webhook-secret.new`
- To rotate secrets: `mv webhook-secret.new webhook-secret`

## Rollback

If migration fails or data is corrupted:

1. Keep OpenClaw data untouched until verification is complete
2. Delete ZeptoClaw data directories if needed:
   ```bash
   rm -rf /home/user/zeptoclaw/credentials
   rm -rf /home/user/zeptoclaw/sessions
   rm -rf /home/user/zeptoclaw/memory
   rm -rf /home/user/zeptoclaw/secrets
   ```
3. Re-run migration after fixing issues

## Notes

- Scripts are idempotent (safe to run multiple times)
- Existing files in target directories will be overwritten without warning
- Back up ZeptoClaw data before re-running migrations
