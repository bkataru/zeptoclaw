# Updating Configuration

## Prerequisites

- Access to ZeptoClaw configuration files (typically `~/.config/zeptoclaw/config.json` or similar)
- Understanding of configuration schema (see `src/config/config.zig`)
- Systemd user permissions to restart services
- Backup of current configuration

## Overview

This runbook covers safe configuration updates without downtime or data loss:
- Editing config files
- Validating changes
- Rolling out updates with minimal impact
- Rolling back on failure

**Supported configuration sources:**
- Configuration file (JSON or TOML)
- Environment variables (override file)
- Command-line flags (highest priority)

---

## Step 1: Identify Configuration Location

```bash
# Default locations (check in order):
CONFIG_PATHS=(
  "$HOME/.config/zeptoclaw/config.json"
  "$HOME/.config/zeptoclaw/config.toml"
  "/etc/zeptoclaw/config.json"
  "/usr/local/etc/zeptoclaw/config.json"
)

for path in "${CONFIG_PATHS[@]}"; do
  if [ -f "$path" ]; then
    echo "Found config at: $path"
    CONFIG_FILE="$path"
    break
  fi
done

if [ -z "$CONFIG_FILE" ]; then
  echo "Config file not found in standard locations."
  echo "Check if using environment variables exclusively."
  exit 1
fi
```

---

## Step 2: Backup Current Configuration

```bash
BACKUP_DIR="$HOME/.local/share/zeptoclaw/config-backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
cp "$CONFIG_FILE" "$BACKUP_DIR/config-$TIMESTAMP.json"
echo "Backup saved to: $BACKUP_DIR/config-$TIMESTAMP.json"

# Also record which git commit was deployed
cd /home/user/zeptoclaw
git rev-parse HEAD > "$BACKUP_DIR/config-$TIMESTAMP.commit"
```

---

## Step 3: Edit Configuration

### Use an Editor

```bash
# Make a copy to edit
cp "$CONFIG_FILE" "${CONFIG_FILE}.tmp"

# Edit with your preferred editor
${EDITOR:-vim} "${CONFIG_FILE}.tmp"

# Validate JSON/TOML syntax before applying
if [[ "$CONFIG_FILE" == *.json ]]; then
  python3 -m json.tool "${CONFIG_FILE}.tmp" > /dev/null || { echo "Invalid JSON!"; exit 1; }
elif [[ "$CONFIG_FILE" == *.toml ]]; then
  python3 -c "import toml; toml.load('${CONFIG_FILE}.tmp')" 2>/dev/null || { echo "Invalid TOML!"; exit 1; }
fi

# Move into place atomically
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
```

### Configuration Schema Reference

Common top-level fields:

```json
{
  "nvidia": {
    "api_key": "nvapi-...",
    "model": "qwen/qwen3.5-397b-a17b",
    "timeout_ms": 30000,
    "retry_policy": { "max_retries": 3, "backoff_ms": 1000 }
  },
  "gateway": {
    "port": 18789,
    "max_concurrent_requests": 100,
    "circuit_breaker": { "failure_threshold": 5, "reset_timeout_s": 60 }
  },
  "providers": [...],
  "skills": {...}
}
```

See `src/config/config.zig` for full schema.

---

## Step 4: Validate Configuration

### Test Config Load

```bash
# The zeptoclaw binary can validate config without starting services
./zig-out/bin/zeptoclaw --validate-config --config "$CONFIG_FILE" && echo "Config valid" || echo "Config INVALID"

# Or using gateway:
timeout 10s ./zig-out/bin/zeptoclaw-gateway --dry-run --config "$CONFIG_FILE" 2>&1 | grep -i 'valid\|error'
```

### Check for Required Fields

```bash
# Ensure NVIDIA API key is set
grep -q '"api_key"' "$CONFIG_FILE" && grep -q 'nvapi-' "$CONFIG_FILE" && echo "API key present" || echo "WARNING: API key missing or invalid"
```

---

## Step 5: Apply Configuration Changes

#### Hot-reload (if supported)

Some settings support runtime reload via SIGHUP:

```bash
systemctl --user kill -s HUP zeptoclaw-gateway.service
# Check if config reloaded:
curl -s http://localhost:18789/metrics | grep config_hash
```

**Not all settings are hot-reloadable.** Check implementation. If unsure, restart.

#### Restart Services (safe method)

```bash
# Restart only the gateway (most config changes affect gateway/provider)
systemctl --user restart zeptoclaw-gateway.service

# If WhatsApp channel config changed:
systemctl --user restart whatsapp-responder.service

# If autonomous features changed:
systemctl --user restart moltbook-heartbeat.service
```

---

## Step 6: Verify Configuration Apply

### Check Health Endpoint

```bash
sleep 5  # wait for restart
curl -s http://localhost:18789/health | jq .status
# Should be "healthy"
```

### Verify Specific Settings

```bash
# Check port (if changed)
netstat -tuln | grep 18789 || ss -tuln | grep 18789

# Check timeout configured
curl -s http://localhost:18789/metrics | grep timeout || echo "timeout metric not found"
```

### Test Functionality

Send a test request:

```bash
curl -s -X POST http://localhost:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen3.5-397b-a17b","messages":[{"role":"user","content":"test"}]}' \
  -w "\nHTTP %{http_code}\n" | tail -1
# Expected: HTTP 200
```

---

## Step 7: Monitor for 5 Minutes

```bash
# Watch logs for config-related errors
journalctl --user -u zeptoclaw-gateway -f &
PID=$!

sleep 300

# After 5 min, check if any errors appeared
journalctl --user -u zeptoclaw-gateway --since "5 minutes ago" | grep -i 'config\|invalid\|required' || echo "No config errors"

kill $PID 2>/dev/null
```

---

## Rollback on Failure

If service fails to start or health becomes `unhealthy`:

```bash
# Stop gateway
systemctl --user stop zeptoclaw-gateway.service

# Restore previous config
cp "$BACKUP_DIR/config-$TIMESTAMP.json" "$CONFIG_FILE"

# Restart
systemctl --user start zeptoclaw-gateway.service

# Verify
sleep 5
curl -s http://localhost:18789/health || echo "Restart failed even with backup"
```

If backup restore fails, check configuration syntax and required fields again.

---

## Common Configuration Changes

### Change Port

```json
{
  "gateway": { "port": 18790 }
}
```

After restart, update health curl to use new port. Firewall may need adjustment.

### Change Model

```json
{
  "nvidia": { "model": "nvidia/llama-3.1-nemotron-70b-instruct" }
}
```

Restart gateway. No data migration needed (model is just a string).

### Enable Debug Logging

Add env var or config:

```bash
# Environment (preferred for temporary)
systemctl --user import-environment LOG_LEVEL
# or edit service to include Environment=LOG_LEVEL=debug

# Config-based log level (if supported)
{
  "log_level": "debug"
}
```

---

## Configuration Validation Checklist

- [ ] Config file syntax valid (JSON/TOML parseable)
- [ ] Required fields present (NVIDIA_API_KEY or in config)
- [ ] No outdated fields (after upgrade, check deprecations)
- [ ] Ports within valid range (1-65535)
- [ ] Timeouts positive integers
- [ ] File paths exist and readable (if specified)
- [ ] Backup of previous config retained
- [ ] Services restarted successfully
- [ ] Health status healthy
- [ ] Test request succeeded

---

## Advanced: Atomic Multi-File Updates

If configuration split across multiple files (e.g., `config.d/` directory):

```bash
# Create timestamped temp dir
TMPDIR=$(mktemp -d)
cp -r /etc/zeugencfg/* "$TMPDIR/"
# Edit files in $TMPDIR
# Validate entire config
# Atomic move
mv "$TMPDIR" /etc/zeugencfg.new
renameat2 /etc/zeugencfg.new /etc/zeugencfg
```

---

## References

- [Initial Deployment](/runbooks/initial-deployment.md) - Environment setup
- [Deploying New Version](/runbooks/deploying-new-version.md) - Full version updates
- Schema: `src/config/config.zig`
- Environment variables: `src/config/config_loader.zig`

---

## Quick Commands Reference

```bash
# Validate config
./zig-out/bin/zeptoclaw --validate-config

# Restart gateway
systemctl --user restart zeptoclaw-gateway.service

# Check health
curl http://localhost:18789/health

# View effective config from logs (if debug)
journalctl --user -u zeptoclaw-gateway | grep -i 'config loaded'
```
