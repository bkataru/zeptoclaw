# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**0.4.0** (2026-09-04). Native WhatsApp is the only transport. `zig build test --summary all`: 468 pass, 3 skip without `NVIDIA_API_KEY`. Zig 0.16.0.

## Recent Updates

- **Native-only WhatsApp** (0.4.0): the Node child, root `package.json`, and all Node spawn/JSON-RPC paths are gone. Pair with `zeptoclaw whatsapp pair`, which now works without `NVIDIA_API_KEY`
- **Group replies reach your phone** (0.4.0): group sends query usync for own devices and include them in the SKDM fanout. A group @mention of the bot also triggers a turn
- **Outbound edits and revokes** (0.4.0): the stanza carries `edit` (`1` / `7` / `8`); inbound edits decode. A group retry receipt resends SKDM plus skmsg (cap 5 per message)
- **Self-heal re-pair** (0.4.0): a 401 logout starts QR re-pair instead of leaving a dead session
- **usync fix**: the binary encoder wrote JID attributes as plain text instead of the `JIDPair`/`ADJID` tags the server needs. usync now resolves in about 300ms instead of timing out
- **LID self-chat fix**: 1:1 chats arrive on the recipient LID, not the phone number. `sendText` resolves PN/LID pairs from `lid_map` and sets `peer_recipient_pn`
- **Automatic retry-receipt recovery**: on a `<receipt type=retry>`, the client drops the stale session, fetches a fresh prekey bundle, and resends with the same message id (cap 5 per message). `zeptoclaw-wa-send` forces a fresh handshake by hand
- **`POST /reload`**: hot-reloads `allowFrom`, `dmPolicy`, and `groupPolicy` without restarting the gateway
- **`exec` gating**: the `exec` tool runs only on an operator `fromMe` DM. A partner DM cannot invoke it
- **Agent loop on WhatsApp** (2026-08-22): gateway inbound goes through `Agent.runTurn` (workspace markdown + tools + NIM), not `NIMClient.chat` once
- **Memory**: daily journals `~/.zeptoclaw/workspace/memory/YYYY-MM-DD.md` (full `[in]`/`[out]`, no 2000-char clip). Tools `memory_get` / `memory_search` / `memory_append` / `memory_edit`. `zeptoclaw memory update` every 30 min (decide then synthesize). `zeptoclaw memory compact` every 2 h (densify MEMORY.md, does not dump journals)
- **WhatsApp reliability**: inbound ledger (wire id + 3 min fingerprint), LID/`fromMe` allowlist DMs, handler off the poll thread, auto-reconnect on disconnect (not `loggedOut`)
- **Pending turns**: `pending-turns.jsonl` under `sessions/whatsapp/`. Enqueue before NIM, ack after send or silent `listen`/`leave`. Replay on `connection status=connected` after SIGKILL
- **Burst coalesce**: while NIM is in flight for a chat, later messages on that JID merge into one follow-up turn (cap 16). First reply still answers the starter message
- **Inbound images**: download to `sessions/whatsapp/media/`, last-image per JID, attach as NIM `image_url` on that chat's later turns (4MB cap)
- **Same-chat journal hydrate**: `dailyContext` injects today's + yesterday's lines matching `] (chat_id):` so a restart still has thread
- **Signature**: Zig `engagement.appendSignature` appends ⚡ (U+26A1) after sendable replies. Silent listen/leave stay unsigned
- **Parser fuzz**: `zeptoclaw fuzz [iters]` (default 50000). Optional `zeptoclaw-fuzz.timer`. `zig build test --fuzz` is broken on Zig 0.16.0 (`test_runner` StackTrace). See `docs/fuzz.md`
- **Live dirs**: `~/.zeptoclaw/{workspace,sessions,config.json}`. WhatsApp session `~/.zeptoclaw/sessions/whatsapp/native.sqlite`
- **Zig 0.16.0 Migration** (February 28, 2026): All 11 phases finalized with zero errors
- **ArrayList API**: Fixed `toOwnedSlice()` across all 9 skill modules (nufast_physics, knowledge_base, semantic_search, local_llm, adhd_workflow, dirmacs_docs, planckeon_sites, discovery, memory_tree_search)
- **Thread Safety**: Added mutex protection to WhatsApp channel shared state; eliminated global mutable state via per-execution skill instances
- **HTTP Robustness**: Implemented configurable request timeouts in NIMClient (default 120s) to prevent hangs
- **Type Safety**: Replaced all 31 `@intCast` occurrences with validated `std.math.cast` and error propagation across 18 files
- **Error Handling**: Reviewed 117 `catch unreachable` patterns; kept unreachable where genuinely impossible (with comments), propagated errors in test fixtures
- **Testing & Quality**: Restored integration tests with proper Config; added unit tests for ConfigLoader error paths; thread safety stress tests for WhatsApp channel
- **Production Hardening**: Config validation at startup; StateStore.save() with atomic writes; structured logging; graceful shutdown (SIGINT/SIGTERM); health and Prometheus metrics endpoints
- **Memory & Security**: Fixed Config.deinit() to prevent leaks; removed sensitive credentials from logs; corrected errdefer in ConfigLoader

## Project Metrics

| Metric | Value |
|--------|-------|
| **Zig source files** | 119 |
| **Lines of code** | ~46.6k in `src/` |
| **Build errors** | 0 |
| **Tests** | 471 (468 pass, 3 skip) |
| **Binaries** | 6 |
| **Skills ported** | 21 |

### Binaries

| Binary | Description |
|--------|-------------|
| `zeptoclaw` | CLI, `whatsapp pair`, `memory update`, `memory compact`, `fuzz` |
| `zeptoclaw-gateway` | HTTP + WhatsApp (port 18789) |
| `zeptoclaw-webhook` | Webhook helper (port 9000) |
| `zeptoclaw-shell2http` | Shell-over-HTTP (port 9001) |
| `zeptoclaw-wa-pair` | Terminal-QR pairing for native WhatsApp mode |
| `zeptoclaw-wa-send <db-path> <to-jid> <text>` | One-shot native-mode DM sender; forces a fresh Signal handshake after a session desync |

## What is this?

ZeptoClaw is a custom, from-scratch AI agent framework written in **Zig 0.16.0+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

**Key features:**
- NVIDIA NIM native: `nvidia/nemotron-3-ultra-550b-a55b` primary, `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` as fallback and vision (`see_image` tool)
- Zero bloat, built from scratch
- UTCP (Universal Tool Calling Protocol) support
- Modular: providers, agents, channels, tools
- WhatsApp channel integration: native Zig multi-device client (`native/`). DM and group text, inbound/outbound media, presence, reactions, and polls
- Agent loop: `read` / `write` / `edit` / `exec` / `web_search` / `see_image` / `listen` / `leave` / `skill` / `memory_*`
- 21 skills ported from OpenClaw
- Cloudflare Worker for resilient routing
- WhatsApp and the CLI share `Agent.runTurn`

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** - Install via [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API Key** - Get yours from [NVIDIA NIM](https://build.nvidia.com/)

## Configuration

Set required environment variables:

```bash
# Required: NVIDIA API key
export NVIDIA_API_KEY=nvapi-xxx

# Optional: Primary model (defaults to nvidia/nemotron-3-ultra-550b-a55b); nano-omni is used as fallback and vision
export NVIDIA_MODEL=nvidia/nemotron-3-ultra-550b-a55b

# Optional: HTTP gateway token (config gateway.auth.token also works)
export GATEWAY_AUTH_TOKEN=your_token

# Optional: heartbeat cron interval; 0 disables (keep 0 while chatting)
export ZEPTO_CRON_SECS=0

# Optional: 30-min journal ingest interval; 0 disables
export ZEPTO_MEMORY_SECS=1800

# Moltbook integration (if using)
export MOLTBOOK_API_KEY=your_key
export MOLTBOOK_USER_ID=your_user_id
```

WhatsApp allowlist is config (`channels.whatsapp.allowFrom`, `dmPolicy`). Keys in systemd or `chmod 600` env files. WhatsApp session store: `~/.zeptoclaw/sessions/whatsapp/native.sqlite`. Memory compact oneshot: `~/.config/zeptoclaw/nim.env`.

## Usage

### Build and Run

```bash
# Build all binaries
zig build

# Run the main agent
./zig-out/bin/zeptoclaw

# Run gateway server (WhatsApp + HTTP)
./zig-out/bin/zeptoclaw-gateway

# Memory jobs (own process / own NIM backoff; share NVIDIA quota)
./zig-out/bin/zeptoclaw memory update    # ingest journals -> MEMORY.md
./zig-out/bin/zeptoclaw memory compact   # densify MEMORY.md
./zig-out/bin/zeptoclaw fuzz 50000       # parser havoc (no NIM)

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

WhatsApp inbound (gateway) is the same loop: workspace markdown as the system prompt, tools until final text, then send.

## Architecture

```
src/
├── main.zig                    # Entry point
├── root.zig                    # Library root
├── config.zig                  # Configuration
├── fuzz_mutate.zig             # Parser havoc (no NIM HTTP)
├── openclaw_compat/            # Path/config bridge (~/.zeptoclaw then ~/.openclaw)
├── providers/                  # LLM providers
│   ├── types.zig               # OpenAI-compatible types
│   ├── nim.zig                 # NVIDIA NIM client
│   ├── provider_pool.zig       # Provider pooling
│   ├── health_tracker.zig      # Health monitoring
│   └── fallback_router.zig     # Fallback routing
├── agent/                      # Agent framework
│   ├── message.zig             # Message utilities
│   ├── tools.zig               # Tool registry
│   ├── core_tools.zig          # Workspace read/write/edit/exec + search
│   ├── transcript.zig          # Turn transcripts (sessions/transcripts/)
│   ├── cron.zig                # Optional heartbeat turns
│   ├── memory.zig              # Daily journals + extractive fallback
│   ├── memory_update.zig       # 30-min ingest (decide then synthesize)
│   ├── memory_compact.zig      # 2-hour densify
│   └── loop.zig                # Agent loop (runTurn)
├── channels/                   # I/O channels
│   ├── cli.zig                 # CLI channel
│   ├── session.zig             # Session management
│   ├── input.zig               # Input handling
│   ├── stream.zig              # Streaming utilities
│   └── whatsapp/               # WhatsApp channel
│       ├── whatsapp_channel.zig
│       ├── pending.zig         # pending-turns.jsonl
│       ├── inbound_media.zig   # last-image per JID
│       ├── engagement.zig      # language extra, ⚡, subscribe/leave
│       ├── inbound.zig
│       ├── outbound.zig
│       ├── session.zig
│       ├── config.zig
│       ├── access_control.zig
│       ├── types.zig
│       └── native/             # multi-device client (Noise + Signal; live transport)
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
| **Agent** | Main agent loop with conversation state (`runTurn`) |
| **Providers** | LLM provider abstraction (NVIDIA NIM) |
| **Channels** | I/O abstraction (CLI, WhatsApp, etc.) |
| **Tools** | UTCP registry + core_tools (`read`/`write`/`edit`/`exec`/`memory_*`) |
Unit templates live in `systemd/` and `contrib/systemd/` (no secrets):

| Service | Description | Port |
|---------|-------------|------|
| `zeptoclaw-gateway.service` | Main gateway server | 18789 |
| `zeptoclaw-webhook.service` | Webhook server | 9000 |
| `zeptoclaw-shell2http.service` | Shell-over-HTTP server | 9001 |
| `gateway-watchdog.service` + timer | Gateway health monitor (every 2 min) | - |
| `whatsapp-responder.service` + timer | Leftover; live replies come from the gateway | - |
| `moltbook-heartbeat.service` + timer | Moltbook heartbeat (every 30 min) | - |
| `workspace-sync.timer` | Workspace sync (every 30 min) | - |
| `barvis-memory-update.service` + timer | `zeptoclaw memory compact` (every 2 h; in `contrib/`) | - |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (in `contrib/`) | - |

Repo templates have **no secrets**. Put `NVIDIA_API_KEY` and `GATEWAY_AUTH_TOKEN` on the local user unit (e.g. `~/.config/systemd/user/zeptoclaw-gateway.service`). If `systemctl --user restart` hangs: `systemctl --user kill` plus `pkill` the gateway, then `start`.

### Installation

```bash
# Create systemd user directory
mkdir -p ~/.config/systemd/user

# Copy service files
cp systemd/*.service ~/.config/systemd/user/
cp systemd/*.timer ~/.config/systemd/user/

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
cd scripts/migrate

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

Live WhatsApp session store is `~/.zeptoclaw/sessions/whatsapp/native.sqlite` (not in the public repo). `barvis-sync` copies it into private barvis `zeptoclaw-state/`.

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

Native multi-device client (Zig). Pair with `zeptoclaw whatsapp pair`. Session store: `{auth_dir}/native.sqlite`.

- `access_control.zig` - Access control logic
- `config.zig` - Configuration management
- `inbound.zig` - Inbound message handling
- `outbound.zig` - Outbound message handling
- `session.zig` - Session management
- `types.zig` - Type definitions
- `whatsapp_channel.zig` - Main channel logic
- `pending.zig` - Unacked inbound queue (`pending-turns.jsonl`)
- `inbound_media.zig` - Last inbound image per JID
- `engagement.zig` - Language extra, ⚡ signature, subscribe/leave

Replay is **message id + fingerprint** (`chatId|fromMe|body`), with a 3-minute same-body skip - not a mute window after connect. Wake word is **barvis** except allowlisted DMs / LID self-chat. `leave` unsubscribes a chat until the next barvis.

Pending turns replay on WhatsApp `connected`. Burst messages while NIM is in flight merge into a follow-up. Same-JID inbound images attach as NIM vision. Journals hydrate same-chat history after restart.

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
./zig-out/bin/zeptoclaw fuzz 2000
```

### Project structure

- `src/` (119 Zig files, ~44.7k lines)
- `vendor/` (zeitgeist, comprezz)
- `systemd/` and `contrib/systemd/` (unit templates, no secrets)
- `scripts/migrate/`
- `cloudflare-worker/`
- `testdata/fuzz/`
- `docs/` (`whatsapp.md`, `memory.md`, `openclaw-compat.md`, `fuzz.md`, runbooks)

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

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto...) - emphasizing minimalism
- **Claw** = Part of the "Claw" family (NullClaw, KrillClaw, TinyClaw)
- **Z** = Starts with Z, like Zig

## License

MIT - Same as the rest of the Claw family.

---

## History

August 2026 wired WhatsApp through `runTurn`, hardened the inbound ledger, and added pending turns, burst coalesce, vision, and parser fuzz. September 2026 made the native client the sole transport, with a usync fix, a LID self-chat fix, and retry-receipt recovery. 0.4.0 adds group @mention triggers, outbound edits/revokes, group retry SKDM resends, own-phone group delivery, and self-heal re-pair. History was rewritten once to drop live tokens and junk blobs; clones follow current `main`.

---

**Status:** v0.4.0 tagged. Native-only WhatsApp transport, group @mention trigger, outbound edits/revokes, group retry SKDM resends, own-phone group delivery, self-heal re-pair. WhatsApp `runTurn` plus journals plus memory update/compact, NIM retry caps with fallback replies, tool-output UTF-8 scrub, native media decoder fixes.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
