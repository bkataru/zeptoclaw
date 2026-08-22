# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

Tagged **v0.1.0** (2026-08-22). Toolchain is **Zig 0.16.0**. Later `main` commits add WhatsApp durability (pending replay, burst coalesce, inbound vision) and parser fuzzing; those are not a new tag.

`zig build test` is the compile-and-parser gate. NIM integration tests skip without `NVIDIA_API_KEY`. `zig build test --fuzz` does not rebuild on 0.16.0 (`test_runner` StackTrace); use `zeptoclaw fuzz` instead. See [docs/fuzz.md](docs/fuzz.md).

## Recent Updates

Post-tag behavior that is now the live contract (detail in [CHANGELOG.md](CHANGELOG.md), [docs/whatsapp.md](docs/whatsapp.md), [docs/memory.md](docs/memory.md)):

- WhatsApp inbound is `Agent.runTurn` (workspace markdown + tools + NIM), not one-shot `NIMClient.chat`
- Same-chat journal hydrate after restart; `pending-turns.jsonl` replay after SIGKILL; burst coalesce while NIM is in flight; last inbound image on that JID attached as NIM vision
- Daily journals `~/.zeptoclaw/workspace/memory/YYYY-MM-DD.md` (`[in]`/`[out]`, full text). Tools `memory_*`. Child `zeptoclaw memory update` (30 min). `zeptoclaw memory compact` (2 h)
- Replay ledger is Baileys id + 3-minute body fingerprint. No wall-clock mute after connect. `RpcTimeout` is a failed send ACK
- Live tree: `~/.zeptoclaw/{workspace,sessions,config.json}`. Baileys auth `sessions/whatsapp/`

Zig 0.16 ArrayList/`@intCast` migration notes belong in git history, not here.

## Project Metrics

Scale of `src/` (re-count after a large move). Not a scoreboard: test counts, binary sizes, and "zero errors" change every commit.

| | |
|--|--|
| Zig files under `src/` | 106 |
| Lines in those files | ~29k |
| Binaries from `zig build` | 4 (`zeptoclaw`, `zeptoclaw-gateway`, `zeptoclaw-webhook`, `zeptoclaw-shell2http`) |
| State root | `~/.zeptoclaw` |
| Gateway listen | `18789` |

### Binaries

| Binary | Role |
|--------|------|
| `zeptoclaw` | CLI, `whatsapp pair`, `memory update`, `memory compact`, `fuzz` |
| `zeptoclaw-gateway` | HTTP control plane + WhatsApp (port 18789) |
| `zeptoclaw-webhook` | Webhook helper (port 9000) |
| `zeptoclaw-shell2http` | Shell-over-HTTP (port 9001) |

## What is this?

ZeptoClaw is a custom, from-scratch AI agent framework written in **Zig 0.16.0+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

**Invariants (the loop, not a feature list):**

- NVIDIA NIM (`thinkingmachines/inkling` default). `chatWithTools` retries forever on RateLimit / Timeout / Network; auth errors fail immediately
- One turn engine: CLI and WhatsApp both call `Agent.runTurn`. Tool rounds cap at 200. Leaked `{"name":...}` chat JSON is hydrated into tool calls
- Tools: `read` / `write` / `edit` / `exec` / `web_search` / `listen` / `leave` / `skill` / `memory_get` / `memory_search` / `memory_append` / `memory_edit`. `exec` is approve-gated unless `ZEPTO_EXEC_APPROVE=1`
- WhatsApp live path is Baileys (`baileys_wrapper.js`). `native/` whatsmeow compiles; it is not wired
- Groups stay deny until a group JID is on `allowFrom`
- Workspace markdown (`SOUL.md`, identity, journals, `MEMORY.md`) is the system prompt source. `MEMORY.md` auto-inject is Baala `fromMe` DMs only
- OpenClaw-shaped skills live under `src/skills/`; they are optional, not the WhatsApp path
- Cloudflare Worker is a separate OpenAI-compatible router + KV, not the local gateway

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** - [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API key** - [build.nvidia.com](https://build.nvidia.com/)
- **Node.js 18+** - WhatsApp wrapper. Set `ZEPTO_NODE` if `node` is not on `PATH` (systemd must set it too)

## Configuration

```bash
export NVIDIA_API_KEY=nvapi-xxx
export NVIDIA_MODEL=thinkingmachines/inkling
export GATEWAY_AUTH_TOKEN=your_token
export ZEPTO_NODE=/usr/bin/node
export ZEPTO_CRON_SECS=0
export ZEPTO_MEMORY_SECS=1800
```

`ZEPTO_CRON_SECS=0` disables heartbeat turns while chatting. `ZEPTO_MEMORY_SECS` is the gateway child's ingest interval (default 1800s; first ingest waits one full interval after start).

WhatsApp allowlist is config (`channels.whatsapp.allowFrom`, `dmPolicy`). Secrets stay in the local systemd unit or `chmod 600` env files (`~/.config/zeptoclaw/nim.env` for memory oneshots). Do not commit them. Fail closed on missing `GATEWAY_AUTH_TOKEN` (tests use placeholders in `token_auth.zig` only).

On-disk layout:

| Path | Meaning |
|------|---------|
| `~/.zeptoclaw/config.json` | Runtime config |
| `~/.zeptoclaw/workspace/` | Soul, skills, `MEMORY.md`, daily journals |
| `~/.zeptoclaw/sessions/whatsapp/` | Baileys auth, inbound ledger, `pending-turns.jsonl`, media |
| `~/.zeptoclaw/sessions/transcripts/` | `Agent` transcripts |

`openclaw_compat` resolves `$HOME/.zeptoclaw` first, then read-only `~/.openclaw`.

## Usage

### Build and Run

```bash
zig build
./zig-out/bin/zeptoclaw
./zig-out/bin/zeptoclaw-gateway
./zig-out/bin/zeptoclaw memory update
./zig-out/bin/zeptoclaw memory compact
./zig-out/bin/zeptoclaw fuzz 50000
./zig-out/bin/zeptoclaw-webhook
./zig-out/bin/zeptoclaw-shell2http
```

### Interactive CLI

`zeptoclaw` with no subcommand is a stdin loop on the same `runTurn` as WhatsApp: workspace markdown as system prompt, tools until final text.

WhatsApp: inbound JSON from Node, access check, enqueue pending, optional journal `[in]`, `runTurn`, send, journal `[out]`, ack pending. Zig appends ⚡ (U+26A1) after the model text (`engagement.appendSignature`). Silent `listen`/`leave` send nothing.

## Architecture

```
src/
├── main.zig                    # CLI entry (pair / memory / fuzz / interactive)
├── root.zig                    # Library root
├── config.zig                  # Config load
├── fuzz_mutate.zig             # Parser havoc (no NIM HTTP)
├── openclaw_compat/            # ~/.zeptoclaw then ~/.openclaw
├── providers/
│   ├── types.zig               # OpenAI-shaped types + image_url
│   ├── nim.zig                 # NVIDIA NIM (chatWithTools, tryParseCompletion)
│   ├── provider_pool.zig
│   ├── health_tracker.zig
│   └── fallback_router.zig
├── agent/
│   ├── loop.zig                # Agent.runTurn, hydrateToolCallsFromContent
│   ├── tools.zig / core_tools.zig
│   ├── transcript.zig
│   ├── cron.zig
│   ├── memory.zig              # journals, dailyContext, lineBelongsToChat
│   ├── memory_update.zig       # 30-min ingest
│   └── memory_compact.zig      # 2-hour densify
├── channels/
│   ├── cli.zig
│   └── whatsapp/
│       ├── whatsapp_channel.zig
│       ├── baileys_wrapper.js  # Live Node transport
│       ├── pending.zig         # pending-turns.jsonl
│       ├── inbound_media.zig   # last-image per JID
│       ├── engagement.zig      # language extra, ⚡, subscribe/leave
│       ├── access_control.zig
│       └── native/             # whatsmeow stubs (not live)
├── services/gateway_server.zig # HTTP + WhatsApp dispatch, burst, replay
├── gateway/                    # token_auth, session_store, control UI
├── skills/                     # OpenClaw-shaped skills
└── autonomous/                 # Moltbook / state_store helpers
```

### Core Components

| Component | Contract |
|-----------|----------|
| **NIMClient** | OpenAI-compatible HTTP to NVIDIA NIM. Multimodal `image_url` when a same-JID image exists |
| **Agent** | `runTurn`: extra context + tools until final assistant text |
| **Channels** | CLI vs WhatsApp; WhatsApp owns RPC, ledger, pending, media |
| **Tools** | UTCP registry + `core_tools` (workspace + `memory_*`) |
| **Memory** | Journal is the trace. `MEMORY.md` is distilled later. Hydrate filters by `] (chat_id):` |
| **Gateway** | Port 18789. Inbound off the RPC reader thread. Burst mutex released during NIM |

## Systemd Services

Templates: `systemd/` and `contrib/systemd/` (no secrets). Live Barvis uses a **local** user unit for the gateway (`ExecStart=%h/zeptoclaw/zig-out/bin/zeptoclaw-gateway`) with `NVIDIA_API_KEY` / `GATEWAY_AUTH_TOKEN` / `ZEPTO_NODE` on that unit only.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Long-running gateway (18789) + WhatsApp + in-process 30-min `memory update` child |
| `barvis-memory-update.timer` | Every 2 h: `zeptoclaw memory compact` (`contrib/systemd/`) |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (`contrib/systemd/`) |
| `zeptoclaw-webhook.service` | Port 9000 |
| `zeptoclaw-shell2http.service` | Port 9001 |
| `gateway-watchdog.timer` | Health ping (every 2 min) |

Other units in `systemd/` (moltbook heartbeat, workspace-sync, whatsapp-responder) are optional around the old OpenClaw-shaped ops, not required for the DM loop.

If `systemctl --user restart` hangs: `systemctl --user kill` plus `pkill` the gateway and `baileys_wrapper`, then `start`.

### Installation

```bash
mkdir -p ~/.config/systemd/user
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
cp contrib/systemd/barvis-memory-update.* contrib/systemd/zeptoclaw-fuzz.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now barvis-memory-update.timer
```

Put keys on the local gateway unit, not the copied template.

### Management

```bash
systemctl --user list-units 'zeptoclaw*' 'gateway*'
systemctl --user list-timers --all
journalctl --user -u zeptoclaw-gateway.service -f
```

## Migration from OpenClaw

Path/config compatibility is `src/openclaw_compat/` ([docs/openclaw-compat.md](docs/openclaw-compat.md)). Data copy scripts remain in `scripts/migrate/`. Live WhatsApp auth is `~/.zeptoclaw/sessions/whatsapp/` (not in this repo). Private `barvis` sync copies it into `zeptoclaw-state/`.

### Data Migration

| Script | Purpose |
|--------|---------|
| `migrate-all.sh` | Master |
| `migrate-credentials.sh` | WhatsApp credentials |
| `migrate-sessions.sh` | Session data |
| `migrate-memory.sh` | Memory/embeddings |
| `migrate-secrets.sh` | Secrets with rotation |

```bash
cd scripts/migrate
./migrate-all.sh --dry-run
./migrate-all.sh
```

### Skills Migration

Skills under `src/skills/` were ported from OpenClaw (`skill` tool). They are not the WhatsApp reliability path. Names: `adhd_workflow`, `discovery`, `dirmacs_docs`, `gateway_watchdog`, `git_workflow`, `github`, `github_stars`, `knowledge_base`, `local_http_services`, `local_llm`, `memory_tree_search`, `moltbook`, `moltbook_heartbeat`, `nufast_physics`, `operational_safety`, `planckeon_sites`, `rust_cargo`, `semantic_search`, `web_qa`, `wsl_troubleshooting`, `zig_dev`.

### WhatsApp Channel

Live: Node `baileys_wrapper.js` (JSON-only stdout, QR on stderr) + Zig `WhatsAppChannel`. Dispatch is off the reader thread. `sendRequest` is single-flight; `RpcTimeout` (~30s) is send ACK failure.

Durability (see [docs/whatsapp.md](docs/whatsapp.md)):

- `inbound-ledger.json`: Baileys ids + fingerprint `chatId|fromMe|body` (3 min)
- `pending-turns.jsonl`: enqueue before NIM, ack after send or silent listen/leave, replay on `connected`
- Burst: per-chat buffer while NIM runs; first reply is the starter message; rest merge into the follow-up
- Vision: inbound image saved under `sessions/whatsapp/media/`; later text on that JID reuses `last-image/`
- Access: `dmPolicy=allowlist`. Wake word **barvis** except allowlisted 1:1 / LID self-chat. `leave` unsubscribes until the next barvis

## Cloudflare Worker

Separate Worker: OpenAI-compatible `/v1/chat/completions` with failover and KV (`BARVIS_STATE` / `ZEPTOCLAW_STATE` share one namespace id). Not a substitute for `zeptoclaw-gateway`.

```bash
cd cloudflare-worker
npm install
./deploy.sh
```

See [cloudflare-worker/README.md](cloudflare-worker/README.md).

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

```bash
zig build
zig build test
./zig-out/bin/zeptoclaw fuzz 2000
```

- `src/` (106 Zig files, ~29k lines)
- `vendor/` (zeitgeist, comprezz)
- `systemd/` and `contrib/systemd/`
- `scripts/migrate/`
- `cloudflare-worker/`
- `testdata/fuzz/` (redacted seed shapes)
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

No npm `openclaw` package. WhatsApp uses Baileys from the Node wrapper only.

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

Parser surfaces (inbound JSON, journal JID filter, pending jsonl, tool-call hydrate, memory decide, NIM completion JSON) are covered by `std.testing.fuzz` corpora plus `src/fuzz_mutate.zig`. Do not fuzz `runTurn` or a live Baileys connect.

## Why "ZeptoClaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto) - emphasizing minimalism
- **Claw** = Part of the "Claw" family (NullClaw, KrillClaw, TinyClaw)
- **Z** = Starts with Z, like Zig

## License

MIT - Same as the rest of the Claw family.

---

Commit-level history: `git log` and [CHANGELOG.md](CHANGELOG.md). History was rewritten once to drop live tokens; clone current `main`.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
