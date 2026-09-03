# Changelog

## 0.3.0 - 2026-09-04

### Tests

- Fixed test discovery for four WhatsApp modules. `root.zig` imported `inbound`, `session`, `outbound`, and `access_control` as single types, and Zig collects no `test` blocks through that form. They are whole-file imports in the test-mode comptime list now. 16 previously silent tests run, including the inbound ledger restart-survival test.
- Added an inbound dedup ledger (`{auth_dir}/gateway-inbound-ledger.json`). The processor records wire ids plus content fingerprints and reloads them after a restart, so an offline-batch redelivery never triggers a second reply.

### Native media decoders

- Fixed `ImageMessage.direct_path`: the decoder read field 10, the wire sends 11. Image downloads lost their path before this fix.
- Rewrote the `StickerMessage` decoder. Every field except `url` was misnumbered or sat behind a wire-type guard that never matches, so no sticker ever decrypted. The decoder now follows the source-verified field table.
- `encodeReceipt` accepts a `t` timestamp. Read receipts need it. The delivery-ack caller passes null.

### NIM reliability

- Raised the NIM timeout default from 30s to 120s. Ultra answers trivial prompts in ~32s, so the old default killed every request just before the answer arrived. The constructors hardcoded 30000 and ignored the config value; they use `cfg.nim_timeout_ms` now, with tests that pin the wiring.
- Raised agent `max_tokens` from 1024 to 4096. Ultra spends most of 1024 tokens on hidden reasoning and returns a stub. Replies use tools and full sentences again.
- Split retries into transient and permanent. `Timeout` / `RateLimit` / `Network` retry forever. Any other error gets 3 tries in `chatUntilDone` and 3 turn retries in the gateway, then the turn answers with a fallback echo. A deterministic 400 no longer wedges the turn for 20 minutes and swallows later wake-ups through coalescing.
- The gateway logs the HTTP status plus the first bytes of NVIDIA's error body on every non-200, plus a per-message shape summary (role, content length, tool-call counts) and the tool-call payloads. The next schema rejection names itself.
- Tool outputs pass through a lossy UTF-8 scrub (invalid bytes become U+FFFD) before they enter history. Raw `ls` bytes from a bad filename used to poison the request JSON and draw a 400 on every later attempt of the turn.
- Hydrated text-emitted tool calls get unique ids (`text-tool-{seq}`). The old constant id collided when one turn hydrated twice.

### Replies

- Burst prompts lead with the newest message and instruct tool use for DO / CHECK / RUN / TELL parts, so a greeting burst no longer swallows an action ask.
- Tests: 441 pass, 3 skip without `NVIDIA_API_KEY`.

## 0.2.0 - 2026-09-03

### WhatsApp

- Added a native WhatsApp client (`src/channels/whatsapp/native/`). It is a full Signal/whatsmeow-style multi-device port: handshake, pairing, the binary wire codec, Curve25519/Ed25519 signing, groups, sender-key encryption, media, QR pairing, and a sqlite device store. Turn it on with `channels.whatsapp.native` (or `ZEPTO_WA_NATIVE=1`). Baileys stays the default.
- Fixed a usync silent-drop. The binary encoder wrote JID-shaped attributes as plain text, not the `JIDPair`/`ADJID` tags the server expects. The server accepted the frame but never answered, so every send timed out with `error.IqTimeout`. usync now resolves in about 300ms.
- Fixed silent delivery drops on 1:1 DMs, including self-chat. WhatsApp now delivers those chats on the recipient's LID, not the phone number. The old envelope got a server ACK, but the LID-keyed device (the phone) dropped it. `sendText` now resolves PN and LID through the stored `lid_map` and sets `peer_recipient_pn` on the envelope.
- Added `zeptoclaw-wa-send <db-path> <to-jid> <text>`. It is a standalone one-shot sender. Use it to force a fresh handshake when a peer device's session goes out of sync.
- The native client now recovers from a `<receipt type=retry>` on its own. `sendText` caches the last 64 outbound DM plaintexts. On a retry, the client drops that device's stale session, fetches a fresh prekey bundle, and resends with the same message id. Automatic resends are capped at 5 per message. Group retries are not covered yet.
- Added `POST /reload`. It re-reads `allowFrom`, `dmPolicy`, and `groupPolicy` from `~/.zeptoclaw/config.json` and applies them without a gateway restart.
- `exec` now runs only on an operator `fromMe` DM. A partner DM cannot run shell commands.
- Baileys reconnects after `connection.close`, with backoff from 2s up to 60s. A `loggedOut` session stays dead until the next QR scan. Pending turns still replay on the following `connected` event.
- Inbound images download to `sessions/whatsapp/media`. The gateway keeps the last image per chat JID and attaches it as NIM vision on later turns in that same chat.
- Burst coalesce: while a chat has a NIM turn in flight, later messages in that chat merge into one follow-up turn. The gateway releases its lock during the NIM call, so a burst does not queue behind a rate-limit sleep.
- Added a pending-inbound queue (`pending-turns.jsonl`). The gateway enqueues an inbound message before NIM and acks it after send or listen. A `SIGKILL` mid-turn no longer drops the message; the gateway replays the queue on the next connect.
- `MEMORY.md` now auto-injects only on an operator `fromMe` DM. A peer's inbound message in that chat does not get it.
- WhatsApp turns hydrate from same-chat journal lines before `runTurn`, on top of the JID isolation from 0.1.0.

### Vision

- `nvidia/nemotron-3-ultra-550b-a55b` is now the primary agent model: fast, tool-capable, text-only. `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` moved to `fallbacks[0]`. A new `see_image` tool dispatches it on demand, since the primary model rejects image input.

### Memory

- Fixed a memory-update child panic. The child now inherits the process env, and `dirExists` no longer panics on a relative path.
- The compact oneshot now runs with `TimeoutStartSec=0`. A slow NIM retry no longer gets `SIGTERM` at 15 minutes.

### Fuzz

- Added `zeptoclaw fuzz [iters]`, a nightly havoc run (50000 iterations by default). It runs property tests for JID isolation and pending-ack state, plus `tryParseCompletion` on NIM output. Seeds live under `testdata/fuzz/`, with secrets redacted. Zig's own `--fuzz` is still broken on 0.16.0.
- Added `std.testing.fuzz` targets for inbound JSON, the journal JID filter, `pending-turns.jsonl`, tool-call hydration, and the memory-decide parser. Run them with `zig build test --fuzz`.

### Ops

- `build.zig.zon` version `0.2.0`. Tests: 419 pass, 3 skip without `NVIDIA_API_KEY`.

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
