# ZeptoClaw Deployment Guide

**Status:** ✅ Build Complete | ⏳ Deployment Pending

This guide covers deploying ZeptoClaw after the complete migration from OpenClaw.

---

## Quick Start

```bash
# 1. Build (if not already done)
cd /home/user/zeptoclaw
zig build

# 2. Verify build
ls -lh zig-out/bin/
# Should show 4 binaries: zeptoclaw, zeptoclaw-gateway, zeptoclaw-webhook, zeptoclaw-shell2http

# 3. Set required environment variables
export NVIDIA_API_KEY="nvapi-your-key-here"
export MOLTBOOK_API_KEY="your-moltbook-key"
export MOLTBOOK_AGENT_ID="your-agent-id"
export MOLTBOOK_AGENT_NAME="your-agent-name"

# 4. Run data migration (from OpenClaw)
./scripts/migrate/migrate-all.sh

# 5. Install systemd services
./scripts/install-systemd.sh

# 6. Start services
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now zeptoclaw-webhook.service
systemctl --user enable --now zeptoclaw-shell2http.service

# 7. Test
curl http://localhost:18789/health
```

---

## Prerequisites

### System Requirements

- **Zig 0.15.2+** - [Download](https://ziglang.org/download/)
- **Node.js 18+** (for Cloudflare Worker)
- **systemd** (user services)
- **NVIDIA NIM API Key** - [Get here](https://build.nvidia.com/)
- **Moltbook Credentials** - API key, agent ID, agent name

### Required Environment Variables

Create `/home/user/.zeptoclaw/env`:

```bash
# NVIDIA NIM API
NVIDIA_API_KEY=nvapi-your-key-here
NVIDIA_MODEL=qwen/qwen3.5-397b-a17b

# Moltbook Integration
MOLTBOOK_API_KEY=your-moltbook-api-key
MOLTBOOK_AGENT_ID=your-agent-id
MOLTBOOK_AGENT_NAME=your-agent-name

# Gateway Authentication (optional, auto-generated if not set)
ZEPTOCLAW_GATEWAY_TOKEN=change-this-to-secure-random-token
```

**Security:** Set permissions: `chmod 600 /home/user/.zeptoclaw/env`

---

## Step 1: Data Migration from OpenClaw

ZeptoClaw includes migration scripts to transfer data from OpenClaw:

```bash
cd /home/user/zeptoclaw/scripts/migrate

# Option 1: Dry run (see what will be migrated)
./migrate-all.sh --dry-run

# Option 2: Full migration
./migrate-all.sh

# Option 3: Individual migrations
./migrate-credentials.sh    # WhatsApp sessions, API keys
./migrate-sessions.sh       # Conversation history
./migrate-memory.sh         # Memory database
./migrate-secrets.sh        # Webhook secrets, tokens
```

### What Gets Migrated

| Source | Destination | Description |
|--------|-------------|-------------|
| `~/.openclaw/credentials/` | `~/.zeptoclaw/credentials/` | WhatsApp sessions, API tokens |
| `~/.openclaw/sessions/` | `~/.zeptoclaw/sessions/` | Conversation history |
| `~/.openclaw/memory/` | `~/.zeptoclaw/memory/` | SQLite memory database |
| `~/.openclaw/.webhook-secret` | `~/.zeptoclaw/.webhook-secret` | Webhook HMAC secret |
| `~/.openclaw/webhooks/hooks.json` | `~/.zeptoclaw/webhooks/hooks.json` | Webhook configurations |

---

## Step 2: Create Startup Scripts

Systemd services require startup scripts. Create them:

```bash
mkdir -p /home/user/.zeptoclaw/scripts
```

### gateway-start.sh

```bash
cat > /home/user/.zeptoclaw/scripts/gateway-start.sh << 'EOF'
#!/bin/bash
# ZeptoClaw Gateway Startup Script
set -e

# Load environment
if [ -f /home/user/.zeptoclaw/env ]; then
    export $(grep -v '^#' /home/user/.zeptoclaw/env | xargs)
fi

# Execute gateway
exec /home/user/zeptoclaw/zig-out/bin/zeptoclaw-gateway
EOF
chmod +x /home/user/.zeptoclaw/scripts/gateway-start.sh
```

### shell2http-start.sh

```bash
cat > /home/user/.zeptoclaw/scripts/shell2http-start.sh << 'EOF'
#!/bin/bash
# ZeptoClaw Shell2HTTP Startup Script
set -e

# Load environment
if [ -f /home/user/.zeptoclaw/env ]; then
    export $(grep -v '^#' /home/user/.zeptoclaw/env | xargs)
fi

# Execute shell2http server
exec /home/user/zeptoclaw/zig-out/bin/zeptoclaw-shell2http
EOF
chmod +x /home/user/.zeptoclaw/scripts/shell2http-start.sh
```

### webhook-start.sh (if needed)

```bash
cat > /home/user/.zeptoclaw/scripts/webhook-start.sh << 'EOF'
#!/bin/bash
# ZeptoClaw Webhook Server Startup Script
set -e

# Load environment
if [ -f /home/user/.zeptoclaw/env ]; then
    export $(grep -v '^#' /home/user/.zeptoclaw/env | xargs)
fi

# Execute webhook server
exec /home/user/zeptoclaw/zig-out/bin/zeptoclaw-webhook
EOF
chmod +x /home/user/.zeptoclaw/scripts/webhook-start.sh
```

---

## Step 3: Install Systemd Services

### Copy Service Files

```bash
# Create systemd user directory
mkdir -p ~/.config/systemd/user

# Copy ZeptoClaw services
cp /home/user/zeptoclaw/systemd/*.service ~/.config/systemd/user/
cp /home/user/zeptoclaw/systemd/*.timer ~/.config/systemd/user/

# Copy Cloudflare heartbeat service (if using)
cp /home/user/zeptoclaw/cloudflare-worker/zeptoclaw-heartbeat.* ~/.config/systemd/user/
```

### Create Required Directories

```bash
mkdir -p /home/user/.zeptoclaw/{webhooks,logs,credentials/whatsapp,sessions,memory}
```

### Reload Systemd

```bash
systemctl --user daemon-reload
```

### Enable and Start Services

```bash
# Core services (start in order)
systemctl --user enable --now zeptoclaw-gateway.service
sleep 2  # Give gateway time to start
systemctl --user enable --now zeptoclaw-webhook.service
systemctl --user enable --now zeptoclaw-shell2http.service

# Supporting services
systemctl --user enable --now gateway-watchdog.timer
systemctl --user enable --now whatsapp-responder.timer
systemctl --user enable --now moltbook-heartbeat.timer
systemctl --user enable --now workspace-sync.timer

# Cloudflare heartbeat (if deployed)
# systemctl --user enable --now zeptoclaw-heartbeat.timer
```

### Verify Services

```bash
# List all ZeptoClaw services
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*'

# Check status
systemctl --user status zeptoclaw-gateway.service

# View logs
journalctl --user -u zeptoclaw-gateway -f
```

---

## Step 4: Test Deployment

### Gateway Health Check

```bash
curl http://localhost:18789/health | jq
```

Expected response:
```json
{
  "status": "ok",
  "timestamp": "2026-02-27T...",
  "uptime_seconds": 123
}
```

### Chat Completion Test

```bash
curl -X POST http://localhost:18789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello, ZeptoClaw!"}
    ]
  }' | jq
```

### Webhook Server Test

```bash
curl http://localhost:9000/health
```

### Shell2HTTP Test

```bash
curl http://localhost:9001/systemctl/status | jq
```

---

## Step 5: Cloudflare Worker Deployment (Optional)

The Cloudflare Worker provides external API access with health tracking and failover.

### Setup

```bash
cd /home/user/zeptoclaw/cloudflare-worker

# Install dependencies
npm install

# Create KV namespaces
wrangler kv:namespace create "GATEWAY_HEALTH"
wrangler kv:namespace create "ZEPTOCLAW_STATE"

# Update wrangler.toml with KV namespace IDs and gateway URL
# Edit the file to add the IDs returned by the commands above
```

### Deploy

```bash
# Login to Cloudflare (first time only)
wrangler login

# Deploy
./deploy.sh
```

### Test Worker

```bash
# Health check
curl https://zeptoclaw-router.your-subdomain.workers.dev/health | jq

# Chat completion
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}]}' | jq
```

---

## Step 6: Runtime Validation

### Integration Tests

```bash
cd /home/user/zeptoclaw
zig build test 2>&1 | tee test-results.txt
```

### Manual Verification Checklist

- [ ] Gateway responds on port 18789
- [ ] Webhook server responds on port 9000
- [ ] Shell2HTTP server responds on port 9001
- [ ] WhatsApp channel can receive/send messages
- [ ] All 21 skills are registered and functional
- [ ] Moltbook integration works (heartbeat, memory sync)
- [ ] Cloudflare Worker deployed and routing correctly (if applicable)
- [ ] Systemd timers running (watchdog, responder, heartbeat)

### Check Data Migration

```bash
# Verify credentials migrated
ls -la ~/.zeptoclaw/credentials/whatsapp/

# Verify sessions migrated
ls -la ~/.zeptoclaw/sessions/

# Verify memory migrated
ls -la ~/.zeptoclaw/memory/
```

---

## Troubleshooting

### Gateway Won't Start

```bash
# Check logs
journalctl --user -u zeptoclaw-gateway -f

# Verify environment variables
cat /home/user/.zeptoclaw/env

# Test binary directly
/home/user/zeptoclaw/zig-out/bin/zeptoclaw-gateway --help
```

### WhatsApp Not Working

1. Verify credentials migrated: `ls ~/.zeptoclaw/credentials/whatsapp/`
2. Check session files exist
3. Verify WhatsApp channel configuration in config
4. Check logs: `journalctl --user -u whatsapp-responder -f`

### Skills Not Loading

1. Verify skill files exist: `ls -la /home/user/zeptoclaw/src/skills/*/skill.zig`
2. Check skill registry: `grep -r "register" src/skills/*.zig`
3. Review logs for skill loading errors

### Cloudflare Worker Issues

```bash
# Check deployment status
wrangler deploy --dry-run

# View logs
wrangler tail

# Reset KV (if needed)
wrangler kv:namespace delete "GATEWAY_HEALTH"
wrangler kv:namespace create "GATEWAY_HEALTH"
```

---

## Service Architecture

````
┌─────────────────────────────────────────────────────────┐
│                 ZeptoClaw System                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────┐    ┌─────────────┐    ┌────────────┐  │
│  │   Gateway   │    │   Webhook   │    │  Shell2HTTP│  │
│  │  :18789     │    │  :9000      │    │  :9001     │  │
│  └──────┬──────┘    └──────┬──────┘    └─────┬──────┘  │
│         │                  │                  │         │
│         └──────────────────┼──────────────────┘         │
│                            │                            │
│  ┌─────────────────────────┴───────────────────────┐   │
│  │           Systemd Services & Timers             │   │
│  │  - gateway-watchdog (every 2min)                │   │
│  │  - whatsapp-responder (every 15min)             │   │
│  │  - moltbook-heartbeat (every 30min)             │   │
│  │  - workspace-sync (every 30min)                 │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
                           │
                           │ (optional)
                           ▼
              ┌────────────────────────┐
              │  Cloudflare Worker     │
              │  - Health tracking     │
              │  - Auto failover       │
              │  - External API        │
              └────────────────────────┘
```

---

## Next Steps After Deployment

1. **Monitor Logs**: Set up log rotation and monitoring
2. **Backup Strategy**: Regularly backup `~/.zeptoclaw/` data
3. **Security**: Review firewall rules, API key exposure
4. **Updates**: Monitor ZeptoClaw repository for updates
5. **Performance**: Watch memory usage, response times

---

## Support

- **Documentation**: See [README.md](README.md) for overview
- **Cloudflare Worker**: See [cloudflare-worker/README.md](cloudflare-worker/README.md)
- **Issues**: Report on GitHub
- **Barvis**: [Moltbook profile](https://www.moltbook.com/u/barvis_da_jarvis)

---

**License:** MIT - Same as ZeptoClaw
