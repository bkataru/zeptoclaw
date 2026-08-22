# ZeptoClaw

> **The world's tiniest AI agent computer.**
>
> Zig 0.16.0 powered, NVIDIA NIM native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis), Baala's Jarvis 🦀⚡

## Build Status

**v0.1.0** (August 22, 2026) — library, CLI, and integration tests green on Zig 0.16.0. The live gateway speaks WhatsApp through a full agent loop, not a one-shot chat call.

## Recent Updates

- **WhatsApp is an agent, not a stub.** Inbound messages run the same turn loop as the CLI: workspace persona, tools, retries, then a reply. Rate limits and timeouts back off and keep going; the turn is not dropped.
- **Memory has a real lifecycle.** Every chat is journaled in full on a daily file. Long-term memory is something the model can read and write with tools, plus two background jobs with different jobs: a frequent ingest of new conversations, and a slower densify of the long-term document.
- **The pipe stays honest.** Replay is identity plus a short fingerprint window, not a mute-after-connect. JSON-only RPC, drained stderr, send ACK timeouts, allowlisted DMs (including self-chat), handler off the reader thread.
- **Home state is `~/.zeptoclaw`.** Workspace, sessions, and config live there. The public repo is code; persona and session snapshots belong in the private Barvis tree.

Zig 0.16.0 landed earlier in 2026 (allocator-aware collections, safer integer casts, startup validation, atomic state writes, health endpoints). That work is assumed, not the headline.

## Project Metrics

| Metric | Value |
|--------|-------|
| **Zig source files** | ~103 |
| **Lines of code** | ~15k in `src/` |
| **Build errors** | 0 |
| **Tests** | 240 (3 skip without `NVIDIA_API_KEY`) |
| **Binaries produced** | 4 |
| **Skills ported** | 21 |

### Binaries

| Binary | Description |
|--------|-------------|
| `zeptoclaw` | CLI, pairing, and memory jobs (`memory update` / `memory compact`) |
| `zeptoclaw-gateway` | HTTP + WhatsApp gateway (port 18789) |
| `zeptoclaw-webhook` | Webhook helper (port 9000) |
| `zeptoclaw-shell2http` | Shell-over-HTTP helper (port 9001) |

## What is this?

ZeptoClaw is a small agent runtime written in Zig. It is purpose-built for Barvis: talk to NVIDIA NIM, keep a workspace of markdown as soul and memory, and meet people on WhatsApp without dragging in a heavier “claw” stack.

**What it tries to be good at:**

- One conversation loop everywhere (CLI and WhatsApp)
- Tools as the way the model touches the world (files, shell, search, skills, memory)
- Never dropping a live chat on a 429 if waiting will do
- Separating *raw traces* from *curated knowledge*
- Keeping secrets and live sessions off the public git history

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.16.0+** — [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API key** — [build.nvidia.com](https://build.nvidia.com/)
- **Node.js 18+** — only for the live WhatsApp transport; set `ZEPTO_NODE` if `node` is not on `PATH`

## Configuration

```bash
export NVIDIA_API_KEY=nvapi-xxx
export NVIDIA_MODEL=thinkingmachines/inkling          # optional
export GATEWAY_AUTH_TOKEN=your_token                  # HTTP gateway
export ZEPTO_NODE=/usr/bin/node                       # if needed
export ZEPTO_CRON_SECS=0                              # 0 = no heartbeat turns on the chat path
export ZEPTO_MEMORY_SECS=1800                         # 30 min journal ingest; 0 disables
```

WhatsApp allowlist lives in OpenClaw-shaped config (`channels.whatsapp.allowFrom`, `dmPolicy`). Keep live keys in systemd or `chmod 600` env files, not in git. Baileys auth is `~/.zeptoclaw/sessions/whatsapp/` (not the public repo). NVIDIA for the 2-hour compact job is `~/.config/zeptoclaw/nim.env`.

## Usage

```bash
zig build
./zig-out/bin/zeptoclaw                 # interactive CLI
./zig-out/bin/zeptoclaw-gateway         # WhatsApp + HTTP
./zig-out/bin/zeptoclaw memory update   # ingest journals → long-term memory (30-min job)
./zig-out/bin/zeptoclaw memory compact  # densify long-term memory (2-hour job)
./zig-out/bin/zeptoclaw whatsapp pair   # QR pair
```

The interactive CLI and WhatsApp inbound share the same idea: load persona from the workspace, let the model call tools until it has something to say, then write the reply. Memory files are **not** stuffed into every prompt; the model asks for them when it wants them.

## Architecture

Think in layers, not a file dump.

**Providers** talk to language models. NVIDIA NIM is the native path: OpenAI-shaped chat, tool rounds, and its own backoff so a rate limit is a wait, not a lost turn.

**The agent loop** is the only place a “turn” happens. A turn is: assemble context, call the model, run tools, maybe call the model again, stop when there is plain language (or the round cap is hit). If the model prints a tool call as chat text, the loop hydrates it and executes rather than leaking JSON to WhatsApp.

**Channels** are how humans arrive. CLI is stdin. WhatsApp is a Zig process that owns a Node Baileys child: JSON on stdout, noise on stderr, one in-flight RPC at a time. A native WhatsApp stack lives in-tree as a compile-only sketch; it is not the live transport.

**Tools and skills** are how the agent acts. Workspace tools read and edit markdown, run commands, search the web, and listen/leave chats. Skills are named capabilities (git, GitHub, Moltbook, safety, and the rest of the OpenClaw port). Memory tools are optional: get, search, append, edit.

**Memory is three tempos:**

1. **Immediate** — every inbound and outbound WhatsApp line is appended, unclipped, to today’s journal (`memory/YYYY-MM-DD.md` in the workspace).
2. **Ingest (every 30 minutes)** — a child process may call the model. If journals did not change, it does nothing. If they did, a short decide turn answers UPDATE or SKIP; only UPDATE synthesizes the long-term file. Isolated from the WhatsApp client’s backoff. If the child fails, a last-resort extractive copy of long outbound lines is the fallback.
3. **Compact (every 2 hours)** — a different job. It does not dump journals. It looks at the long-term document as it already is and densifies it: fold scratch notes into durable sections, merge duplicates, drop pings.

**The gateway** is the long-lived process: HTTP on 18789, WhatsApp connect, dispatch inbound off the reader thread, journal, send, optional compact loop. Config and workspace resolve `~/.zeptoclaw` first, then a read-only OpenClaw leftover.

```
human  →  channel (CLI / WhatsApp)
       →  agent loop (persona + tools + NIM)
       →  reply
              ↘ daily journal (raw)
              ↘ optional memory tools
              ↘ 30-min ingest / 2-hour compact (own processes)
```

## Systemd

Templates in `systemd/` and `contrib/systemd/` have **no secrets**. Put `NVIDIA_API_KEY` and `GATEWAY_AUTH_TOKEN` on the local user unit.

| Unit | Role |
|------|------|
| `zeptoclaw-gateway.service` | Live agent + WhatsApp (port 18789) |
| `barvis-memory-update.timer` | 2-hour **compact** (`zeptoclaw memory compact`) |
| `barvis-sync.timer` | Private workspace git (not in this public tree) |
| `gateway-watchdog.timer` | Optional health poke |
| `zeptoclaw-webhook` / `shell2http` | Optional HTTP helpers |
| `whatsapp-responder.timer` | Legacy fallback; the gateway is the live path |
| `moltbook-heartbeat.timer` | Optional Moltbook ping |

```bash
mkdir -p ~/.config/systemd/user
cp systemd/zeptoclaw-gateway.service ~/.config/systemd/user/
cp contrib/systemd/barvis-memory-update.{service,timer} ~/.config/systemd/user/
# edit Environment= / EnvironmentFile= on the local unit
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now barvis-memory-update.timer
```

If `systemctl --user restart` hangs: kill the gateway and the Baileys child, then start. See [DEPLOYMENT.md](DEPLOYMENT.md).

## Migration from OpenClaw

The Zig runtime is the source of truth. `scripts/migrate/` can copy credentials, sessions, memory, and secrets into `~/.zeptoclaw`. Live Baileys auth for this tree is `~/.zeptoclaw/sessions/whatsapp/`.

```bash
cd scripts/migrate
./migrate-all.sh --dry-run
./migrate-all.sh
```

### Skills

Twenty-one skills from the OpenClaw workspace, including git and GitHub, knowledge base, semantic search, Moltbook, operational safety, and a handful of project-specific ones (physics, sites, Zig, Cargo, WSL). They register as named commands the agent can invoke; they are not a second product.

### WhatsApp channel

A Zig owner process plus a Node Baileys child. Stdout is JSON-RPC only; QR and session errors go to stderr so the pipe cannot fill. Replay remembers message ids and a three-minute same-body fingerprint — there is no “ignore everything for N seconds after connect.” Wake word is **barvis**, except allowlisted DMs and LID self-chat. Groups need the group on the allowlist. `leave` sleeps a chat until the next barvis.

## Cloudflare Worker

An optional edge router: OpenAI-shaped chat, health, failover, heartbeat, incident state in KV. Shared KV so old Barvis bindings and new ZeptoClaw bindings see the same document.

```bash
cd cloudflare-worker
npm install
./deploy.sh
```

See [cloudflare-worker/README.md](cloudflare-worker/README.md). Secrets via `wrangler secret put`, never commits.

| Endpoint | Role |
|----------|------|
| `POST /v1/chat/completions` | Chat |
| `GET /v1/models` | Models |
| `GET /health` | Health |
| `POST /heartbeat` | Local agent heartbeat |
| `GET /state` | State |
| `POST /gateway/incident` | Report |
| `GET /gateway/incidents` | List |

## Development

```bash
zig build
zig build test --summary all
```

- `src/` — runtime
- `vendor/` — zeitgeist, comprezz
- `systemd/` / `contrib/systemd/` — unit templates
- `scripts/migrate/` — OpenClaw → `~/.zeptoclaw`
- `docs/` — [WhatsApp](docs/whatsapp.md), [memory](docs/memory.md), [OpenClaw paths](docs/openclaw-compat.md), runbooks

Public alloc transfers need a greppable `/// Memory:` comment. Do not commit sessions, `.env`, or live tokens.

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [utcp](https://github.com/bkataru/zig-utcp) | Tool-calling protocol |
| [mcp.zig](https://github.com/bkataru/mcp.zig) | Model Context Protocol |
| [raikage](https://github.com/bkataru/raikage) | Encryption |
| [hf-hub-zig](https://github.com/bkataru/hf-hub-zig) | Hugging Face Hub |
| [niza](https://github.com/bkataru/niza) | Utilities |
| [zenmap](https://github.com/bkataru/zenmap) | Data structures |
| [zeitgeist](vendor/zeitgeist) | Time-series memory (vendored) |
| [comprezz](vendor/comprezz) | Compression (vendored) |

## Testing and Verification

```bash
zig build --release=safe
ls -lh zig-out/bin/
curl http://localhost:18789/health
```

A live WhatsApp ping should log inbound, generation, then a sent id — not a send-ACK timeout. Memory jobs log `decision=skip` or `decision=update` / `decision=compact`.

## Why "ZeptoClaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto…) — emphasizing minimalism
- **Claw** = the claw family (NullClaw, KrillClaw, TinyClaw)
- **Z** = like Zig

## License

MIT — same as the rest of the Claw family.

---

**Status:** v0.1.0 — live WhatsApp agent loop and a three-tempo memory system

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
