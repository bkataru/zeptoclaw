# WhatsApp channel

Live path: Zig `WhatsAppChannel` runs the native multi-device client in `native/`. Auth: `~/.zeptoclaw/sessions/whatsapp/native.sqlite` (not in the public repo). `barvis-sync` copies it plus transcripts into private `bkataru/barvis` `zeptoclaw-state/`.

Inbound runs `Agent.runTurn` (workspace markdown, tools, NIM retries, reply). Then `journal_append` `[in]`/`[out]` to `memory/YYYY-MM-DD.md`. See `memory.md`.

## Reconnect

On disconnect, the native client reconnects with exponential backoff (2s, cap 60s) unless the session is logged out (needs a new QR). Pending-turns replay on the next `connected` event.

## Replay

`~/.zeptoclaw/sessions/whatsapp/inbound-ledger.json`:

- wire message ids in `seen` / `sent`
- Fingerprint `chatId|fromMe|collapsed-body` with a 3 minute skip window in `isReplay`, but only for non-empty text. Caption-less media, reactions, and revokes are keyed by wire id so they do not collide.

There is no mute-fromMe-for-N-seconds-after-connect. First deploy with an empty ledger can process history once; those ids then persist.

## Access

Config `dmPolicy=allowlist` + `allowFrom` E.164 list. LID self-chat (`...@lid`) is treated as Message-yourself. `fromMe` in an allowlisted 1:1 is inbound from the operator. Groups need the group JID on the allowlist. A **barvis** wake word or an @mention of the bot's PN/LID/device JID starts a turn. The wake word in your own message to someone also starts a turn in that DM. `leave` unsubscribes a chat until the next **barvis**.

The `exec` tool only runs on an operator `fromMe` message in self-chat. A wake-word turn in a peer DM runs without `exec`.

`POST /reload` on the gateway hot-reloads `allowFrom`, `dmPolicy`, and `groupPolicy` without a restart.

## Pairing and store

Pair with `zeptoclaw whatsapp pair` — it prints a terminal QR (half-block glyphs) plus the raw pairing URL. Identity is stored at `{auth_dir}/native.sqlite` (default `~/.zeptoclaw/sessions/whatsapp/native.sqlite`). Deleting that file unpairs the device.

Text DM and group send/receive both work end to end. `sendText` auto-routes to group send when the target is a `g.us` JID, and group receive decrypts sender-key messages the same way. Inbound media downloads and decrypts. Outbound media, presence, reactions, revokes, edits, polls, location, and read receipts use the same native client.

## Past fixes

- usync silent-drop: the encoder wrote JID attributes as plain text, not the `JIDPair`/`ADJID` tags the server needs, so the server never answered. Fixed; usync resolves in about 300ms.
- 1:1 delivery: those chats arrive on the recipient LID, not the phone number. `sendText` resolves PN/LID through the stored `lid_map` and sets `peer_recipient_pn`.
- Group own-phone delivery: group sends query usync for own devices and include them in the SKDM fanout, so the sender phone decrypts group replies.
- Retry recovery: `sendText` caches the last 64 outbound plaintexts. A 1:1 retry drops the stale session, fetches a fresh prekey bundle, and resends with the same id. A group retry fans out SKDM plus skmsg. Cap: 5 resends per message.
- 401 logout: the client starts QR re-pair instead of leaving a dead session.
- LID-group phone delivery: in LID-addressed groups, self PN devices mirror to LID form before the SKDM fanout. Phones drop PN-addressed targets in LID groups.

## Sender attribution

Group prompts arrive as `[name]: body`. The name is the push name, else E.164 digits, else Baala for the operator's own messages. Burst follow-ups merge already-prefixed lines, and journal `[in]`/`[out]` lines carry `[sender]` tags after the chat marker. The model is told the prefix names the speaker, and that older turns claiming otherwise predate the feature.

## Signature

Outbound text is signed in Zig (`engagement.appendSignature`) with a space and ⚡ (U+26A1). The model is told not to add it. Silent `listen`/`leave` turns send nothing, so they stay unsigned.

Language rules live in `engagement.LANGUAGE_INSTRUCTIONS` (WhatsApp extra context) and `SOUL.md` (workspace system prompt).

## History after restart

RAM `WhatsAppSession` history is empty after `kill`/`start`. DMs (and groups) get same-chat lines from `memory/YYYY-MM-DD.md` via `dailyContext` before `runTurn`. That is how a later `hi barvis, i like her top` can see `i like ur top` from the same JID without loading other chats.

## Unacked turns

Before NIM, the gateway appends the inbound to `~/.zeptoclaw/sessions/whatsapp/pending-turns.jsonl` (wire id, chat JID, body, fromMe). After a successful send or silent listen/leave, that id is removed. On `connection status=connected`, remaining rows are replayed (`skip_journal`) so a SIGKILL mid-retry does not drop the turn.

## MEMORY.md in partner DMs

Injected only when `fromMe=true` (Baala). Peer inbound in that DM does not get `MEMORY.md` auto-injected. Same-chat journal still hydrates both directions.

## Burst coalesce

Inbound is journaled immediately. If that chat already has a NIM turn in flight, extra bodies go into a per-chat buffer (cap 16). After send or listen, those lines become one follow-up turn (`mergeBurstPrompt`). The mutex is not held during NIM, so a burst is not stuck behind RateLimit sleep.

Same-chat journal is keyed by WhatsApp JID (the thread), not by sender. That is the right isolation: both people in a DM share one history. Other JIDs and `MEMORY.md` stay out unless Baala `fromMe` in that DM.

## Inbound images

Inbound images download to `~/.zeptoclaw/sessions/whatsapp/media/`. The gateway records the last path per chat JID under `last-image/` and attaches that file as a NIM `image_url` data URL on:

- the image turn itself
- later text in the **same** DM (so "i like her top" can see the photo)

Other chats never get that file. Videos/audio are not vision-attached. Max 4MB.
