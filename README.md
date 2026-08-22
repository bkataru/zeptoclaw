# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**v0.1.0** was tagged 2026-08-22 against Zig 0.16.0. `main` has moved since then: pending-turn replay, burst coalesce, inbound images, and parser fuzzing. The tag is a snapshot of the WhatsApp `runTurn` cutover plus journals and the memory jobs; install from current `main` if you want the durability work.

`zig build test` compiles the tree and runs parser/unit tests. NIM integration tests skip when `NVIDIA_API_KEY` is unset. Zig 0.16.0's `zig build test --fuzz` fails to rebuild (`test_runner` mixes `builtin.StackTrace` and `debug.StackTrace`). Parser havoc lives in `zeptoclaw fuzz`; see [docs/fuzz.md](docs/fuzz.md).

## Recent Updates

WhatsApp inbound is handled by `Agent.runTurn`: workspace markdown as the system prompt, tools, NVIDIA NIM. Same-chat lines from today's and yesterday's journals (`memory/YYYY-MM-DD.md`) are injected so a restart still has thread. Before NIM, the gateway appends the inbound to `pending-turns.jsonl` and acks it after a send or a silent `listen`/`leave`; leftover rows replay when Baileys reports `connected`. While NIM is in flight for a JID, later messages on that JID buffer (cap 16) and merge into one follow-up turn. Inbound images land under `sessions/whatsapp/media/`; later text on the same JID can attach that file as a NIM `image_url`.

Journals are full `[in]`/`[out]` text (8 MiB reread cap on rewrite). Tools: `memory_get`, `memory_search`, `memory_append`, `memory_edit`. Every 30 minutes the gateway spawns `zeptoclaw memory update` (decide UPDATE/SKIP, then synthesize `MEMORY.md`). Every 2 hours `zeptoclaw memory compact` densifies `MEMORY.md` without dumping journals. `MEMORY.md` is auto-injected only on Baala `fromMe` DMs.

Replay uses Baileys message ids plus a 3-minute fingerprint `chatId|fromMe|body`. Connecting does not mute inbound on wall-clock. `RpcTimeout` (~30s) means the send ACK never came back. State lives under `~/.zeptoclaw/{workspace,sessions,config.json}`; Baileys auth is `sessions/whatsapp/`.

Details: [CHANGELOG.md](CHANGELOG.md), [docs/whatsapp.md](docs/whatsapp.md), [docs/memory.md](docs/memory.md).

## Project Metrics

`src/` as of this writing. File and line counts drift; binaries, state root, and the listen port do not.

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
| `zeptoclaw-gateway` | HTTP control plane and WhatsApp (port 18789) |
| `zeptoclaw-webhook` | Webhook helper (port 9000) |
| `zeptoclaw-shell2http` | Shell-over-HTTP (port 9001) |

## What is this?

ZeptoClaw is a custom, from-scratch AI agent framework written in **Zig 0.16.0+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

The loop is NVIDIA NIM (`thinkingmachines/inkling` by default). `chatWithTools` retries forever on RateLimit, Timeout, and Network; auth errors fail immediately (tests skip the sleep). CLI and WhatsApp both call `Agent.runTurn`. Tool rounds cap at 200. If the model prints `{"name":...}` as chat instead of a tool call, `hydrateToolCallsFromContent` still runs it.

Tools: `read`, `write`, `edit`, `exec`, `web_search`, `listen`, `leave`, `skill`, `memory_get`, `memory_search`, `memory_append`, `memory_edit`. `exec` needs an approval line in `sessions/exec-approvals.txt` unless `ZEPTO_EXEC_APPROVE=1`.

WhatsApp on the live host is Baileys via `baileys_wrapper.js`. `src/channels/whatsapp/native/` (whatsmeow-shaped Zig) compiles and is unwired. Groups stay deny until the group JID is on `allowFrom`. Workspace markdown (`SOUL.md`, identity, journals, `MEMORY.md`) is the system prompt. OpenClaw-shaped skills under `src/skills/` are optional (`skill` tool). The Cloudflare Worker is a separate OpenAI-compatible router with KV; it does not replace `zeptoclaw-gateway`.

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** from [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API key** from [build.nvidia.com](https://build.nvidia.com/)
- **Node.js 18+** for the WhatsApp wrapper. Set `ZEPTO_NODE` if `node` is missing from `PATH`. systemd units must set it as well.

## Configuration

```bash
export NVIDIA_API_KEY=nvapi-xxx
export NVIDIA_MODEL=thinkingmachines/inkling
export GATEWAY_AUTH_TOKEN=your_token
export ZEPTO_NODE=/usr/bin/node
export ZEPTO_CRON_SECS=0
export ZEPTO_MEMORY_SECS=1800
```

`ZEPTO_CRON_SECS=0` turns off heartbeat turns (leave it at 0 while chatting). `ZEPTO_MEMORY_SECS` is how often the gateway child runs `memory update` (default 1800). The first ingest waits one full interval after gateway start.

WhatsApp allowlist is config: `channels.whatsapp.allowFrom` and `dmPolicy`. Put `NVIDIA_API_KEY` and `GATEWAY_AUTH_TOKEN` on the local systemd unit, or in `chmod 600` files such as `~/.config/zeptoclaw/nim.env` for memory oneshots. Missing `GATEWAY_AUTH_TOKEN` fails closed on the gateway; `token_auth.zig` tests use placeholders only.

| Path | Meaning |
|------|---------|
| `~/.zeptoclaw/config.json` | Runtime config |
| `~/.zeptoclaw/workspace/` | Soul, skills, `MEMORY.md`, daily journals |
| `~/.zeptoclaw/sessions/whatsapp/` | Baileys auth, inbound ledger, `pending-turns.jsonl`, media |
| `~/.zeptoclaw/sessions/transcripts/` | `Agent` transcripts |

`openclaw_compat` looks at `$HOME/.zeptoclaw` first, then read-only `~/.openclaw`.

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

`zeptoclaw` with no subcommand reads stdin and runs the same `runTurn` as WhatsApp: workspace markdown, tools, final assistant text.

WhatsApp path: Node emits inbound JSON, Zig checks access, enqueues pending, journals `[in]`, calls `runTurn`, sends, journals `[out]`, acks pending. After the model text, Zig appends ⚡ (U+26A1) via `engagement.appendSignature` if it is not already there. `listen` and `leave` send nothing, so they stay unsigned. Language rules live in `engagement.LANGUAGE_INSTRUCTIONS` and in workspace `SOUL.md`.

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
│       └── native/             # whatsmeow stubs (unwired)
├── services/gateway_server.zig # HTTP + WhatsApp dispatch, burst, replay
├── gateway/                    # token_auth, session_store, control UI
├── skills/                     # OpenClaw-shaped skills
└── autonomous/                 # Moltbook / state_store helpers
```

### Core Components

| Component | What it does |
|-----------|----------------|
| **NIMClient** | OpenAI-compatible HTTP to NVIDIA NIM. Same-JID images go out as `image_url` data URLs (4MB cap). |
| **Agent** | `runTurn` walks extra context and tools until a final assistant message. |
| **Channels** | CLI vs WhatsApp. WhatsApp owns RPC, ledger, pending, and media. |
| **Tools** | UTCP registry plus `core_tools` (workspace files, exec, search, `memory_*`). |
| **Memory** | Daily journals are the trace. `MEMORY.md` is distilled later. Hydrate matches `] (chat_id):`. |
| **Gateway** | Port 18789. Inbound is dispatched off the RPC reader thread. Burst mutex is released during NIM. |

## Systemd Services

Templates live in `systemd/` and `contrib/systemd/` (no secrets). Barvis on this host uses a local user unit: `ExecStart=%h/zeptoclaw/zig-out/bin/zeptoclaw-gateway` with `NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`, and `ZEPTO_NODE` only on that unit.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Gateway on 18789, WhatsApp, in-process 30-min `memory update` child |
| `barvis-memory-update.timer` | Every 2 h: `zeptoclaw memory compact` (`contrib/systemd/`) |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (`contrib/systemd/`) |
| `zeptoclaw-webhook.service` | Port 9000 |
| `zeptoclaw-shell2http.service` | Port 9001 |
| `gateway-watchdog.timer` | Health ping every 2 min |

`systemd/` also has moltbook heartbeat, workspace-sync, and whatsapp-responder. Those are leftover OpenClaw-shaped ops; DMs work without them.

If `systemctl --user restart` hangs, `systemctl --user kill` plus `pkill` on the gateway and `baileys_wrapper`, then `start`.

### Installation

```bash
mkdir -p ~/.config/systemd/user
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
cp contrib/systemd/barvis-memory-update.* contrib/systemd/zeptoclaw-fuzz.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now barvis-memory-update.timer
```

Edit the local gateway unit for keys after copying the template.

### Management

```bash
systemctl --user list-units 'zeptoclaw*' 'gateway*'
systemctl --user list-timers --all
journalctl --user -u zeptoclaw-gateway.service -f
```

## Migration from OpenClaw

Path and config compatibility is `src/openclaw_compat/` ([docs/openclaw-compat.md](docs/openclaw-compat.md)). Copy scripts are in `scripts/migrate/`. Live WhatsApp auth is `~/.zeptoclaw/sessions/whatsapp/` and is not in this repo. Private `barvis` sync copies it into `zeptoclaw-state/`.

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

`src/skills/` was ported from OpenClaw and is invoked with the `skill` tool. WhatsApp reliability does not depend on these modules.

`adhd_workflow`, `discovery`, `dirmacs_docs`, `gateway_watchdog`, `git_workflow`, `github`, `github_stars`, `knowledge_base`, `local_http_services`, `local_llm`, `memory_tree_search`, `moltbook`, `moltbook_heartbeat`, `nufast_physics`, `operational_safety`, `planckeon_sites`, `rust_cargo`, `semantic_search`, `web_qa`, `wsl_troubleshooting`, `zig_dev`.

### WhatsApp Channel

Node `baileys_wrapper.js` writes JSON objects on stdout and QR / session errors on stderr. Zig `WhatsAppChannel` drains stderr so the pipe cannot stall, and ignores non-`{` stdout. Dispatch runs off the reader thread. `sendRequest` is single-flight; `RpcTimeout` (~30s) is a missing send ACK. Node races `socket.sendMessage` against a 20s timer.

Durability is documented in [docs/whatsapp.md](docs/whatsapp.md):

- `inbound-ledger.json`: Baileys ids and fingerprint `chatId|fromMe|body` (3 min skip)
- `pending-turns.jsonl`: enqueue before NIM, ack after send or silent listen/leave, replay on `connected`
- Burst: per-chat buffer while NIM runs; the first reply is the message that started NIM; later lines merge into the follow-up
- Vision: inbound image under `sessions/whatsapp/media/`; later text on that JID reuses `last-image/`
- Access: `dmPolicy=allowlist`. Wake word **barvis** except allowlisted 1:1 and LID self-chat. `leave` unsubscribes until the next barvis

## Cloudflare Worker

A Cloudflare Worker exposes OpenAI-compatible `/v1/chat/completions` with failover. `BARVIS_STATE` and `ZEPTOCLAW_STATE` share one KV namespace id. It is a router, not the local WhatsApp gateway.

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
- `testdata/fuzz/` (redacted seed shapes: dummy `1555555010x`, bodies `x`)
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

There is no npm `openclaw` package. WhatsApp uses Baileys from the Node wrapper.

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

Fuzz corpora (`std.testing.fuzz`) plus `src/fuzz_mutate.zig` cover inbound JSON, journal JID filter, pending jsonl, tool-call hydrate, memory decide parsers, and NIM completion JSON. `zeptoclaw fuzz` is longer havoc without NIM HTTP or a Baileys connect.

## Why "ZeptoClaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto)
- **Claw** = same family as NullClaw, KrillClaw, TinyClaw
- **Z** = Zig

## License

MIT, same as the rest of the Claw family.

---

Commit history: `git log` and [CHANGELOG.md](CHANGELOG.md). History was rewritten once to drop live tokens; clone current `main`.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
