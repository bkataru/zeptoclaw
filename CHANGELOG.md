# Changelog

## Unreleased

- Burst coalesce: while NIM is in flight for a chat, later messages in that JID merge into one follow-up turn. Mutex released during NIM.


- Pending inbound queue: `pending-turns.jsonl`. Enqueue before NIM, ack after send or listen. Replay on WhatsApp connect after SIGKILL.
- `MEMORY.md` auto-injected only on Baala `fromMe` DMs. Peer inbound in that chat does not get it.
- Same-chat journal hydrate (already in 0.1.0 follow-ups).

## 0.1.0 - 2026-08-22

Tagged release of the live Barvis path.

### Agent

- WhatsApp inbound uses `Agent.runTurn` (workspace markdown, tools, NIM), not one-shot `NIMClient.chat`.
- `chatWithTools` retries forever on `RateLimit` / `Timeout` / `Network`. Auth errors fail immediately. Tests skip sleep.
- `hydrateToolCallsFromContent` runs tool JSON that the model printed as chat. `TurnOpts.max_iters` = 200.

### Memory

- `memory.journalAppend` writes IST `memory/YYYY-MM-DD.md` (`[in]`/`[out]`, full text).
- Tools: `memory_get`, `memory_search`, `memory_append`, `memory_edit`. No auto-inject of `MEMORY.md` into every turn.
- `zeptoclaw memory update` (gateway child, `ZEPTO_MEMORY_SECS=1800`): skip if journals unchanged; else decide UPDATE/SKIP; then synthesize.
- `zeptoclaw memory compact` (`barvis-memory-update.timer`, 2 h): densify `MEMORY.md`. Does not dump journals.

### WhatsApp

- Replay: Baileys id + 3-minute body fingerprint. No `connectedAtMs` mute.
- JSON-only RPC stdout, stderr drain, `RpcTimeout` on send ACK, handler off the reader thread.
- Allowlisted DMs and LID self-chat; groups need the group JID in `allowFrom`.

### Ops

- Live state: `~/.zeptoclaw/{workspace,sessions,config.json}`.
- Gateway port 18789. Secrets in systemd / `nim.env`, not git.
- `build.zig.zon` version `0.1.0`. Tests: 240.

## 0.0.0

Unreleased Zig 0.16.0 port and OpenClaw skill migration.
