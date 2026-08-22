# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**v0.1.0** was tagged on 2026-08-22 at Zig 0.16.0. That tag covers the WhatsApp `runTurn` cutover, daily journals, and the memory jobs.

`main` has since added pending-turn replay, burst coalesce, inbound vision, and parser fuzzing. Install current `main` if you want that work. History is in [CHANGELOG.md](CHANGELOG.md).

`zig build test` compiles the tree and runs parser and unit tests. NIM integration tests skip when `NVIDIA_API_KEY` is unset.

Zig 0.16.0's `zig build test --fuzz` does not rebuild. The `test_runner` mixes `builtin.StackTrace` with `debug.StackTrace`. Parser havoc runs as `zeptoclaw fuzz [iters]`. See [docs/fuzz.md](docs/fuzz.md).

## Recent Updates

The gateway receives inbound JSON from Node, checks access, and records the turn in `pending-turns.jsonl`. It writes an `[in]` line to today's journal, then calls `Agent.runTurn` with workspace markdown as the system prompt.

After the model returns, it sends the reply, writes the `[out]` line, and acks the pending turn.

The RAM session is empty after a restart. The gateway therefore loads same-chat lines from today's and yesterday's journals before the turn.

If the process died while NIM was retrying, leftover pending rows replay when Baileys reports `connected`.

When a chat already has a NIM turn in flight, later messages on that JID buffer up to 16 and merge into one follow-up. The first reply still answers the message that started NIM.

Inbound images are stored under `sessions/whatsapp/media/`. Later text on the same JID attaches the last image as an `image_url` data URL, up to 4 MB.

Journals keep the full `[in]` and `[out]` text. A rewrite rereads at most 8 MiB of the existing daily file.

The model reaches those files through `memory_get`, `memory_search`, `memory_append`, and `memory_edit`.

Every 30 minutes the gateway spawns `zeptoclaw memory update`. That child decides UPDATE or SKIP, then writes `MEMORY.md`.

Every 2 hours `zeptoclaw memory compact` shortens `MEMORY.md`. It does not dump journals. `MEMORY.md` is auto-injected only on Baala `fromMe` DMs.

Replay uses Baileys message ids plus a 3-minute fingerprint of `chatId|fromMe|body`. Connecting does not mute inbound by wall-clock time.

`RpcTimeout` (~30s) means a send ACK did not arrive. State lives under `~/.zeptoclaw/{workspace,sessions,config.json}`. Baileys auth is `sessions/whatsapp/`.

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

The loop is NVIDIA NIM (`thinkingmachines/inkling` by default). `chatWithTools` retries forever on RateLimit, Timeout, and Network errors. Auth errors fail immediately, and tests skip the sleep.

CLI and WhatsApp both call `Agent.runTurn`. Tool rounds cap at 200. If the model prints `{"name":...}` as chat, `hydrateToolCallsFromContent` still runs it.

Tools are `read`, `write`, `edit`, `exec`, `web_search`, `listen`, `leave`, `skill`, and the four `memory_*` tools. `exec` runs only when the command is listed in `sessions/exec-approvals.txt`, unless `ZEPTO_EXEC_APPROVE=1`.

Live WhatsApp transport is Baileys via `baileys_wrapper.js`. The whatsmeow-shaped code under `src/channels/whatsapp/native/` compiles and stays unwired. Groups stay denied until the group JID is on `allowFrom`.

Workspace markdown (`SOUL.md`, identity, journals, `MEMORY.md`) is the system prompt. Skills under `src/skills/` are optional through the `skill` tool. They do not sit on the WhatsApp path.

The Cloudflare Worker is an OpenAI-compatible HTTP router with KV storage. It does not replace `zeptoclaw-gateway`.

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

`ZEPTO_CRON_SECS=0` disables heartbeat turns while chatting.

`ZEPTO_MEMORY_SECS` is how often the gateway child runs `memory update`. The default is 1800s. The first ingest waits one full interval after start.

The WhatsApp allowlist is `channels.whatsapp.allowFrom` and `dmPolicy`.

Put secrets on the local systemd unit, or in `chmod 600` files such as `~/.config/zeptoclaw/nim.env` for memory oneshots. A missing `GATEWAY_AUTH_TOKEN` fails closed. `token_auth.zig` tests use placeholders only.

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

`zeptoclaw` with no subcommand reads stdin through the same `runTurn` as WhatsApp. Workspace markdown is the system prompt. Tools run until the final text.

On WhatsApp, Node emits inbound JSON. Zig checks access, enqueues the pending turn, journals `[in]`, calls `runTurn`, sends, journals `[out]`, and acks pending.

Zig appends ⚡ (U+26A1) after the model text through `engagement.appendSignature`. It skips the mark if the text already has it. `listen` and `leave` send nothing, so those turns stay unsigned.

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
| **NIMClient** | OpenAI-compatible HTTP to NVIDIA NIM. Same-JID images go out as `image_url` |
| **Agent** | `runTurn` walks extra context and tools until final assistant text |
| **Channels** | CLI vs WhatsApp. WhatsApp owns RPC, ledger, pending, and media |
| **Tools** | UTCP registry plus `core_tools` for workspace files, exec, search, and `memory_*` |
| **Memory** | Journals are the trace. `MEMORY.md` is written later. Hydrate filters by `] (chat_id):` |
| **Gateway** | Port 18789. Inbound is dispatched off the RPC reader thread. Burst mutex is released during NIM |

## Systemd Services

Templates live in `systemd/` and `contrib/systemd/`. They contain no secrets.

Barvis uses a local user gateway unit. `NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`, and `ZEPTO_NODE` sit on that unit only.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Gateway on 18789, WhatsApp, and the in-process 30-min `memory update` child |
| `barvis-memory-update.timer` | Every 2 h, `zeptoclaw memory compact` (`contrib/systemd/`) |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (`contrib/systemd/`) |
| `zeptoclaw-webhook.service` | Port 9000 |
| `zeptoclaw-shell2http.service` | Port 9001 |
| `gateway-watchdog.timer` | Health ping every 2 min |

`systemd/` also has moltbook heartbeat, workspace-sync, and whatsapp-responder. Those are leftover OpenClaw-era units. DMs do not need them.

If `systemctl --user restart` hangs, run `systemctl --user kill`, `pkill` the gateway and `baileys_wrapper`, then `start`.

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

Path and config compatibility is `src/openclaw_compat/` ([docs/openclaw-compat.md](docs/openclaw-compat.md)). Copy scripts are in `scripts/migrate/`.

Live WhatsApp auth is `~/.zeptoclaw/sessions/whatsapp/` and is not in this repo. Private `barvis` sync copies it into `zeptoclaw-state/`.

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

`src/skills/` was ported from OpenClaw. The `skill` tool invokes them.

Names: `adhd_workflow`, `discovery`, `dirmacs_docs`, `gateway_watchdog`, `git_workflow`, `github`, `github_stars`, `knowledge_base`, `local_http_services`, `local_llm`, `memory_tree_search`, `moltbook`, `moltbook_heartbeat`, `nufast_physics`, `operational_safety`, `planckeon_sites`, `rust_cargo`, `semantic_search`, `web_qa`, `wsl_troubleshooting`, `zig_dev`.

### WhatsApp Channel

The live path is Node `baileys_wrapper.js` talking to Zig `WhatsAppChannel`. Node writes JSON objects on stdout and puts QR and session errors on stderr. Zig drains stderr so the pipe cannot stall.

Dispatch runs off the reader thread. `sendRequest` is single-flight. `RpcTimeout` (~30s) means the send ACK never came back. Node races `socket.sendMessage` against a 20s timer.

Durability is documented in [docs/whatsapp.md](docs/whatsapp.md):

- `inbound-ledger.json` stores Baileys ids and the `chatId|fromMe|body` fingerprint for a 3-minute skip.
- `pending-turns.jsonl` is written before NIM, acked after a send or a silent listen/leave, and replayed on `connected`.
- A per-chat burst buffer holds messages that arrive while NIM runs. The first reply answers the starter. The rest merge into the follow-up.
- Inbound images are saved under `sessions/whatsapp/media/`. Later same-JID text reuses `last-image/`.
- Access is `dmPolicy=allowlist`. The wake word is **barvis** except for allowlisted 1:1 chats and LID self-chat. `leave` unsubscribes until the next barvis.

## Cloudflare Worker

The Worker exposes OpenAI-compatible `/v1/chat/completions` with failover. `BARVIS_STATE` and `ZEPTOCLAW_STATE` share one KV namespace id.

It is a router. It does not run WhatsApp.

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

There is no npm `openclaw` package. WhatsApp uses Baileys from the Node wrapper.

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

Fuzz coverage comes from `std.testing.fuzz` corpora plus `src/fuzz_mutate.zig`.

Surfaces:

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

Commit history: `git log` and [CHANGELOG.md](CHANGELOG.md). History was rewritten once to drop live tokens. Clone current `main`.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
