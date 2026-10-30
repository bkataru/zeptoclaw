# WhatsApp channel

## Overview

The `src/channels/whatsapp` package implements ZeptoClaw’s WhatsApp integration: shared message and config types (`types.zig`), Zepto config mapping (`config.zig`), DM/group access control (`access_control.zig`), debounced session state and transcripts (`session.zig`), restart-safe inbound dedup (`inbound.zig`), downloaded-media helpers (`inbound_media.zig`), outbound chunking and markdown tables (`outbound.zig`), listen/leave engagement and reply signing (`engagement.zig`), burst pending turns on disk (`pending.zig`), CLI pairing entry (`pairing.zig`), and the native multi-device channel facade (`whatsapp_channel.zig`).

Wire protocol, encryption, and SQLite session storage live under [./native/README.md](./native/README.md). Pair with `zeptoclaw whatsapp pair`; credentials and ledgers default under `WHATSAPP_AUTH_DIR` or `~/.zeptoclaw/sessions/whatsapp`.

## Interface

- `access_control.zig:AccessControlResult` — Outcome of a policy check: `allowed`, optional `reason`, optional `pairing_code`.
- `access_control.zig:AccessControl` — Config plus paired senders, pending pairings, and group allowlist maps; DM/group checks, pairing codes, allowlist CRUD.
- `access_control.zig:E164Normalizer` — Static `normalize` and `isValid` for phone strings.
- `config.zig:loadFromZeptoConfig` — Maps ZeptoClaw WhatsApp string fields into `types.WhatsAppConfig` with duped lists and `auth_dir`.
- `engagement.zig:IDLE_UNSUB_SEC` — 1800-second idle threshold before lazy unsubscribe in `isActive`.
- `engagement.zig:subscribe` — Marks chat subscribed and sets `last_active` to current unix time.
- `engagement.zig:unsubscribe` — Clears subscribed on the chat slot if present.
- `engagement.zig:isSubscribed` — Returns subscribed bit from the fixed global slot table.
- `engagement.zig:noteActivity` — Updates `last_active` for an existing chat slot.
- `engagement.zig:isActive` — Subscribed and within `IDLE_UNSUB_SEC`; lazily unsubscribes on expiry.
- `engagement.zig:isSelfChat` — Compares chat id user part to any identity via native `jid.user`.
- `engagement.zig:TurnGate` — Enum `skip_peer_from_me`, `listening`, or `run` for inbound turn routing.
- `engagement.zig:ChatKind` — Enum `dm_self`, `dm_peer`, or `group` for turn input.
- `engagement.zig:TurnInput` — Bundles kind, `from_me`, `triggered`, `subscribed`, `event_only` for `nextGate`.
- `engagement.zig:nextGate` — Pure FSM: wake/active rules differ for self, peer DM, and group.
- `engagement.zig:applyGate` — `run`+`triggered` calls `subscribe`; `skip_peer_from_me` calls `unsubscribe`.
- `engagement.zig:Presence` — Enum `idle` or `active` derived from subscription.
- `engagement.zig:presenceOf` — Maps `isSubscribed` to `Presence.active` or `.idle`.
- `engagement.zig:PRESENCE_INSTRUCTIONS` — Multi-line agent prompt for listen/leave presence on WhatsApp.
- `engagement.zig:SIGNATURE_MARK` — UTF-8 lightning bolt appended to outbound replies.
- `engagement.zig:LANGUAGE_INSTRUCTIONS` — Multi-line Barvis tone, safety, and config/reload guidance.
- `engagement.zig:alreadySigned` — True if trimmed text ends with `SIGNATURE_MARK`.
- `engagement.zig:appendSignature` — Dupes text or allocPrints text plus `SIGNATURE_MARK` once.
- `inbound.zig:InboundProcessor` — Dedup ledger plus delegate to `WhatsAppSession.processInboundMessage`.
- `inbound.zig:MessageDeduper` — TTL-based `StringHashMap` duplicate cache for auxiliary dedup.
- `inbound_media.zig:remember` — Writes mime and path lines to `auth_dir/last-image/{safe_chat}.txt`.
- `inbound_media.zig:loadLast` — Reads last-image file; caller owns returned path; fills `mime_buf`.
- `inbound_media.zig:fileToDataUrl` — Base64 data URL for file up to 4 MiB.
- `inbound_media.zig:fileToDataUrlCapped` — Same as `fileToDataUrl` with caller-supplied `max_bytes` ceiling.
- `inbound_media.zig:CACHE_LIMIT_BYTES` — 1 GiB default media directory budget before eviction.
- `inbound_media.zig:enforceCacheLimit` — Evicts oldest files under `auth_dir/media` then prunes dangling last-image pointers.
- `outbound.zig:OutboundProcessor` — Chunks text, converts markdown tables, retries sends via injected `send_fn`.
- `outbound.zig:SendResult` — `success`, `message_ids` slice, `chunk_count`.
- `outbound.zig:MarkdownTableConverter` — Standalone markdown table to plain text converter.
- `pairing.zig:runPairing` — CLI entry: config for pairing, QR flow, `runNativePairForeground`, restart hint.
- `pending.zig:PendingTurn` — Owned `id`, `chat_id`, `body` buffers plus `from_me` and `direct` flags.
- `pending.zig:filePath` — Resolves `pending-turns.jsonl` under `WHATSAPP_AUTH_DIR` or default home path.
- `pending.zig:loadFrom` — Parses JSONL lines into owned `PendingTurn` slice capped at `MAX_ROWS`.
- `pending.zig:enqueueAt` — Rewrites file skipping duplicate id and enforcing `MAX_ROWS` FIFO.
- `pending.zig:ackAt` — Rewrites file omitting row matching id.
- `pending.zig:enqueue` — `enqueueAt` at default `filePath`.
- `pending.zig:ack` — `ackAt` at default `filePath`.
- `pending.zig:load` — `loadFrom` at default `filePath`.
- `pending.zig:mergeBurstPrompt` — Builds agent prompt listing bodies newest-first with tool-use instruction.
- `session.zig:WhatsAppSession` — Inbound debouncing, access control, `stable_messages`, group transcripts.
- `session.zig:AccessResult` — `allowed`, `reason`, `pairing_code` from access checks.
- `session.zig:ProcessResult` — `allowed`, `reason`, `pairing_code`, optional borrowed `message` pointer.
- `types.zig:MessageType` — Enum text, image, video, audio, document, location, poll, reaction, revoke, unknown.
- `types.zig:ChatType` — Enum direct or group.
- `types.zig:ConnectionStatus` — Enum disconnected, connecting, connected, logged_out.
- `types.zig:DmPolicy` — Enum allowlist, pairing, open, disabled.
- `types.zig:GroupPolicy` — Enum allowlist, open, disabled.
- `types.zig:Location` — Latitude and longitude `f64` pair.
- `types.zig:ReplyContext` — `message_id`, optional participant and quoted message.
- `types.zig:WhatsAppMessage` — Heap-owned inbound/outbound message with mentions list and metadata.
- `types.zig:PollOption` — Poll option name string.
- `types.zig:Poll` — Name, options slice, `selectable_count`.
- `types.zig:ConnectionUpdate` — Status plus optional `self_jid`, `self_e164`, error.
- `types.zig:QrEvent` — QR string payload.
- `types.zig:WhatsAppConfig` — Channel settings: policies, `allow_from`, debounce, native flag, etc.
- `types.zig:SendMessageOptions` — Optional `media_url`, caption, `gif_playback` for sends.
- `types.zig:SendReactionOptions` — `from_me`, participant, remove flags.
- `types.zig:DebouncedEntry` — `WhatsAppMessage` plus enqueue timestamp.
- `types.zig:Debouncer` — Per-from-key debounce buffer with last-flush times.
- `whatsapp_channel.zig:WhatsAppConfig` — Re-export alias of `types.WhatsAppConfig`.
- `whatsapp_channel.zig:WhatsAppChannel` — Native multi-device plugin with mutex, reader thread, and handler callbacks.
- `whatsapp_channel.zig:inboundToWhatsAppMessage` — Maps native `InboundMessage` to `WhatsAppMessage` including mentions and `reply_context`.

## Invariants

- `access_control.zig:AccessControl` — Pending pairing codes expire after 300 seconds; `validatePairingCode` compares stored code with `mem.eql`.
- `access_control.zig:AccessControl` — DM policy disabled/allowlist/pairing/open gates direct messages; group policy gates group messages; `group_require_mention` requires non-empty `mentioned_jids` when set.
- `config.zig:loadFromZeptoConfig` — Invalid `whatsapp_dm_policy` or `whatsapp_group_policy` strings return `InvalidDmPolicy` or `InvalidGroupPolicy`; caller must `deinit` the returned config.
- `engagement.zig:nextGate` — At most 32 chat slots; chat ids truncated to 128 bytes; `event_only` masks subscribed for active calculation; group `from_me` with only leftover presence yields `listening`, not `run`.
- `inbound.zig:InboundProcessor` — `seen_messages` capped at 2000 FIFO; fingerprints only for non-media text with body; fingerprint key is chat|fromMe|body clipped to 400 chars within TTL; ledger write failure does not fail the current turn.
- `inbound_media.zig:enforceCacheLimit` — `safeChat` keeps alnum, dot, underscore, hyphen; others become underscore.
- `outbound.zig:OutboundProcessor` — `sendMedia` returns `error.MediaTooLarge` when file exceeds `config.media_max_mb`; only selected network errors are retryable.
- `pending.zig:enqueueAt` — Body clipped to max body; at most 32 rows; duplicate enqueue id is ignored.
- `session.zig:WhatsAppSession` — Group allowlist matches `chat_id` against `config.allow_from` entries; `stable_messages` pruned to 16 on flush; `ProcessResult.message` borrowed until eviction; session `validatePairingCode` accepts any code after expiry check (code not compared).
- `types.zig:WhatsAppMessage` — String fields must be allocator-owned for safe `deinit`; `Debouncer.enqueue` consumes message ownership.
- `types.zig:WhatsAppConfig` — Default DM pairing, group allowlist, 50 MiB media, debounce 0 via `init`.
- `whatsapp_channel.zig:WhatsAppChannel` — Outbound send APIs return `error.NotConnected` without `native_client`; native loop stops reconnect after three consecutive logged-out strikes; `restartChild` ignores calls within 600 ms of `last_restart_ms` or when `restart_in_flight`.

## Side Effects

- `access_control.zig:AccessControl` — Allocator dup/free on paired senders, pending pairings, and group allowlist keys and codes.
- `config.zig:loadFromZeptoConfig` — Heap allocates `auth_dir`, `allow_from` entries, and `group_activation_commands`.
- `engagement.zig:subscribe` / `engagement.zig:unsubscribe` / `engagement.zig:isActive` / `engagement.zig:applyGate` — Mutates global engagement slot table.
- `engagement.zig:appendSignature` — Allocates via caller allocator.
- `inbound.zig:InboundProcessor` — Reads/writes `{auth_dir}/gateway-inbound-ledger.json`; creates auth dir parents on ledger save.
- `inbound_media.zig:remember` / `inbound_media.zig:enforceCacheLimit` — Filesystem read/write under auth dir `last-image` and `media`; deletes oldest media and stale index files; logs on eviction.
- `outbound.zig:OutboundProcessor` — `std.Io.sleep` between send retries; opens media paths for size check; heap allocates converted text, chunks, and message id dupes.
- `pairing.zig:runPairing` — Prints to stdout; native pairing writes credentials under `auth_dir` (see [./native/README.md](./native/README.md)).
- `pending.zig:enqueueAt` / `pending.zig:ackAt` — Truncating rewrite of `pending-turns.jsonl`; creates parent directories.
- `session.zig:WhatsAppSession` — Debouncer takes ownership of enqueued messages; heap allocates pairing codes, stable copies, transcript lines, combined debounced bodies.
- `types.zig:WhatsAppConfig` — `init`, `replaceAllowFrom`, and message dup paths allocate via struct allocator.
- `whatsapp_channel.zig:WhatsAppChannel` — Spawns native reader and per-message dispatch threads; opens/writes `auth_dir/native.sqlite`, downloads media to `auth_dir/media`; mutex protects connection fields; `ensureAuthDir` on connect and media save.

## Verification

- Run: `zig build test`
