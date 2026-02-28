# Restoring from StateStore Backup

## Prerequisites

- Regular StateStore backups exist (automated or manual)
- Access to backup files (usually in `~/.local/share/zeptoclaw/backups/`)
- Systemd user permissions to stop/start services
- Understanding of data loss implications (state since last backup will be lost)

## Overview

ZeptoClaw persists state using StateStore:
- Session data
- Memory embeddings (vector database)
- Skill-specific state (e.g., knowledge base indexes)
- Workspace changes

This runbook covers restoring state from a backup after:
- Data corruption
- Accidentally deleted state
- Failed migration or upgrade
- Disk failure (restore to new machine)

---

## Step 1: Assess Current State

### Check Current State Directory

```bash
STATE_DIR="$HOME/.local/share/zeptoclaw/state"
BACKUP_DIR="$HOME/.local/share/zeptoclaw/backups"

ls -la "$STATE_DIR"
```

**Expected structure:**
```
state/
├── sessions/
├── memory/
├── skills/
└── metadata.json
```

### Determine Backup Availability

```bash
ls -la "$BACKUP_DIR"
```

**Expected:**
```
backups/
├── 20260228-143022/
│   ├── commit.txt
│   └── state/ (copy of state dir)
└── 20260227-090011/
```

If no backups exist, see **Without Backups** section below.

---

## Step 2: Stop Services

```bash
# Stop all ZeptoClaw services to prevent state modifications during restore
systemctl --user stop zeptoclaw-gateway.service
systemctl --user stop zeptoclaw-webhook.service
systemctl --user stop zeptoclaw-shell2http.service
systemctl --user stop whatsapp-responder.service
systemctl --user stop moltbook-heartbeat.service
systemctl --user stop gateway-watchdog.service

# Verify all stopped
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*' | grep -v inactive | wc -l
# Should output 0
```

---

## Step 3: Select Backup to Restore

### List Available Backups

```bash
# Sort by date (newest first)
ls -t "$BACKUP_DIR"
```

### Verify Backup Integrity

```bash
# Check latest backup structure
LATEST_BACKUP=$(ls -t "$BACKUP_DIR" | head -1)
ls -la "$BACKUP_DIR/$LATEST_BACKUP/state/"
```

Ensure `state/` directory exists and contains typical files (sessions/, memory/, etc.).

### (Optional) Inspect Backup Contents

```bash
# Preview what will be restored
ls "$BACKUP_DIR/$LATEST_BACKUP/state/"
tree "$BACKUP_DIR/$LATEST_BACKUP/state/" 2>/dev/null || find "$BACKUP_DIR/$LATEST_BACKUP/state/" -type f | head -20
```

---

## Step 4: Restore State

### Backup Current State (before overwriting)

```bash
# Create emergency backup of current (possibly corrupted) state
CORRUPT_BACKUP="$BACKUP_DIR/corrupt-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CORRUPT_BACKUP"
cp -r "$STATE_DIR" "$CORRUPT_BACKUP/"
echo "Corrupted state backed up to: $CORRUPT_BACKUP"
```

### Restore from Selected Backup

```bash
# Remove current state (WARNING: irreversible)
rm -rf "$STATE_DIR"

# Copy backup state to live location
cp -r "$BACKUP_DIR/$LATEST_BACKUP/state" "$STATE_DIR"

# Verify permissions (agent user must have read/write)
chmod 700 "$STATE_DIR"
chmod -R 600 "$STATE_DIR"/* 2>/dev/null || true
```

**Alternative:** Use rsync for incremental restore (if partial state preserved):
```bash
rsync -av "$BACKUP_DIR/$LATEST_BACKUP/state/" "$STATE_DIR/"
```

---

## Step 5: Verify Restored State

```bash
# List restored files to ensure copy succeeded
ls -la "$STATE_DIR"
ls -la "$STATE_DIR/sessions/" | head
ls -la "$STATE_DIR/memory/" | head
```

Check metadata (if exists):

```bash
if [ -f "$STATE_DIR/metadata.json" ]; then
  cat "$STATE_DIR/metadata.json" | head -20
fi
```

---

## Step 6: Start Services

```bash
# Start services in normal order
systemctl --user start zeptoclaw-gateway.service
systemctl --user start zeptoclaw-webhook.service
systemctl --user start zeptoclaw-shell2http.service
systemctl --user start gateway-watchdog.service
systemctl --user start whatsapp-responder.service
systemctl --user start moltbook-heartbeat.service

# Enable timers if not already
systemctl --user enable --now gateway-watchdog.timer whatsapp-responder.timer moltbook-heartbeat.timer workspace-sync.timer
```

---

## Step 7: Validate Restore

### Check Health

```bash
# Wait for startup
sleep 5

curl -s http://localhost:18789/health | jq .status
# Expected: "healthy"
```

### Verify Sessions Restored

```bash
# If sessions feature used:
./zig-out/bin/zeptoclaw --list-sessions 2>/dev/null | head -10
# Or check via API/CLI that recent sessions appear
```

### Verify Memory Indexes

```bash
# If memory tree search skill used:
curl -s http://localhost:18789/v1/skills/memory-tree-search/handleTree | jq .
# Should return existing tree structure without errors
```

### Check Metrics

```bash
curl -s http://localhost:18789/metrics | grep -E 'sessions_total|memory_items'
# Ensure metrics restore to pre-incident levels (approx)
```

---

## Step 8: Monitor for Issues

```bash
# Watch logs for 10 minutes for errors related to state loading
journalctl --user -u zeptoclaw-gateway -f &
LOG_PID=$!

sleep 600

# Check if any errors occurred
journalctl --user -u zeptoclaw-gateway --since "10 minutes ago" | grep -i 'state\|load\|restore\|corrupt' | tail -20

kill $LOG_PID 2>/dev/null
```

---

## Without Backups

If no StateStore backup exists:

1. Accept data loss from last known good state (might be empty initial state)
2. Start with fresh state:
   ```bash
   rm -rf "$STATE_DIR"
   mkdir -p "$STATE_DIR"
   systemctl --user start zeptoclaw-gateway.service
   ```
3. Sessions and memory will be lost; agent starts fresh.
4. Communicate to users about lost conversations/sessions.

### Prevent Future Data Loss

Set up automated backups:

```bash
# Already implemented? Check workspace-sync.timer
systemctl --user status workspace-sync.timer
# This timer should periodically backup state to cloud or remote.

# If not, see configuration in autonomous/state_store.zig for backup settings.
```

---

## Restoring to New Machine

If original host lost:

1. Install Zig 0.15.2, clone repo, build binaries
2. Install systemd services on new host
3. Copy backup directory from remote storage to `~/.local/share/zeptoclaw/backups/`
4. Follow steps 2-7 above
5. Update DNS or load balancer to point to new host

---

## Rollback (if restore was incorrect)

If restored backup is wrong or corrupted:

```bash
# Stop services
systemctl --user stop zeptoclaw-gateway.service

# Restore the "corrupt-backup" created in Step 4 (if still exists)
if [ -d "$CORRUPT_BACKUP" ]; then
  rm -rf "$STATE_DIR"
  cp -r "$CORRUPT_BACKUP/state" "$STATE_DIR"
  echo "Rolled back to pre-restore state"
fi

# Restart
systemctl --user start zeptoclaw-gateway.service
```

---

## References

- [Deploying New Version](/runbooks/deploying-new-version.md) for backup location details
- [Configuration](/runbooks/updating-configuration.md) for state directory location configuration
- StateStore implementation: `src/autonomous/state_store.zig`

---

## Quick Commands Reference

```bash
# Stop all services
systemctl --user stop --all

# List backups
ls -t ~/.local/share/zeptoclaw/backups/

# Restore latest
rm -rf ~/.local/share/zeptoclaw/state
cp -r ~/.local/share/zeptoclaw/backups/$(ls -t ~/.local/share/zeptoclaw/backups/ | head -1)/state ~/.local/share/zeptoclaw/state/

# Start services
systemctl --user start zeptoclaw-gateway.service

# Verify
curl http://localhost:18789/health
```
