# Deploying New Version

## Prerequisites

- Current version deployed and running
- New version built (`zig build -Drelease-safe`)
- Backup of current binaries and state (see [Restoring from Backup](/runbooks/restoring-from-backup.md))
- Sufficient disk space for new binaries
- Maintenance window or zero-downtime deployment capability (optional)

## Overview

This runbook covers deploying a new version of ZeptoClaw with minimal downtime. We use systemd for controlled restarts and health checks to verify successful deployment.

---

## Step 1: Prepare New Version

```bash
# Navigate to project directory
cd /home/user/zeptoclaw

# Pull latest changes (if from git)
git pull origin main

# Build release binaries
zig build -Drelease-safe

# Verify all 4 binaries exist and are executable
ls -lh zig-out/bin/zeitgeist zeptoclaw-gateway zeptoclaw-webhook zeptoclaw-shell2http

# Check build succeeded (exit code 0)
if [ $? -ne 0 ]; then
  echo "Build failed! Aborting deployment."
  exit 1
fi
```

---

## Step 2: Verify Binaries Before Deploy

```bash
# Optional: smoke test each binary (quick start/stop)
./zig-out/bin/zeptoclaw --version || { echo "zeptoclaw binary invalid"; exit 1; }
./zig-out/bin/zeptoclaw-gateway --version || { echo "gateway binary invalid"; exit 1; }
./zig-out/bin/zeptoclaw-webhook --version || { echo "webhook binary invalid"; exit 1; }
./zig-out/bin/zeptoclaw-shell2http --version || { echo "shell2http binary invalid"; exit 1; }
```

**Note:** If `--version` flag not supported, test with `--help` or simply verify binary loads without error using a short timeout test.

---

## Step 3: Stop Services Gracefully

```bash
# Stop in reverse dependency order (if using all services)
systemctl --user stop zeptoclaw-shell2http.service
systemctl --user stop zeptoclaw-webhook.service
systemctl --user stop zeptoclaw-gateway.service
systemctl --user stop gateway-watchdog.service
systemctl --user stop whatsapp-responder.service
systemctl --user stop moltbook-heartbeat.service

# Verify all stopped
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*' | grep -v inactive
```

**Expected:** All services show `inactive` or `dead`.

---

## Step 4: Backup Current State and Binaries

```bash
# Create timestamped backup directory
BACKUP_DIR="$HOME/.local/share/zeptoclaw/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup current binaries
cp zig-out/bin/zeitgeist "$BACKUP_DIR/" 2>/dev/null || true
cp zig-out/bin/zeptoclaw-gateway "$BACKUP_DIR/"
cp zig-out/bin/zeptoclaw-webhook "$BACKUP_DIR/"
cp zig-out/bin/zeptoclaw-shell2http "$BACKUP_DIR/"

# Backup state (StateStore)
# Default location: ~/.local/share/zeptoclaw/state/
if [ -d "$HOME/.local/share/zeptoclaw/state" ]; then
  cp -r "$HOME/.local/share/zeptoclaw/state" "$BACKUP_DIR/"
fi

# Record which commit was deployed
git rev-parse HEAD > "$BACKUP_DIR/commit.txt"

echo "Backup saved to: $BACKUP_DIR"
```

---

## Step 5: Deploy New Binaries

```bash
# Replace binaries (no need to rebuild - already built)
# Binaries are already in zig-out/bin/, just ensure they are executable
chmod 755 zig-out/bin/*

# If using a different installation prefix, copy to /usr/local/bin or similar:
# sudo cp zig-out/bin/* /usr/local/bin/
```

**Note:** For user services, binaries in `~/zeptoclaw/zig-out/bin/` are fine. Services reference absolute paths.

---

## Step 6: Start Services

```bash
# Start in dependency order
systemctl --user start zeptoclaw-gateway.service
systemctl --user start zeptoclaw-webhook.service
systemctl --user start zeptoclaw-shell2http.service
systemctl --user start gateway-watchdog.service
systemctl --user start whatsapp-responder.service
systemctl --user start moltbook-heartbeat.service

# Also start timers (they are usually started with enable)
systemctl --user start gateway-watchdog.timer
systemctl --user start whatsapp-responder.timer
systemctl --user start moltbook-heartbeat.timer
systemctl --user start workspace-sync.timer
```

---

## Step 7: Verify Health

```bash
# Wait for services to initialize
sleep 5

# Check all services are running
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*'

# Test health endpoint
HEALTH=$(curl -s http://localhost:18789/health || echo '{"status":"unreachable"}')
echo "$HEALTH" | grep -q '"status":"healthy"' && echo "Gateway healthy" || echo "Gateway UNHEALTHY"

# If unhealthy, check logs immediately
if echo "$HEALTH" | grep -q '"status":"unreachable"'; then
  journalctl --user -u zeptoclaw-gateway -n 100
fi
```

**Expected Output:**
```
UNIT                      LOAD   ACTIVE SUB     DESCRIPTION
zeptoclaw-gateway.service loaded active running ZeptoClaw Gateway
...
Gateway healthy
```

---

## Step 8: Smoke Test Functionality

```bash
# Send a test request through the gateway
TEST_RESPONSE=$(curl -s -X POST http://localhost:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen3.5-397b-a17b","messages":[{"role":"user","content":"test"}],"max_tokens":10}' \
  -w "\n%{http_code}")

# Extract response body and status code
RESPONSE_BODY=$(echo "$TEST_RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -n1)

if [ "$HTTP_CODE" = "200" ]; then
  echo "Smoke test PASSED"
  echo "Response: $RESPONSE_BODY" | head -c 200
else
  echo "Smoke test FAILED: HTTP $HTTP_CODE"
  echo "Response: $RESPONSE_BODY"
  # Check logs
  journalctl --user -u zeptoclaw-gateway -n 50
  exit 1
fi
```

---

## Step 9: Monitor for 5 Minutes

```bash
# Watch logs for errors
journalctl --user -u zeptoclaw-gateway -f &
LOG_PID=$!

# Wait 5 minutes, monitor for crash/restart loops
sleep 300

# Check if gateway still running
if systemctl --user is-active zeptoclaw-gateway.service >/dev/null; then
  echo "Gateway stable after 5 minutes"
else
  echo "Gateway crashed or stopped during monitoring!"
  journalctl --user -u zeptoclaw-gateway -n 200
  exit 1
fi

# Stop log monitoring
kill $LOG_PID 2>/dev/null
```

---

## Rollback Procedures

If deployment fails at any point:

### Immediate Rollback

```bash
# Stop all services
systemctl --user stop --all

# Restore binaries from backup
if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  cp "$BACKUP_DIR/zeptoclaw-gateway" zig-out/bin/
  cp "$BACKUP_DIR/zeptoclaw-webhook" zig-out/bin/
  cp "$BACKUP_DIR/zeptoclaw-shell2http" zig-out/bin/
  chmod 755 zig-out/bin/*
else
  echo "No backup directory found. Check $HOME/.local/share/zeptoclaw/backups/ or use git."
  # Fallback: rebuild previous commit
  git checkout HEAD~1 -- zig-out/bin/ 2>/dev/null || true
fi

# Restart services
systemctl --user start zeptoclaw-gateway.service zeptoclaw-webhook.service zeptoclaw-shell2http.service
systemctl --user start gateway-watchdog.service whatsapp-responder.service moltbook-heartbeat.service

# Verify rollback
sleep 5
curl -s http://localhost:18789/health | grep healthy || echo "Rollback failed to restore health"
```

### Restore State from Backup

If state corruption suspected, see [Restoring from Backup](/runbooks/restoring-from-backup.md).

---

## Post-Deployment Checklist

- [ ] All services running (`systemctl --user list-units`)
- [ ] Health endpoint returns `healthy`
- [ ] Smoke test request succeeds (HTTP 200)
- [ ] No errors in logs (`journalctl --user -u zeptoclaw-gateway --since "5 min ago" | grep -i error`)
- [ ] Backup of previous version retained
- [ ] Commit hash recorded for audit trail (`git rev-parse HEAD > ~/.local/share/zeptoclaw/deployments/$(date +%Y%m%d-%H%M%S).commit`)

---

## Zero-Downtime Deployment (Advanced)

For high availability, use blue-green deployment with two installations:

1. Deploy new version to alternate directory: `/opt/zeptoclaw-v2/`
2. Start new services with different systemd instance names (`zeptoclaw-gateway-v2.service`)
3. Load test and verify health on alternate port
4. Switch load balancer or reverse proxy to new version
5. Stop old version after verification

This requires custom systemd files and port configuration adjustments. See [Configuration](/runbooks/updating-configuration.md) for port changes.
