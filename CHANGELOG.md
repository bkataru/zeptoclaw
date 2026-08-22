# Changelog

## 0.1.0 — 2026-08-22

First tagged release of the live Barvis path.

### Agent

- WhatsApp inbound runs the same tool loop as the CLI (persona markdown, tools, then a reply).
- NVIDIA rate limits, timeouts, and empty-network failures retry with backoff; turns are not dropped.
- Leaked tool JSON in assistant text is hydrated and executed. Tool rounds cap at 200.

### Memory

- Daily journals use a real IST calendar (`memory/YYYY-MM-DD.md`). Inbound and outbound text is stored in full (no 2000-character clip).
- The model has optional memory tools (get, search, append, edit). Long-term markdown is not auto-injected into every turn.
- Every 30 minutes: `zeptoclaw memory update` in a child process — skip if journals did not change, otherwise decide UPDATE/SKIP, then synthesize.
- Every 2 hours: `zeptoclaw memory compact` — densify the long-term file; does not dump raw journals.

### WhatsApp

- Replay ledger: message id plus a short same-body fingerprint. No wall-clock mute after connect.
- JSON-only RPC, stderr drain, send ACK timeout, handler off the reader thread.
- Allowlisted DMs and LID self-chat; groups still need the group on the allowlist.

### Ops

- Canonical live state: `~/.zeptoclaw/{workspace,sessions,config.json}`.
- Gateway port 18789. Secrets stay in systemd / env files, not git.

## 0.0.0

Unreleased Zig 0.16.0 port and OpenClaw skill migration.
