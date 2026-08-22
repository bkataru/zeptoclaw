# WhatsApp channel

Live path: Zig `WhatsAppChannel` spawns Node `src/channels/whatsapp/baileys_wrapper.js` (Baileys 6.x). Auth: `sessions/whatsapp/` (gitignored in **this** repo). The private `bkataru/barvis` backup copies that dir plus transcripts into `zeptoclaw-state/` every 30 minutes via `barvis-sync`.

## RPC

Zig writes JSON-RPC lines on Node stdin (`sendMessage`, `onMessage`, …). Node writes **JSON objects only** on stdout. Non-`{` lines are ignored. QR and session errors go to stderr; Zig drains stderr so the pipe cannot stall.

`sendRequest` is single-flight: wait for a matching `id` (number **or** string) or `RpcTimeout` (~30s). Node races `socket.sendMessage` against a 20s timer so Zig is not left silent. The WhatsApp **reader thread must not** run `sendMessage`; inbound is dispatched on a worker thread.

## Replay

`sessions/whatsapp/inbound-ledger.json`:

- Baileys message ids in `seen` / `sent`
- Fingerprint `chatId|fromMe|collapsed-body` with a **3 minute** skip window in `isReplay`

There is no “mute fromMe for N seconds after connect.” First deploy with an empty ledger can process history once; those ids then persist.

## Access

Config `dmPolicy=allowlist` + `allowFrom` E.164 list. LID self-chat (`…@lid`) is treated as Message-yourself. `fromMe` in an allowlisted 1:1 is inbound from the operator. Groups need the group JID on the allowlist and a **barvis** mention (or equivalent policy). `leave` unsubscribes a chat until the next **barvis**.

## Native port

`src/channels/whatsapp/native/` is a whatsmeow-inspired Zig stub. It compiles; it is not wired as the gateway transport.