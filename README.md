# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.15.2 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**Zig 0.15.2 Migration Complete** - Build and tests passing with 0 errors (Completed: February 28, 2026)

## Recent Updates

- **Zig 0.15.2 Migration** (February 28, 2026): All 11 phases finalized with zero errors
- **ArrayList API**: Fixed `toOwnedSlice()` across all 9 skill modules (nufast_physics, knowledge_base, semantic_search, local_llm, adhd_workflow, dirmacs_docs, planckeon_sites, discovery, memory_tree_search)
- **Thread Safety**: Added mutex protection to WhatsApp channel shared state; eliminated global mutable state via per-execution skill instances
- **HTTP Robustness**: Implemented configurable request timeouts in NIMClient (default 30s) to prevent hangs
- **Type Safety**: Replaced all 31 `@intCast` occurrences with validated `std.math.cast` and error propagation across 18 files
- **Error Handling**: Reviewed 117 `catch unreachable` patterns; kept unreachable where genuinely impossible (with comments), propagated errors in test fixtures
- **Testing & Quality**: Restored integration tests with proper Config; added unit tests for ConfigLoader error paths; thread safety stress tests for WhatsApp channel
- **Production Hardening**: Config validation at startup; StateStore.save() with atomic writes; structured logging; graceful shutdown (SIGINT/SIGTERM); health and Prometheus metrics endpoints
- **Memory & Security**: Fixed Config.deinit() to prevent leaks; removed sensitive credentials from logs; corrected errdefer in ConfigLoader

## Project Metrics

| Metric | Value |
|--------|-------|
| **Zig Source Files** | 70 files |
| **Lines of Code** | 19,717 lines |
| **Build Errors** | 0 |
| **Binaries Produced** | 4 |
| **Systemd Services** | 10 |
| **Skills Ported** | 21 |
| **Migration Phases** | 11/11 complete |

### Binaries

| Binary | Size | Description |
|--------|------|-------------|
| `zeptoclaw` | 43 MB | Main agent binary |
| `zeptoclaw-gateway` | 34 MB | HTTP gateway server (port 18789) |
| `zeptoclaw-webhook` | 12 MB | Webhook server (port 9000) |
| `zeptoclaw-shell2http` | 12 MB | Shell2HTTP server (port 9001) |

## What is this?

ZeptoClaw is a custom, from-scratch AI agent framework written in **Zig 0.15.2+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

**Key features:**
- NVIDIA NIM native with `qwen/qwen3.5-397b-a17b`
- Zero bloat, built from scratch
- UTCP (Universal Tool Calling Protocol) support
- Modular: providers, agents, channels, tools
- WhatsApp channel integration
- 21 skills ported from OpenClaw
- Cloudflare Worker for resilient routing

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.15.2+** - Install via [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API Key** - Get yours from [NVIDIA NIM](https://build.nvidia.com/)

## Configuration

Set required environment variables:

```bash
# Required: NVIDIA API key
export NVIDIA_API_KEY=nvapi-xxx

# Optional: Model (defaults to qwen/qwen3.5-397b-a17b)
export NVIDIA_MODEL=qwen/qwen3.5-397b-a17b

# Moltbook integration (if using)
export MOLTBOOK_API_KEY=your_key
export MOLTBOOK_USER_ID=your_user_id
```

## Usage

### Build and Run

```bash
# Build all binaries
zig build

# Run the main agent
./zig-out/bin/zeptoclaw

# Run gateway server
./zig-out/bin/zeptoclaw-gateway

# Run webhook server
./zig-out/bin/zeptoclaw-webhook

# Run shell2http server
./zig-out/bin/zeptoclaw-shell2http
```

### Interactive CLI

Once running, you'll enter an interactive session where you can:
- Chat with the AI agent
- Use tools via UTCP
- Execute commands and get responses

## Architecture

```
src/
├── main.zig                    # Entry point
├── root.zig                    # Library root
├── config.zig                  # Configuration
├── providers/                  # LLM providers
│   ├── types.zig               # OpenAI-compatible types
│   ├── nim.zig                 # NVIDIA NIM client
│   ├── provider_pool.zig       # Provider pooling
│   ├── health_tracker.zig      # Health monitoring
│   └── fallback_router.zig     # Fallback routing
├── agent/                      # Agent framework
│   ├── message.zig             # Message utilities
│   ├── tools.zig               # Tool registry
│   └── loop.zig                # Agent loop
├── channels/                   # I/O channels
│   ├── cli.zig                 # CLI channel
│   ├── session.zig             # Session management
│   ├── input.zig               # Input handling
│   ├── stream.zig              # Streaming utilities
│   └── whatsapp/               # WhatsApp channel
│       ├── whatsapp_channel.zig
│       ├── inbound.zig
│       ├── outbound.zig
│       ├── session.zig
│       ├── config.zig
│       ├── access_control.zig
│       └── types.zig
├── services/                   # HTTP services
│   ├── gateway_server.zig      # Main gateway
│   ├── webhook_server.zig      # Webhook handling
│   ├── shell2http_server.zig   # Shell2HTTP
│   └── http_server.zig         # HTTP utilities
├── skills/                     # Skill implementations
│   ├── skill_registry.zig      # Skill management
│   ├── skill_loader.zig        # Dynamic loading
│   ├── skill_sdk.zig           # SDK for skills
│   ├── triggers.zig            # Skill triggers
│   ├── execution_context.zig   # Execution context
│   ├── types.zig               # Skill types
│   └── [skill_name]/skill.zig  # Individual skills
├── autonomous/                 # Autonomous operations
│   ├── autonomous.zig          # Main autonomous logic
│   ├── agent_framework.zig     # Agent framework
│   ├── moltbook_client.zig     # Moltbook integration
│   ├── rate_limiter.zig        # Rate limiting
│   ├── state_store.zig         # State persistence
│   └── types.zig               # Type definitions
└── gateway/                    # Gateway components
    ├── http_server.zig         # HTTP server
    ├── session_store.zig       # Session storage
    ├── token_auth.zig          # Token authentication
    └── control_ui.zig          # Control UI
```

### Core Components

| Component | Description |
|-----------|-------------|
| **NIMClient** | HTTP client for NVIDIA NIM API |
| **Agent** | Main agent loop with conversation state |
| **Providers** | LLM provider abstraction (NVIDIA NIM) |
| **Channels** | I/O abstraction (CLI, WhatsApp, etc.) |
| **Tools** | UTCP-compatible tool registry |
| **Skills** | 21 ported skills from OpenClaw |

## Systemd Services

10 systemd service and timer files are provided for automated operation:

| Service | Description | Port |
|---------|-------------|------|
| `zeptoclaw-gateway.service` | Main gateway server | 18789 |
| `zeptoclaw-webhook.service` | Webhook server | 9000 |
| `zeptoclaw-shell2http.service` | Shell2HTTP server | 9001 |
| `gateway-watchdog.service` | Gateway health monitor | - |
| `whatsapp-responder.service` | WhatsApp message handler | - |
| `moltbook-heartbeat.service` | Moltbook heartbeat | - |
| `gateway-watchdog.timer` | Monitor gateway (every 2 min) | - |
| `whatsapp-responder.timer` | Process messages (every 15 min) | - |
| `moltbook-heartbeat.timer` | Heartbeat (every 30 min) | - |
| `workspace-sync.timer` | Workspace sync (every 30 min) | - |

### Installation

```bash
# Create systemd user directory
mkdir -p ~/.config/systemd/user

# Copy service files
cp /home/user/zeptoclaw/systemd/*.service ~/.config/systemd/user/
cp /home/user/zeptoclaw/systemd/*.timer ~/.config/systemd/user/

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now zeptoclaw-webhook.service
systemctl --user enable --now zeptoclaw-shell2http.service
systemctl --user enable --now gateway-watchdog.service
systemctl --user enable --now whatsapp-responder.service
systemctl --user enable --now moltbook-heartbeat.service
systemctl --user enable --now gateway-watchdog.timer
systemctl --user enable --now whatsapp-responder.timer
systemctl --user enable --now moltbook-heartbeat.timer
systemctl --user enable --now workspace-sync.timer
```

### Management

```bash
# List services
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*'

# List timers
systemctl --user list-timers --all

# View logs
journalctl --user -u zeptoclaw-gateway -f
```

## Migration from OpenClaw

All 11 migration phases are complete. The following has been migrated:

### Data Migration

5 scripts are available in `scripts/migrate/`:

| Script | Purpose |
|--------|---------|
| `migrate-all.sh` | Master migration script |
| `migrate-credentials.sh` | WhatsApp credentials |
| `migrate-sessions.sh` | Session data |
| `migrate-memory.sh` | Memory/embeddings |
| `migrate-secrets.sh` | Secrets with rotation |

### Usage

```bash
cd /home/user/zeptoclaw/scripts/migrate

# Dry run (recommended first)
./migrate-all.sh --dry-run

# Full migration
./migrate-all.sh

# Individual migrations
./migrate-credentials.sh
./migrate-sessions.sh
./migrate-memory.sh
./migrate-secrets.sh
```

### Skills Migration

21 skills ported from OpenClaw:

| Skill | Description |
|-------|-------------|
| `adhd_workflow` | ADHD workflow management |
| `discovery` | Discovery and exploration |
| `dirmacs_docs` | Documentation generation |
| `gateway_watchdog` | Gateway monitoring |
| `git_workflow` | Git operations |
| `github` | GitHub integration |
| `github_stars` | GitHub stars management |
| `knowledge_base` | Knowledge base operations |
| `local_http_services` | Local HTTP service management |
| `local_llm` | Local LLM operations |
| `memory_tree_search` | Memory tree search |
| `moltbook` | Moltbook integration |
| `moltbook_heartbeat` | Moltbook heartbeat |
| `nufast_physics` | Physics calculations |
| `operational_safety` | Operational safety checks |
| `planckeon_sites` | Site management |
| `rust_cargo` | Rust/Cargo operations |
| `semantic_search` | Semantic search |
| `web_qa` | Web Q&A |
| `wsl_troubleshooting` | WSL troubleshooting |
| `zig_dev` | Zig development |

### WhatsApp Channel

Fully implemented with 7 files:

- `access_control.zig` - Access control logic
- `config.zig` - Configuration management
- `inbound.zig` - Inbound message handling
- `outbound.zig` - Outbound message handling
- `session.zig` - Session management
- `types.zig` - Type definitions
- `whatsapp_channel.zig` - Main channel logic

## Cloudflare Worker

ZeptoClaw includes a Cloudflare Worker for resilient OpenAI-compatible API routing with automatic failover.

### Features

- OpenAI-compatible `/v1/chat/completions` endpoint
- Gateway health tracking with cooldowns
- Automatic failover with exponential backoff
- Heartbeat system for local agent monitoring
- Incident tracking and state management
- Persistent state via Cloudflare KV

### Quick Start

```bash
cd cloudflare-worker

# Install dependencies
npm install

# Create KV namespaces
wrangler kv:namespace create "GATEWAY_HEALTH"
wrangler kv:namespace create "ZEPTOCLAW_STATE"

# Update wrangler.toml with KV namespace IDs, then deploy
./deploy.sh
```

See [cloudflare-worker/README.md](cloudflare-worker/README.md) for detailed instructions.

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat |
| `/v1/models` | GET | List models |
| `/health` | GET | Gateway health status |
| `/heartbeat` | POST | Local agent heartbeat |
| `/state` | GET | Full state view |
| `/gateway/incident` | POST | Report incident |
| `/gateway/incidents` | GET | View incidents |

## Development

### Build

```bash
zig build
```

### Run tests

```bash
zig build test
```

### Project structure

- `src/` - Main source code (70 files, 19,717 lines)
- `vendor/` - Vendored dependencies
- `systemd/` - Systemd service files (10 files)
- `scripts/migrate/` - Migration scripts (5 scripts)
- `cloudflare-worker/` - Cloudflare Worker implementation

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [utcp](https://github.com/bkataru/zig-utcp) | Universal Tool Calling Protocol |
| [mcp.zig](https://github.com/bkataru/mcp.zig) | Model Context Protocol |
| [raikage](https://github.com/bkataru/raikage) | Encryption utilities |
| [hf-hub-zig](https://github.com/bkataru/hf-hub-zig) | HuggingFace Hub integration |
| [niza](https://github.com/bkataru/niza) | Utility functions |
| [zenmap](https://github.com/bkataru/zenmap) | Data structures |
| [zeitgeist](vendor/zeitgeist) | Time-series memory (vendored) |
| [comprezz](vendor/comprezz) | Compression utilities (vendored) |

## Testing and Verification

### Build verification

```bash
# Clean build
zig build --release=safe

# Check binary sizes
ls -lh zig-out/bin/
```

### Service verification

```bash
# Check gateway is running
curl http://localhost:18789/health

# Check webhook
curl http://localhost:9000/health

# Check shell2http
curl http://localhost:9001/health
```

### Cloudflare Worker verification

```bash
# Health check
curl https://zeptoclaw-router.your-subdomain.workers.dev/health

# Test chat
curl -X POST https://zeptoclaw-router.your-subdomain.workers.dev/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}]}'
```

## Why "ZeptoClaw"?

- **Zepto** = 10²¹ (smaller than nano, pico, femto...) - emphasizing minimalism
- **Claw** = Part of the "Claw" family (NullClaw, KrillClaw, TinyClaw)
- **Z** = Starts with Z, like Zig

## License

MIT - Same as the rest of the Claw family.

---

## Recent Commits

The following changes were recently committed to complete the Zig 0.15.2 migration:

1. **fix: Implement Config.deinit() to free allocated fields** - Prevents memory leaks by freeing all allocated Config fields
2. **fix: Correct fallback_models allocation in migration config** - Fixes static slice allocation issues
3. **fix: Resolve memory leaks in provider test fixtures** - Adds proper cleanup in tests
4. **fix: Correct ArrayList API usage in provider modules** - Fixes append() and toOwnedSlice() calls
5. **fix: Fix ArrayList.toOwnedSlice() in WhatsApp channel** - Ensures API compliance across channel files
6. **fix: Update knowledge_base skill for Zig 0.15.2 compatibility** - Updates skill for latest Zig version

---

**Status:** Migration Complete - All 11 phases finished with 0 errors

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
