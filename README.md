# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**v0.1.0** was tagged on 2026-08-22 at Zig 0.16.0. Since then `main` has picked up WhatsApp durability (pending replay, burst coalesce, inbound vision) and parser fuzzing, so the tag is a snapshot of the WhatsApp `runTurn` cutover with journals and the memory jobs. Install current `main` if you want that durability work. Commit history is in [CHANGELOG.md](CHANGELOG.md).

`zig build test` compiles the tree and runs the parser and unit tests. NIM integration tests skip when `NVIDIA_API_KEY` is unset. Zig 0.16.0's `zig build test --fuzz` does not rebuild because the `test_runner` mixes `builtin.StackTrace` with `debug.StackTrace`, so parser havoc runs as `zeptoclaw fuzz [iters]` instead. See [docs/fuzz.md](docs/fuzz.md).

## Recent Updates

WhatsApp inbound is a real turn rather than a one-shot call. The gateway receives JSON from Node, checks access, records the turn as pending in `pending-turns.jsonl`, writes an `[in]` line to today's journal, then runs `Agent.runTurn` with the workspace markdown as the system prompt. After the model returns, it sends the reply, writes the `[out]` line, and acks the pending turn.

Because the RAM session is empty after a restart, the gateway hydrates same-chat lines from today's and yesterday's journals before the turn. If the process was killed while NIM was retrying, the pending rows replay when Baileys reports `connected`. When a chat already has a NIM turn in flight, later messages on that JID buffer (up to 16) and merge into a single follow-up turn, while the first reply still answers whichever message started the turn. Inbound images land under `sessions/whatsapp/media/`, and later text on that same JID attaches the most recent image as an `image_url` data URL (4 MB cap).

Journals keep the full `[in]` and `[out]` text, and a rewrite only rereads up to 8 MiB of the existing daily file. The model can reach them through `memory_get`, `memory_search`, `memory_append`, and `memory_edit`. Every 30 minutes the gateway spawns `zeptoclaw memory update`, which decides whether to update `MEMORY.md` and then synthesizes it. Every 2 hours `zeptoclaw memory compact` densifies `MEMORY.md` without touching the journals. `MEMORY.md` is auto-injected only on Baala `fromMe` DMs.

Replay uses Baileys message ids plus a 3-minute fingerprint of `chatId|fromMe|body`, so connecting never mutes inbound on wall-clock time. `RpcTimeout` (~30s) simply means a send ACK did not arrive. All state lives under `~/.zeptoclaw/{workspace,sessions,config.json}`, and Baileys auth sits in `sessions/whatsapp/`.

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

The loop is NVIDIA NIM (`thinkingmachines/inkling` by default). `chatWithTools` retries forever on RateLimit, Timeout, and Network errors, and fails immediately on auth errors, with tests skipping the sleep. Both the CLI and WhatsApp call `Agent.runTurn`, which allows up to 200 tool rounds. If the model prints `{"name":...}` as chat instead of a tool call, `hydrateToolCallsFromContent` still runs it.

The tool set is `read`, `write`, `edit`, `exec`, `web_search`, `listen`, `leave`, `skill`, and the four `memory_*` tools. `exec` only runs when the command is in `sessions/exec-approvals.txt`, unless `ZEPTO_EXEC_APPROVE=1` makes it unconditional. The live WhatsApp transport is Baileys via `baileys_wrapper.js`, while the whatsmeow-shaped code under `src/channels/whatsapp/native/` compiles and stays unwired. Groups are denied until the group JID is on `allowFrom`. Workspace markdown, which covers `SOUL.md`, identity, journals, and `MEMORY.md`, is the system prompt source. The skills under `src/skills/` are optional through the `skill` tool and do not affect the WhatsApp path. The Cloudflare Worker is a separate OpenAI-compatible router with KV storage and does not replace the gateway.

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** from [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API key** from [build.nvidia.com](https://build.nvidia.com/)
- **Node.js 18+** for the WhatsApp wrapper, and set `ZEPTO_NODE` if `node` is missing from `PATH`. systemd units must set it too.

## Configuration

```bash
export NVIDIA_API_KEY=nvapi-xxx
export NVIDIA_MODEL=thinkingmachines/inkling
export GATEWAY_AUTH_TOKEN=your_token
export ZEPTO_NODE=/usr/bin/node
export ZEPTO_CRON_SECS=0
export ZEPTO_MEMORY_SECS=1800
```

- `ZEPTO_CRON_SECS=0` disables heartbeat turns while chatting.
- `ZEPTO_MEMORY_SECS` controls how often the gateway child runs `memory update`, defaulting to 1800s, and the first ingest waits one full interval after start.
- The WhatsApp allowlist is `channels.whatsapp.allowFrom` and `dmPolicy`.
- Keep secrets on the local systemd unit or in `chmod 600` files such as `~/.config/zeptoclaw/nim.env` for memory oneshots. A missing `GATEWAY_AUTH_TOKEN` fails closed, and `token_auth.zig` tests use placeholders only.

| Path | Meaning |
|------|---------|
| `~/.zeptoclaw/config.json` | Runtime config |
| `~/.zeptoclaw/workspace/` | Soul, skills, `MEMORY.md`, daily journals |
| `~/.zeptoclaw/sessions/whatsapp/` | Baileys auth, inbound ledger, `pending-turns.jsonl`, media |
| `~/.zeptoclaw/sessions/transcripts/` | `Agent` transcripts |

`openclaw_compat` resolves `$HOME/.zeptoclaw` first, then falls back to read-only `~/.openclaw`.

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

`zeptoclaw` with no subcommand reads stdin through the same `runTurn` that WhatsApp uses, so the workspace markdown becomes the system prompt and tools run until the final text.

The WhatsApp path is a fixed sequence: Node emits inbound JSON, Zig checks access and enqueues the pending turn, writes the `[in]` journal line, calls `runTurn`, sends the reply, writes the `[out]` line, and acks the pending turn. Zig appends ⚡ (U+26A1) after the model text through `engagement.appendSignature`, and it tolerates an already-signed reply. The `listen` and `leave` turns send nothing, so those stay unsigned.

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
| **NIMClient** | Sends OpenAI-compatible HTTP to NVIDIA NIM, and attaches a same-JID image as `image_url` when one exists |
| **Agent** | Runs `runTurn`, which walks extra context and tools until final assistant text |
| **Channels** | CLI vs WhatsApp, and WhatsApp owns RPC, ledger, pending, and media |
| **Tools** | UTCP registry plus `core_tools` for workspace files, exec, search, and `memory_*` |
| **Memory** | Journals are the trace, `MEMORY.md` is distilled later, and hydrate filters by `] (chat_id):` |
| **Gateway** | Listens on 18789, dispatches inbound off the RPC reader thread, and releases the burst mutex during NIM |

## Systemd Services

Templates live in `systemd/` and `contrib/systemd/` and carry no secrets. Barvis uses a local user gateway unit that sets `NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`, and `ZEPTO_NODE` on that unit only.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Gateway on 18789 plus WhatsApp and the in-process 30-min `memory update` child |
| `barvis-memory-update.timer` | Every 2 h, `zeptoclaw memory compact` (`contrib/systemd/`) |
| `zeptoclaw-fuzz.timer` | Optional daily parser havoc (`contrib/systemd/`) |
| `zeptoclaw-webhook.service` | Port 9000 |
| `zeptoclaw-shell2http.service` | Port 9001 |
| `gateway-watchdog.timer` | Health ping every 2 min |

`systemd/` also has moltbook heartbeat, workspace-sync, and whatsapp-responder. Those are OpenClaw-era leftovers and the DMs do not need them.

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

Path and config compatibility lives in `src/openclaw_compat/` ([docs/openclaw-compat.md](docs/openclaw-compat.md)), and copy scripts are in `scripts/migrate/`. The live WhatsApp auth is `~/.zeptoclaw/sessions/whatsapp/` and is not in this repo. Private `barvis` sync copies it into `zeptoclaw-state/`.

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

`src/skills/` was ported from OpenClaw and is invoked through the `skill` tool. The names are `adhd_workflow`, `discovery`, `dirmacs_docs`, `gateway_watchdog`, `git_workflow`, `github`, `github_stars`, `knowledge_base`, `local_http_services`, `local_llm`, `memory_tree_search`, `moltbook`, `moltbook_heartbeat`, `nufast_physics`, `operational_safety`, `planckeon_sites`, `rust_cargo`, `semantic_search`, `web_qa`, `wsl_troubleshooting`, and `zig_dev`.

### WhatsApp Channel

The live path is Node `baileys_wrapper.js` talking to Zig `WhatsAppChannel`. Node writes JSON objects on stdout and puts QR and session errors on stderr, while Zig drains stderr so the pipe cannot stall. Dispatch runs off the reader thread, and `sendRequest` is single-flight, with `RpcTimeout` (~30s) meaning the send ACK never came back. Node races `socket.sendMessage` against a 20s timer.

Durability, documented in [docs/whatsapp.md](docs/whatsapp.md):

- `inbound-ledger.json` keeps Baileys ids and the `chatId|fromMe|body` fingerprint for a 3-minute skip.
- `pending-turns.jsonl` is written before NIM, acked after a send or a silent listen/leave, and replayed on `connected`.
- A per-chat burst buffer holds messages that arrive while NIM runs, so the first reply answers the starter and the rest merge into the follow-up.
- Inbound images are saved under `sessions/whatsapp/media/`, and later same-JID text reuses `last-image/`.
- Access is `dmPolicy=allowlist`, the wake word is **barvis** except for allowlisted 1:1 chats and LID self-chat, and `leave` unsubscribes until the next barvis.

## Cloudflare Worker

The Worker exposes OpenAI-compatible `/v1/chat/completions` with failover, and `BARVIS_STATE` and `ZEPTOCLAW_STATE` share one KV namespace id. It is a router only and does not run WhatsApp.

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

The tree is `src/` (106 Zig files, roughly 29k lines), `vendor/` (zeitgeist, comprezz), `systemd/` and `contrib/systemd/`, `scripts/migrate/`, `cloudflare-worker/`, `testdata/fuzz/` (redacted seed shapes with dummy `1555555010x`), and `docs/` (`whatsapp.md`, `memory.md`, `openclaw-compat.md`, `fuzz.md`, runbooks).

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

There is no npm `openclaw` package, and WhatsApp uses Baileys from the Node wrapper.

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

Fuzz coverage comes from `std.testing.fuzz` corpora plus `src/fuzz_mutate.zig`, and the surfaces are inbound JSON (`WhatsAppChannel.parseMessage`, `parseConnectionUpdate`), the journal JID filter (`memory.lineBelongsToChat`), pending jsonl (`pending.loadFrom`), tool-call hydrate (`hydrateToolCallsFromContent`), memory decide (`memory_update` / `memory_compact` `parseDecision`), and NIM completion JSON (`nim.tryParseCompletion`). Do not fuzz `runTurn` or a live Baileys connect.

## Why "ZeptoClaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto)
- **Claw** = same family as NullClaw, KrillClaw, TinyClaw
- **Z** = Zig

## License

MIT, same as the rest of the Claw family.

---

Commit history: `git log` and [CHANGELOG.md](CHANGELOG.md). History was rewritten once to drop live tokens, so clone current `main`.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
