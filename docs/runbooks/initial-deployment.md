# Initial Deployment Guide

## Prerequisites

- Zig 0.15.2+ installed and in PATH
- NVIDIA NIM API key (obtain from [NVIDIA NIM](https://build.nvidia.com/))
- Linux system with systemd (user or system)
- Git (optional, for cloning)

## Overview

ZeptoClaw consists of 4 binaries:
- `zeptoclaw` - Main agent (interactive CLI)
- `zeptoclaw-gateway` - HTTP gateway server (port 18789)
- `zeptoclaw-webhook` - Webhook server (port 9000)
- `zeptoclaw-shell2http` - Shell2HTTP server (port 9001)

10 systemd service/timer files automate operation.

---

## Step 1: Build Binaries

```bash
# Clone repository (if not already)
cd /home/user/zeptoclaw

# Clean build (optional but recommended)
zig build clean

# Build all binaries in release mode
zig build -Drelease-safe

# Verify binaries exist
ls -lh zig-out/bin/
```

**Expected Output:**
```
-rwxr-xr-x  ... zeptoclaw
-rwxr-xr-x  ... zeptoclaw-gateway
-rwxr-xr-x  ... zeptoclaw-webhook
-rwxr-xr-x  ... zeptoclaw-shell2http
```

**Failure Indicators:**
- Any compilation error → check Zig version, dependencies
- Missing binaries → run `zig build` again, check build.zig for errors

---

## Step 2: Configure Environment Variables

Create environment file for systemd services:

```bash
# Create directory for configuration
mkdir -p ~/.config/zeptoclaw

# Create environment file
cat > ~/.config/zeptoclaw/env <<'EOF'
# Required: NVIDIA API key
NVIDIA_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Optional: Model (default: qwen/qwen3.5-397b-a17b)
# NVIDIA_MODEL=qwen/qwen3.5-397b-a17b

# Optional: Moltbook integration
# MOLTBOOK_API_KEY=your_key
# MOLTBOOK_USER_ID=your_user_id
EOF
```

**Important:** Replace the placeholder API key with your actual NVIDIA NIM API key.

**Security Note:** File permissions should restrict access:
```bash
chmod 600 ~/.config/zeptoclaw/env
```

---

## Step 3: Install Systemd Services (User Mode)

```bash
# Create systemd user directory
mkdir -p ~/.config/systemd/user

# Copy service files
cp /home/user/zeptoclaw/systemd/*.service ~/.config/systemd/user/
cp /home/user/zeptoclaw/systemd/*.timer ~/.config/systemd/user/

# Load environment file for user services
# Add to ~/.config/systemd/user/environment (optional alternative to -- env)
# OR use EnvironmentFile in each service (recommended: modify services to include EnvironmentFile)

# For quick start without modifying services, use systemd --user env:
systemctl --user import-environment NVIDIA_API_KEY NVIDIA_MODEL MOLTBOOK_API_KEY MOLTBOOK_USER_ID

# Reload systemd daemon
systemctl --user daemon-reload
```

**Alternative (modify services to load env file):**

Edit each `.service` file to include:
```
[Service]
EnvironmentFile=%h/.config/zeptoclaw/env
```

---

## Step 4: Enable and Start Services

```bash
# Enable and start main gateway
systemctl --user enable --now zeptoclaw-gateway.service

# Enable and start auxiliary services
systemctl --user enable --now zeptoclaw-webhook.service
systemctl --user enable --now zeptoclaw-shell2http.service

# Enable watchdog and heartbeat services
systemctl --user enable --now gateway-watchdog.service
systemctl --user enable --now whatsapp-responder.service
systemctl --user enable --now moltbook-heartbeat.service

# Enable periodic timers
systemctl --user enable --now gateway-watchdog.timer
systemctl --user enable --now whatsapp-responder.timer
systemctl --user enable --now moltbook-heartbeat.timer
systemctl --user enable --now workspace-sync.timer
```

---

## Step 5: Verify Services are Running

```bash
# List all ZeptoClaw services
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*'

# Check service status
systemctl --user status zeptoclaw-gateway.service

# View logs (journalctl)
journalctl --user -u zeptoclaw-gateway -f
```

**Expected:** All services show `active (running)`. No error messages in logs.

---

## Step 6: Test Health Endpoints

```bash
# Wait a few seconds for gateway to start, then:
sleep 5

# Check gateway health
curl http://localhost:18789/health

# Expected output:
# {"status":"healthy","timestamp":"2026-02-28T..."}

# Check readiness
curl http://localhost:18789/ready

# Check metrics
curl http://localhost:18789/metrics | head -20
```

**If health returns `degraded` or `unhealthy`:**
- Check logs: `journalctl --user -u zeptoclaw-gateway -n 50`
- Verify NVIDIA_API_KEY is set correctly
- Check network connectivity to NIM API

---

## Step 7: Test Basic Operation

```bash
# Send a test chat completion request
curl -X POST http://localhost:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3.5-397b-a17b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'

# Expected: JSON response with choices[0].message.content
```

---

## Troubleshooting

### Services fail to start (permission denied)

Check binary permissions:
```bash
chmod +x /home/user/zeptoclaw/zig-out/bin/*
```

### Systemd cannot find binaries

Services expect binaries in `/home/user/zeptoclaw/zig-out/bin/`. If installed elsewhere, edit service files or create symlinks.

### Environment variables not loaded

Verify with:
```bash
systemctl --user show zeptoclaw-gateway.service | grep EnvironmentFile
```

If empty, either:
1. Add `EnvironmentFile` to service files and reload daemon
2. Use `systemctl --user import-environment ...` before starting

### Port already in use

Change port in configuration and restart services:
```bash
# Edit config (see configuration guide)
# Then restart gateway
systemctl --user restart zeptoclaw-gateway.service
```

### Journalctl shows no logs

Ensure journald is running and user logging enabled:
```bash
# Check if persistent logging enabled (optional)
journalctl --user -u zeptoclaw-gateway -n 10 || echo "No logs"
```

---

## Rollback Procedures

If new deployment (see next runbook) causes issues:

```bash
# Stop all services
systemctl --user stop --all

# Restore previous binaries (from backup or git)
cd /home/user/zeptoclaw
git checkout <previous-commit> -- zig-out/bin/

# Rebuild if needed
zig build -Drelease-safe

# Restart services
systemctl --user start --all
```

---

## Additional Documentation

- [Systemd Setup](/runbooks/systemd-setup.md) - Detailed systemd configuration
- [Configuration](/runbooks/updating-configuration.md) - Changing config safely
- [Backup and Restore](/runbooks/restoring-from-backup.md) - StateStore backups
- [Troubleshooting](/runbooks/troubleshooting.md) - Common issues and solutions
