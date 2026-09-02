# WhatsApp channel

Live path: Zig `WhatsAppChannel` spawns Node `src/channels/whatsapp/baileys_wrapper.js` (Baileys 6.x). Auth: `~/.zeptoclaw/sessions/whatsapp/` (not in the public repo). `barvis-sync` copies it plus transcripts into private `bkataru/barvis` `zeptoclaw-state/`.

Inbound runs `Agent.runTurn` (workspace markdown, tools, NIM retries, reply). Then `journal_append` `[in]`/`[out]` to `memory/YYYY-MM-DD.md`. See `memory.md`.

## Reconnect

On `connection.close`, Node rebuilds the Baileys socket with exponential backoff (2s, cap 60s) unless `DisconnectReason.loggedOut` (needs a new QR). `disconnect` / SIGTERM set `shuttingDown` so close does not reconnect. Zig still sees `disconnected` then `connected`; pending-turns replay on `connected`.

## RPC

Zig writes JSON-RPC lines on Node stdin (`sendMessage`, `onMessage`, ...). Node writes JSON objects only on stdout. Non-`{` lines are ignored. QR and session errors go to stderr; Zig drains stderr so the pipe cannot stall.

`sendRequest` is single-flight: wait for a matching `id` (number or string) or `RpcTimeout` (~30s). Node races `socket.sendMessage` against a 20s timer so Zig is not left silent. The WhatsApp reader thread must not run `sendMessage`; inbound is dispatched on a worker thread.

## Replay

`~/.zeptoclaw/sessions/whatsapp/inbound-ledger.json`:

- Baileys message ids in `seen` / `sent`
- Fingerprint `chatId|fromMe|collapsed-body` with a 3 minute skip window in `isReplay`

There is no mute-fromMe-for-N-seconds-after-connect. First deploy with an empty ledger can process history once; those ids then persist.

## Access

Config `dmPolicy=allowlist` + `allowFrom` E.164 list. LID self-chat (`...@lid`) is treated as Message-yourself. `fromMe` in an allowlisted 1:1 is inbound from the operator. Groups need the group JID on the allowlist and a **barvis** mention (or equivalent policy). `leave` unsubscribes a chat until the next **barvis**.

## Native (no Node) mode

Set `channels.whatsapp.native` to `true` in `~/.zeptoclaw/config.json` (or `ZEPTO_WA_NATIVE=1`). The gateway then runs the Zig client instead of spawning the Node/Baileys child.

Pair with `zeptoclaw whatsapp pair` — native mode prints a terminal QR (half-block glyphs) plus the raw pairing URL. Identity is stored at `{auth_dir}/native.sqlite` (default `~/.zeptoclaw/sessions/whatsapp/native.sqlite`). Do not delete that file (or Baileys `creds.json`) to unpair.

Current limits: text DMs. Groups and media are pending.

## Signature

Outbound text is signed in Zig (`engagement.appendSignature`) with a space and ⚡ (U+26A1). The model is told not to add it. Silent `listen`/`leave` turns send nothing, so they stay unsigned.

Language rules live in `engagement.LANGUAGE_INSTRUCTIONS` (WhatsApp extra context) and `SOUL.md` (workspace system prompt).

## History after restart

RAM `WhatsAppSession` history is empty after `kill`/`start`. DMs (and groups) get same-chat lines from `memory/YYYY-MM-DD.md` via `dailyContext` before `runTurn`. That is how a later `hi barvis, i like her top` can see `i like ur top` from the same JID without loading other chats.

## Unacked turns

Before NIM, the gateway appends the inbound to `~/.zeptoclaw/sessions/whatsapp/pending-turns.jsonl` (Baileys id, chat JID, body, fromMe). After a successful send or silent listen/leave, that id is removed. On `connection status=connected`, remaining rows are replayed (`skip_journal`) so a SIGKILL mid-retry does not drop the turn.

## MEMORY.md in partner DMs

Injected only when `fromMe=true` (Baala). Peer inbound in that DM does not get `MEMORY.md` auto-injected. Same-chat journal still hydrates both directions.

## Burst coalesce

Inbound is journaled immediately. If that chat already has a NIM turn in flight, extra bodies go into a per-chat buffer (cap 16). After send or listen, those lines become one follow-up turn (`mergeBurstPrompt`). The mutex is not held during NIM, so a burst is not stuck behind RateLimit sleep.

Same-chat journal is keyed by WhatsApp JID (the thread), not by sender. That is the right isolation: both people in a DM share one history. Other JIDs and `MEMORY.md` stay out unless Baala `fromMe` in that DM.

## Inbound images

Baileys downloads inbound `imageMessage` to `~/.zeptoclaw/sessions/whatsapp/media/` and records the last path per chat JID under `last-image/`. Zig attaches that file as a NIM `image_url` data URL on:

- the image turn itself
- later text in the **same** DM (so "i like her top" can see the photo)

Other chats never get that file. Videos/audio are not vision-attached. Max 4MB.
