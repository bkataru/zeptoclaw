# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

- **v0.1.0** tagged 2026-08-22, Zig 0.16.0. `main` adds WhatsApp durability (pending replay, burst coalesce, inbound vision) and parser fuzzing. History in [CHANGELOG.md](CHANGELOG.md).
- `zig build test` is the compile and parser gate. NIM integration tests skip without `NVIDIA_API_KEY`.
- `zig build test --fuzz` fails to rebuild on 0.16.0 (`test_runner` mixes `builtin.StackTrace` and `debug.StackTrace`). Parser havoc runs as `zeptoclaw fuzz [iters]`. See [docs/fuzz.md](docs/fuzz.md).

## Recent Updates

Live WhatsApp turn:

- inbound JSON from Node
- access check (allowlist, wake word, `fromMe`)
- enqueue pending turn (`pending-turns.jsonl`)
- journal `[in]` to `memory/YYYY-MM-DD.md`
- `Agent.runTurn` (workspace markdown, tools, NIM)
- send reply, journal `[out]`, ack pending

Durability and context:

- same-chat hydrate from today's and yesterday's journals after restart
- pending replay on `connection status=connected` (`skip_journal`)
- burst coalesce: per-chat buffer (cap 16) while NIM is in flight; first reply answers the starter, later lines merge into the follow-up
- inbound images under `sessions/whatsapp/media/`; later text on that JID attaches the last image as a NIM `image_url` data URL (4MB cap)

Memory:

- journals are full `[in]` / `[out]` text (8 MiB rewrite reread cap)
- tools: `memory_get`, `memory_search`, `memory_append`, `memory_edit`
- `zeptoclaw memory update` every 30 min: decide UPDATE/SKIP, then synthesize `MEMORY.md`
- `zeptoclaw memory compact` every 2 h: densify `MEMORY.md`. Does not dump journals
- `MEMORY.md` auto-injected only on Baala `fromMe` DMs

Replay and transport:

- ledger: Baileys id + 3-minute fingerprint `chatId|fromMe|body`
- no wall-clock mute after connect
- `RpcTimeout` (~30s) is a failed send ACK
- state tree: `~/.zeptoclaw/{workspace,sessions,config.json}`; Baileys auth `sessions/whatsapp/`

Details in [docs/whatsapp.md](docs/whatsapp.md) and [docs/memory.md](docs/memory.md).

## Project Metrics

| | |
|--|--|
| Zig files under `src/` | 106 |
| Lines in those files | ~29k |
| Binaries from `zig build` | 4 |
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

- NVIDIA NIM (`thinkingmachines/inkling` default). `chatWithTools` retries forever on RateLimit, Timeout, Network. Auth errors fail immediately (tests skip the sleep).
- CLI and WhatsApp both call `Agent.runTurn`. `max_iters` = 200. Leaked `{"name":...}` chat JSON runs via `hydrateToolCallsFromContent`.
- Tools: `read`, `write`, `edit`, `exec`, `web_search`, `listen`, `leave`, `skill`, `memory_get`, `memory_search`, `memory_append`, `memory_edit`.
- `exec` runs only on approval in `sessions/exec-approvals.txt`, or unconditionally when `ZEPTO_EXEC_APPROVE=1`.
- Live WhatsApp transport is Baileys (`baileys_wrapper.js`). `src/channels/whatsapp/native/` (whatsmeow-shaped) compiles and is unwired.
- Groups stay deny until the group JID is on `allowFrom`.
- Workspace markdown (`SOUL.md`, identity, journals, `MEMORY.md`) is the system prompt source.
- `src/skills/` is optional (`skill` tool), independent of the WhatsApp path.
- Cloudflare Worker: OpenAI-compatible router + KV. Separate from `zeptoclaw-gateway`.

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** from [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API key** from [build.nvidia.com](https://build.nvidia.com/)
- **Node.js 18+** for the WhatsApp wrapper. Set `ZEPTO_NODE` if `node` is missing from `PATH`. systemd units must set it too.

## Configuration

```bash
export NVIDIA_API_KEY=nvapi-xxx
export NVIDIA_MODEL=thinkingmachines/inkling
export GATEWAY_AUTH_TOKEN=your_token
export ZEPTO_NODE=/usr/bin/node
export ZEPTO_CRON_SECS=0
export ZEPTO_MEMORY_SECS=1800
```

- `ZEPTO_CRON_SECS=0`: disable heartbeat turns while chatting.
- `ZEPTO_MEMORY_SECS`: gateway child `memory update` interval. Default 1800s. First ingest waits one full interval after start.
- WhatsApp allowlist: `channels.whatsapp.allowFrom`, `dmPolicy`.
- Secrets on the local systemd unit, or in `chmod 600` files (`~/.config/zeptoclaw/nim.env` for memory oneshots). Missing `GATEWAY_AUTH_TOKEN` fails closed. `token_auth.zig` tests use placeholders only.

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

`zeptoclaw` with no subcommand reads stdin through the same `runTurn` as WhatsApp: workspace markdown as the system prompt, tools until final text.

WhatsApp path detail:

- inbound JSON from Node
- access check, enqueue pending
- journal `[in]`, `runTurn`, send, journal `[out]`, ack pending
- Zig appends ⚡ (U+26A1) after the model text (`engagement.appendSignature`). Idempotent.
- `listen` and `leave` send nothing. Those turns stay unsigned.

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

| Component | Contract |
|-----------|----------|
| **NIMClient** | OpenAI-compatible HTTP to NVIDIA NIM. Multimodal `image_url` when a same-JID image exists |
| **Agent** | `runTurn`: extra context + tools until final assistant text |
| **Channels** | CLI vs WhatsApp. WhatsApp owns RPC, ledger, pending, media |
| **Tools** | UTCP registry + `core_tools` (workspace, exec, search, `memory_*`) |
| **Memory** | Journals are the trace. `MEMORY.md` distilled later. Hydrate filters by `] (chat_id):` |
| **Gateway** | Port 18789. Inbound off the RPC reader thread. Burst mutex released during NIM |

## Systemd Services

Templates in `systemd/` and `contrib/systemd/`. No secrets in the templates. Barvis uses a local user gateway unit with `NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`, `ZEPTO_NODE` on that unit only.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Gateway on 18789, WhatsApp, in-process 30-min `memory update` child |
| `barvis-memory-update.timer` | Every 2 h: `zeptoclaw memory compact` (`contrib/systemd/`) |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (`contrib/systemd/`) |
| `zeptoclaw-webhook.service` | Port 9000 |
| `zeptoclaw-shell2http.service` | Port 9001 |
| `gateway-watchdog.timer` | Health ping every 2 min |

`systemd/` also has moltbook heartbeat, workspace-sync, and whatsapp-responder. Those are OpenClaw-era ops; DMs do not need them.

If `systemctl --user restart` hangs: `systemctl --user kill`, `pkill` the gateway and `baileys_wrapper`, then `start`.

### Installation

```bash
mkdir -p ~/.config/systemd/user
cp systemd/*.service systemd/*.timer ~/.config/systemd/user/
cp contrib/systemd/barvis-memory-update.* contrib/systemd/zeptoclaw-fuzz.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now barvis-memory-update.timer
```

Edit the local gateway unit for keys after copying.

### Management

```bash
systemctl --user list-units 'zeptoclaw*' 'gateway*'
systemctl --user list-timers --all
journalctl --user -u zeptoclaw-gateway.service -f
```

## Migration from OpenClaw

Path and config compatibility is `src/openclaw_compat/` ([docs/openclaw-compat.md](docs/openclaw-compat.md)). Copy scripts in `scripts/migrate/`. Live WhatsApp auth is `~/.zeptoclaw/sessions/whatsapp/`, not in this repo. Private `barvis` sync copies it into `zeptoclaw-state/`.

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

`src/skills/` ported from OpenClaw, invoked via the `skill` tool. Names: `adhd_workflow`, `discovery`, `dirmacs_docs`, `gateway_watchdog`, `git_workflow`, `github`, `github_stars`, `knowledge_base`, `local_http_services`, `local_llm`, `memory_tree_search`, `moltbook`, `moltbook_heartbeat`, `nufast_physics`, `operational_safety`, `planckeon_sites`, `rust_cargo`, `semantic_search`, `web_qa`, `wsl_troubleshooting`, `zig_dev`.

### WhatsApp Channel

Live: Node `baileys_wrapper.js` (JSON objects on stdout, QR and session errors on stderr) + Zig `WhatsAppChannel`. Stderr is drained so the pipe cannot stall. Dispatch is off the reader thread. `sendRequest` is single-flight; `RpcTimeout` (~30s) is a missing send ACK. Node races `socket.sendMessage` against a 20s timer.

Durability ([docs/whatsapp.md](docs/whatsapp.md)):

- `inbound-ledger.json`: Baileys ids + fingerprint `chatId|fromMe|body` (3 min skip)
- `pending-turns.jsonl`: enqueue before NIM, ack after send or silent listen/leave, replay on `connected`
- burst: per-chat buffer while NIM runs; first reply is the starter; later lines merge into the follow-up
- vision: inbound image under `sessions/whatsapp/media/`; later same-JID text reuses `last-image/`
- access: `dmPolicy=allowlist`. Wake word **barvis** except allowlisted 1:1 and LID self-chat. `leave` unsubscribes until the next barvis

## Cloudflare Worker

OpenAI-compatible `/v1/chat/completions` with failover. `BARVIS_STATE` and `ZEPTOCLAW_STATE` share one KV namespace id. Router only; does not run WhatsApp.

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
- `testdata/fuzz/` (redacted seed shapes, dummy `1555555010x`)
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

No npm `openclaw` package. WhatsApp uses Baileys from the Node wrapper.

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

Fuzz surfaces (`std.testing.fuzz` corpora + `src/fuzz_mutate.zig`):

- inbound JSON (`WhatsAppChannel.parseMessage`, `parseConnectionUpdate`)
- journal JID filter (`memory.lineBelongsToChat`)
- pending jsonl (`pending.loadFrom`)
- tool-call hydrate (`hydrateToolCallsFromContent`)
- memory decide (`memory_update` / `memory_compact` `parseDecision`)
- NIM completion JSON (`nim.tryParseCompletion`)

Do not fuzz `runTurn` or a live Baileys connect.

## Why "ZeptoClaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto)
- **Claw** = same family as NullClaw, KrillClaw, TinyClaw
- **Z** = Zig

## License

MIT, same as the rest of the Claw family.

---

Commit history: `git log` and [CHANGELOG.md](CHANGELOG.md). History was rewritten once to drop live tokens; clone current `main`.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
