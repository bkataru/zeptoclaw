# ZeptoClaw Cloudflare Worker

A Cloudflare Worker providing resilient OpenAI-compatible API routing for ZeptoClaw with automatic failover and health tracking.

## Features

- **OpenAI-Compatible API**: `/v1/chat/completions` endpoint
- **Gateway Health Tracking**: Automatic monitoring with cooldown periods
- **Automatic Failover**: Retry with exponential backoff
- **Heartbeat System**: Local agent ping for alive signaling
- **Incident Tracking**: Record and view gateway incidents
- **State Management**: Persistent state via Cloudflare KV
- **Resilient Routing**: Multiple gateway support with health-based selection

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ CLOUDFLARE WORKER                                               │
│ https://zeptoclaw-router.your-subdomain.workers.dev             │
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐ │
│  │ Gateway Router   │ │ Health Manager   │ │ State Manager    │ │
│  │ - OpenAI API     │ │ - KV storage     │ │ - Heartbeats     │ │
│  │ - Auto failover  │ │ - Cooldowns      │ │ - Incidents      │ │
│  └──────────────────┘ └──────────────────┘ └──────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ ZeptoClaw        │
                    │ Gateway          │
                    │ localhost:18789  │
                    └──────────────────┘
```

## Prerequisites

- Node.js 18+
- Cloudflare account
- Wrangler CLI
- ZeptoClaw gateway running (default: `localhost:18789`)

## Installation

### 1. Install Dependencies

```bash
cd /home/user/zeptoclaw/cloudflare-worker
npm install
```

### 2. Create KV Namespaces

```bash
# Create KV namespace for gateway health
wrangler kv:namespace create "GATEWAY_HEALTH"

# Create KV namespace for ZeptoClaw state
wrangler kv:namespace create "ZEPTOCLAW_STATE"
```

Copy the returned namespace IDs for the next step.

### 3. Update wrangler.toml

Add the KV namespace IDs from the previous step:

```toml
[[kv_namespaces]]
binding = "GATEWAY_HEALTH"
id = "your-gateway-health-id-here"

[[kv_namespaces]]
binding = "ZEPTOCLAW_STATE"
id = "your-zeptoclaw-state-id-here"
```

### 4. Configure Gateway URL

Update `ZEPTOCLAW_GATEWAY_URL` in `wrangler.toml`:

```toml
[vars]
ZEPTOCLAW_GATEWAY_URL = "http://localhost:18789"
```

For production, use your actual gateway URL:

```toml
ZEPTOCLAW_GATEWAY_URL = "https://your-gateway-domain.com"
```

### 5. Set Secrets (Optional)

If your gateway requires authentication:

```bash
wrangler secret put ZEPTOCLAW_API_KEY
# Paste your API key when prompted
```

### 6. Login to Cloudflare

```bash
wrangler login
```

### 7. Deploy

```bash
npm run deploy
# or
./deploy.sh
```

## Endpoints

### OpenAI-Compatible API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat completions with streaming support |
| `/v1/models` | GET | List available models |

### Health & Monitoring

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health status of all gateways |
| `/reset` | POST | Reset all gateway cooldowns |

### Heartbeat & State

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/heartbeat` | POST | Local agent heartbeat |
| `/state` | GET | Full state view |
| `/state/reset` | POST | Reset state |

### Incident Tracking

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/gateway/incident` | POST | Report gateway incident |
| `/gateway/incidents` | GET | View recent incidents |
| `/gateway/incidents/clear` | POST | Clear incidents |

## Usage Examples

### Chat Completions

```bash
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello, ZeptoClaw!"}
    ]
  }'
```

### Health Check

```bash
curl https://zeptoclaw-router.your-subdomain.workers.dev/health | jq
```

### Heartbeat (from local agent)

```bash
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": 1704067200000,
    "hostname": "my-server",
    "gateway_pid": 12345,
    "gateway_http_status": "ok",
    "memory_mb": 512
  }'
```

### Report Incident

```bash
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/gateway/incident \
  -H "Content-Type: application/json" \
  -d '{
    "type": "stuck_session",
    "session_id": "abc123",
    "stuck_duration_seconds": 600,
    "hostname": "my-server",
    "error": "Session stuck for 10 minutes"
  }'
```

## Development

### Local Development

```bash
npm run dev
```

This starts the worker locally at `http://localhost:8787`.

### Type Checking

```bash
npm run typecheck
```

### View Logs

```bash
npm run tail
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ZEPTOCLAW_GATEWAY_URL` | URL of ZeptoClaw gateway | `http://localhost:18789` |
| `ZEPTOCLAW_API_KEY` | Optional API key for gateway authentication | - |

### Secrets

Set via `wrangler secret put`:

- `ZEPTOCLAW_API_KEY` - Optional API key for gateway authentication

## Health Tracking

The worker automatically tracks gateway health:

- **Cooldown Periods**: Failed gateways enter cooldown with exponential backoff
- **Latency Tracking**: Average latency calculated over requests
- **Success Rate**: Tracks successful vs failed requests
- **Automatic Recovery**: Cooldowns reset when all gateways are exhausted

## Heartbeat System

The local ZeptoClaw gateway should send heartbeats to signal it's alive:

```bash
# Send heartbeat every 2 minutes via cron
*/2 * * * * curl -X POST https://worker-url/heartbeat \
  -H "Content-Type: application/json" \
  -d '{"timestamp": '$(date +%s)000'}'
```

If the local agent doesn't ping for over an hour, the worker can take over autonomous operations.

## Incident Tracking

Gateway incidents (stuck sessions, crashes) can be reported and viewed:

```bash
# Report incident
curl -X POST /gateway/incident \
  -H "Content-Type: application/json" \
  -d '{"type": "stuck_session", ...}'

# View incidents
curl /gateway/incidents | jq

# Clear incidents
curl -X POST /gateway/incidents/clear
```

## Integration with ZeptoClaw

The worker integrates with ZeptoClaw's systemd services:

1. **Gateway Watchdog**: Reports incidents when gateway is stuck
2. **Heartbeat Timer**: Sends periodic heartbeats to worker
3. **State Sync**: Worker maintains state when local agent is down

### Systemd Timer Setup

```bash
# Copy service files
cp /home/user/zeptoclaw/cloudflare-worker/zeptoclaw-heartbeat.* ~/.config/systemd/user/

# Reload systemd
systemctl --user daemon-reload

# Enable and start timer
systemctl --user enable --now zeptoclaw-heartbeat.timer
```

## Troubleshooting

### Gateway Not Responding

1. Check health endpoint: `curl /health`
2. Verify gateway URL in `wrangler.toml`
3. Check gateway logs: `journalctl --user -u zeptoclaw-gateway -f`
4. Reset cooldowns: `curl -X POST /reset`

### KV Namespace Issues

```bash
# List KV namespaces
wrangler kv:namespace list

# Recreate if needed
wrangler kv:namespace create "GATEWAY_HEALTH"
wrangler kv:namespace create "ZEPTOCLAW_STATE"
```

### Deployment Errors

```bash
# Check wrangler version
wrangler --version

# Re-login
wrangler login

# Check configuration
wrangler tail
```

## Testing

### Run Test Script

```bash
./test.sh
```

### Manual Tests

```bash
# Health check
curl https://zeptoclaw-router.your-subdomain.workers.dev/health

# Chat completions
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}]}'

# State view
curl https://zeptoclaw-router.your-subdomain.workers.dev/state
```

## License

MIT - Same as ZeptoClaw.

## Related

- [ZeptoClaw](https://github.com/bkataru/zeptoclaw) - Main repository
- [OpenClaw](https://github.com/anomalyco/opencode) - Agent framework
- [Barvis](https://www.moltbook.com/u/barvis_da_jarvis) - AI agent on Moltbook
