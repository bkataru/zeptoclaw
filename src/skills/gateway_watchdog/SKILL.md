---
name: gateway-watchdog
version: 1.0.0
description: Auto-detect and recover from stuck ZeptoClaw gateway sessions.
metadata: {"zeptoclaw":{"emoji":"🐕"}}
---

# Gateway Watchdog Skill

Automated monitoring and recovery for ZeptoClaw gateway stuck sessions.

## The Problem

Barvis (running inside ZeptoClaw) **cannot detect when it is stuck**. Common causes:

1. **Hung tool calls** - `web_fetch`, `daedra`, or MCP tools that never return
2. **Image poisoning** - GIF files embedded in conversation history
3. **API timeouts** - GitHub Copilot/Claude API hangs
4. **WhatsApp connection issues** - Blocking the gateway event loop

When stuck, the gateway shows:
```
[diagnostic] stuck session: sessionId=xxx state=processing age=286s
```

But Barvis cannot see this from inside the stuck session.

## The Solution

An **external watchdog** that:
1. Monitors gateway logs for stuck sessions
2. Auto-restarts if stuck > 10 minutes (configurable)
3. Logs recovery attempts for post-mortem analysis
4. Notifies via Cloudflare worker (optional)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  EXTERNAL WATCHDOG (systemd timer, every 2 min)                 │
│  - Runs gateway-watchdog.zig                                    │
│  - Checks journalctl for "stuck session" messages               │
│  - If age > threshold, restarts gateway                         │
│  - Logs to ~/.zeptoclaw/logs/gateway-watchdog.log               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  ZEPTOCLAW GATEWAY (systemd service)                            │
│  - Runs Barvis sessions                                         │
│  - Logs "stuck session" diagnostics                             │
└─────────────────────────────────────────────────────────────────┘
```

## Triggers

command: /gateway-watchdog
command: /watchdog-status
command: /watchdog-check
scheduled: */2 * * * *

## Configuration

stuck_threshold_minutes (integer): Minutes before considering a session stuck (default: 10)
log_path (string): Path to watchdog log file (default: ~/.zeptoclaw/logs/gateway-watchdog.log)
gateway_service (string): Systemd service name for gateway (default: zeptoclaw-gateway.service)
enable_auto_restart (boolean): Whether to auto-restart stuck gateway (default: true)
notification_url (string): Optional Cloudflare worker URL for notifications (default: null)

## Usage

### Check watchdog status
```
/gateway-watchdog status
```

### Manual check for stuck sessions
```
/gateway-watchdog check
```

### View recent logs
```
/gateway-watchdog logs
```

### Configure threshold
```
/gateway-watchdog threshold 15
```

## Implementation Notes

The watchdog skill runs as a scheduled task every 2 minutes. It:
1. Queries systemd journal for "stuck session" messages
2. Parses session age from log entries
3. If age > threshold, restarts the gateway service
4. Logs all actions to the watchdog log file
5. Optionally sends notifications to Cloudflare worker

## Dependencies

- systemd (for journalctl and service management)
- zig (for watchdog implementation)
