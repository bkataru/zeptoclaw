# ZeptoClaw

Zig 0.16 agent runtime for **Barvis**. NVIDIA NIM (`thinkingmachines/inkling`) plus a WhatsApp channel (Baileys) and an HTTP gateway.

This is not a one-shot chat wrapper. Inbound WhatsApp turns run `Agent.runTurn`: workspace markdown as the system prompt, registered tools (`read` / `write` / `edit` / `exec` / `web_search` / `listen` / `leave` / `skill`), then a NIM tool loop until final text.

## Requirements

- [Zig 0.16.0](https://ziglang.org/download/)
- Node.js 18+ (WhatsApp wrapper; pin with `ZEPTO_NODE` if `node` is not on `PATH`)
- `NVIDIA_API_KEY` for chat
- Optional: `GATEWAY_AUTH_TOKEN` (or config `gateway.auth.token`)

## Build

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
zig build test --summary all
```

Binaries land in `zig-out/bin/`:

| Binary | Role |
|--------|------|
| `zeptoclaw` | CLI agent |
| `zeptoclaw-gateway` | HTTP + WhatsApp (default port **18789**) |
| `zeptoclaw-webhook` | Webhooks (port **9000**) |
| `zeptoclaw-shell2http` | Shell2HTTP (port **9001**) |

## Run the gateway

```bash
export NVIDIA_API_KEY=nvapi-...
export NVIDIA_MODEL=thinkingmachines/inkling   # optional
export GATEWAY_AUTH_TOKEN=                       # optional; config can supply
export ZEPTO_NODE=/usr/bin/node                  # if needed
export ZEPTO_CRON_SECS=0                         # 0 disables heartbeat cron
./zig-out/bin/zeptoclaw-gateway
```

User systemd unit (repo template has no secrets):

```ini
# ~/.config/systemd/user/zeptoclaw-gateway.service
[Service]
Environment=NVIDIA_API_KEY=...
Environment=GATEWAY_AUTH_TOKEN=...
Environment=PATH=...   # include node + zig
ExecStart=%h/zeptoclaw/zig-out/bin/zeptoclaw-gateway
```

```powershell
# logs on the host that runs systemd --user
journalctl --user -u zeptoclaw-gateway.service -f
```

Health: `GET http://127.0.0.1:18789/health` with the gateway token.

## WhatsApp

The gateway spawns `src/channels/whatsapp/baileys_wrapper.js`. Auth lives under `sessions/whatsapp/` (gitignored). Allowlist and DM policy come from OpenClaw-compatible config (`channels.whatsapp.allowFrom`, `dmPolicy`).

Behavior that matters in production:

- Wake word is **barvis** (case-insensitive) except allowlisted DMs / LID self-chat.
- Replay suppression is **message id + fingerprint** (`chatId|fromMe|body`), not a wall-clock mute after connect. Same body in the same chat within **3 minutes** is treated as replay even with a new id.
- JSON-RPC on stdout only; QR and Baileys noise go to stderr.
- `sendMessage` is ACK’d with a timeout; Zig does not wait on the reader thread for that ACK.

A pure Zig whatsmeow port lives under `src/channels/whatsapp/native/` and is **not** the live path yet.

## Agent loop

`src/agent/loop.zig` `runTurn`:

1. System prompt from workspace files: `SOUL.md`, `USER.md`, `AGENTS.md`, `IDENTITY.md`, `MEMORY.md` (DM-only), `TOOLS.md` (32 KiB each).
2. NIM `chatWithTools` with core tool schemas.
3. Execute tools in the workspace cwd; loop until the model returns text (or `listen` / `leave`).
4. Transcripts under `sessions/transcripts/` (gitignored).

`exec` requires `ZEPTO_EXEC_APPROVE=1` or an exact line in `sessions/exec-approvals.txt`. Read-only commands (`ls`, `git status`, …) are allowlisted.

## Layout

```
src/
  agent/           runTurn, tools, transcripts, cron
  channels/        CLI + WhatsApp (Baileys + native stubs)
  gateway/         HTTP server, token auth, WhatsApp dispatch
  providers/       NIM client, pools, fallback
  skills/          21 OpenClaw-ported skills (Zig)
  openclaw_compat/ config/workspace path bridge
  autonomous/      moltbook / state store
skills/            markdown skill briefs (OpenClaw layout)
docs/              runbooks
systemd/           user unit templates (no secrets)
cloudflare-worker/ backup router
```

## Docs

- [Deployment](DEPLOYMENT.md)
- [Contributing](CONTRIBUTING.md)
- [OpenClaw compatibility](docs/openclaw-compat.md)
- [WhatsApp channel](docs/whatsapp.md)
- [Runbooks](docs/runbooks/troubleshooting.md)

## License

See [LICENSE](LICENSE).
