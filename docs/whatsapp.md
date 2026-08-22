# WhatsApp channel

Live path: Zig owns a Node Baileys child (`src/channels/whatsapp/baileys_wrapper.js`, Baileys 6.x). Auth: `~/.zeptoclaw/sessions/whatsapp/` (not in the public repo). `barvis-sync` copies it plus transcripts into private `bkataru/barvis` `zeptoclaw-state/`.

Inbound messages run the **agent loop** (persona, tools, retries, reply), then journal `[in]`/`[out]` to the daily file. See [memory.md](memory.md).

## RPC

Zig writes JSON-RPC lines on Node stdin. Node writes **JSON objects only** on stdout. Non-`{` lines are ignored. QR and session errors go to stderr; Zig drains stderr so the pipe cannot stall.

Send is single-flight: wait for a matching id (number **or** string) or a send-ACK timeout (~30s). Node races the socket send against a 20s timer so Zig is not left silent. The WhatsApp **reader thread must not** send; inbound is dispatched on a worker thread.

## Replay

`sessions/whatsapp/inbound-ledger.json` (live: under `~/.zeptoclaw`):

- Baileys message ids in `seen` / `sent`
- Fingerprint `chatId|fromMe|collapsed-body` with a **3 minute** skip window

There is no “mute fromMe for N seconds after connect.” First deploy with an empty ledger can process history once; those ids then persist.

## Access

Config `dmPolicy=allowlist` + `allowFrom` E.164 list. LID self-chat is treated as Message-yourself. `fromMe` in an allowlisted 1:1 is inbound from the operator. Groups need the group JID on the allowlist and a **barvis** mention (or equivalent policy). `leave` unsubscribes a chat until the next **barvis**.

## Native port

`src/channels/whatsapp/native/` is a whatsmeow-inspired Zig stub. It compiles; it is not wired as the gateway transport.
