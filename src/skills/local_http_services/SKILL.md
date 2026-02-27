---
name: local-http-services
version: 1.0.0
description: Execute system commands and trigger actions via local HTTP endpoints.
metadata: {"zeptoclaw":{"emoji":"🌐"}}
---

# Local HTTP Services Skill

Execute system commands and trigger actions via local HTTP endpoints.

## Overview

Two complementary services run on localhost:
- **webhook** (port 9000): Complex webhooks with HMAC validation, for sensitive actions
- **shell2http** (port 9001): Simple command execution with basic auth, for read-only queries

## Security Model

1. **Localhost only** - Both bind to 127.0.0.1, no external access
2. **Authentication** - webhook uses X-Webhook-Token header, shell2http uses basic auth
3. **Pre-defined commands** - No arbitrary execution, all commands are whitelisted
4. **Input sanitization** - Shell metacharacters stripped from user inputs

## Quick Reference

### shell2http Endpoints (port 9001, basic auth)

```bash
# Get auth credentials
SECRET=$(cat ~/.zeptoclaw/.webhook-secret)
AUTH="-u barvis:$SECRET"

# System info
curl -s $AUTH http://127.0.0.1:9001/health
curl -s $AUTH http://127.0.0.1:9001/date
curl -s $AUTH http://127.0.0.1:9001/uptime
curl -s $AUTH http://127.0.0.1:9001/memory
curl -s $AUTH http://127.0.0.1:9001/disk

# Systemd
curl -s $AUTH http://127.0.0.1:9001/timers
curl -s $AUTH http://127.0.0.1:9001/systemctl/status

# Journals
curl -s $AUTH http://127.0.0.1:9001/journal/gateway
curl -s $AUTH http://127.0.0.1:9001/journal/watchdog
curl -s $AUTH http://127.0.0.1:9001/journal/webhook

# Git
curl -s $AUTH http://127.0.0.1:9001/git/status
curl -s $AUTH http://127.0.0.1:9001/git/log

# Worker
curl -s $AUTH http://127.0.0.1:9001/worker/health
curl -s $AUTH http://127.0.0.1:9001/worker/state
curl -s $AUTH http://127.0.0.1:9001/worker/incidents
```

### webhook Endpoints (port 9000, HMAC)

```bash
# Get webhook secret
SECRET=$(cat ~/.zeptoclaw/.webhook-secret)

# Generate HMAC signature
SIGNATURE=$(echo -n "payload" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

# Send webhook
curl -X POST http://127.0.0.1:9000/webhook \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Token: $SIGNATURE" \
  -d '{"action": "restart_gateway"}'
```

## Triggers

command: /http-health
command: /http-uptime
command: /http-memory
command: /http-disk
command: /http-timers
command: /http-git-status
command: /http-journal

## Configuration

webhook_port (integer): Webhook server port (default: 9000)
shell2http_port (integer): Shell2HTTP server port (default: 9001)
webhook_secret_path (string): Path to webhook secret (default: ~/.zeptoclaw/.webhook-secret)
enable_webhook (boolean): Enable webhook server (default: true)
enable_shell2http (boolean): Enable shell2http server (default: true)

## Usage

### Check system health
```
/http-health
```

### Check system uptime
```
/http-uptime
```

### Check memory usage
```
/http-memory
```

### Check disk usage
```
/http-disk
```

### List systemd timers
```
/http-timers
```

### Check git status
```
/http-git-status
```

### View gateway logs
```
/http-journal gateway
```

## Implementation Notes

This skill provides access to local HTTP services for system monitoring and control. It:
1. Queries shell2http for system information
2. Sends commands via webhook for sensitive operations
3. Manages authentication for both services
4. Sanitizes all inputs to prevent injection

## Dependencies

- HTTP client (for local requests)
- shell2http server
- webhook server
