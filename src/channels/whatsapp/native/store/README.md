# WhatsApp native store

## Overview

Persistence for the WhatsApp native channel: `schema.zig` holds the folded whatsmeow SQL DDL (Postgres types mapped to SQLite) and open-time pragmas; `sqlite.zig` opens a SQLite file via `@cImport`, applies that schema, and exposes typed CRUD for device rows, Signal sessions/keys, LID map, and pre-keys; `store.zig` defines the higher-level `Device` model, JID/key types, and identity/session store vtable shapes ported from whatsmeow (BUILD:0 skeleton; SQL lives in `sqlite.zig`).

Tables created by `schema.zig:latest_schema`: `whatsmeow_version`, `whatsmeow_device`, `whatsmeow_identity_keys`, `whatsmeow_pre_keys`, `whatsmeow_sessions`, `whatsmeow_sender_keys`, `whatsmeow_app_state_sync_keys`, `whatsmeow_app_state_version`, `whatsmeow_app_state_mutation_macs`, `whatsmeow_contacts`, `whatsmeow_chat_settings`, `whatsmeow_message_secrets`, `whatsmeow_privacy_tokens`, `whatsmeow_nct_salt`, `whatsmeow_lid_map`, `whatsmeow_event_buffer`, `whatsmeow_retry_buffer`. `sqlite.zig` reads/writes a subset of those tables via prepared statements.

## Interface

- `schema.zig:latest_schema` — multi-statement SQL string: `CREATE TABLE IF NOT EXISTS` for all whatsmeow tables above plus two indexes on `whatsmeow_privacy_tokens` and `whatsmeow_retry_buffer`.
- `schema.zig:pragmatic_pragmas` — slice of three pragma strings: foreign keys ON, WAL journal, synchronous NORMAL.
- `sqlite.zig:Error` — SQLite/store error set (`OpenFailed`, `ExecFailed`, `PrepareFailed`, `BindFailed`, `StepFailed`, `InvalidLength`, `DeviceIdMustBeSet`, `NotOpen`, `OutOfMemory`).
- `sqlite.zig:PreKeyRecord` — struct `{ id, priv_key, pub_key, uploaded }` matching `whatsmeow_pre_keys` columns.
- `sqlite.zig:Device` — in-memory row mirroring `whatsmeow_device` (fixed-size key blobs, optional owned strings).
- `sqlite.zig:Device.deinit` — frees owned string/blob slices when `owned == true`.
- `sqlite.zig:Container` — `{ allocator, db, path }` SQLite handle wrapper.
- `sqlite.zig:Container.open` — `sqlite3_open`, busy timeout, extended result codes, runs pragmas and `latest_schema`, duplicates path.
- `sqlite.zig:Container.checkpoint` — `PRAGMA wal_checkpoint(TRUNCATE)`; errors ignored.
- `sqlite.zig:Container.deinit` — checkpoint, close DB, free path.
- `sqlite.zig:Container.putDevice` — upsert into `whatsmeow_device`; requires non-empty `dev.jid`.
- `sqlite.zig:Container.getDevice` — select by JID; returns owned `Device` or null.
- `sqlite.zig:Container.getAnyDevice` — `LIMIT 1` device row; returns owned `Device` or null.
- `sqlite.zig:Container.putIdentity` — upsert `whatsmeow_identity_keys`.
- `sqlite.zig:Container.getIdentity` — fetch 32-byte identity or null.
- `sqlite.zig:Container.putSession` — upsert `whatsmeow_sessions`.
- `sqlite.zig:Container.getSession` — fetch session blob (empty string if SQL NULL); caller frees slice.
- `sqlite.zig:Container.deleteSession` — delete one session row.
- `sqlite.zig:Container.deleteDevice` — delete device row then checkpoint.
- `sqlite.zig:Container.putSenderKey` — upsert `whatsmeow_sender_keys`.
- `sqlite.zig:Container.getSenderKey` — fetch sender key blob; caller frees slice.
- `sqlite.zig:Container.deleteSenderKey` — delete one sender key row.
- `sqlite.zig:Container.putLidMap` — delete conflicting PN rows then upsert `whatsmeow_lid_map`.
- `sqlite.zig:Container.getPnForLid` — lookup PN by LID; caller frees slice.
- `sqlite.zig:Container.getLidForPn` — lookup LID by PN; caller frees slice.
- `sqlite.zig:Container.putPreKeys` — loop upsert into `whatsmeow_pre_keys`.
- `sqlite.zig:Container.getPreKey` — fetch one pre-key record or null.
- `sqlite.zig:Container.removePreKey` — delete one pre-key row.
- `sqlite.zig:Container.getUnuploadedPreKeys` — ordered unuploaded rows up to `limit`; caller frees slice.
- `sqlite.zig:Container.markPreKeysUploaded` — set `uploaded=1` for `key_id <= up_to_id`.
- `sqlite.zig:Container.countPreKeys` — `COUNT(*)` for JID.
- `sqlite.zig:Container.nextPreKeyId` — `MAX(key_id)+1` or `1` if none.
- `store.zig:StoreError` — logical store errors (`NotImplemented`, `DeviceNotFound`, etc.).
- `store.zig:JID` — `{ user, server, device }` WhatsApp JID parts.
- `store.zig:JID.isEmpty` — true when `user` is empty.
- `store.zig:JID.format` — allocates canonical JID string (`user@server` or `user:device@server`).
- `store.zig:KeyPair` — 32-byte private/public key pair struct.
- `store.zig:KeyPair.generate` — random private key; BUILD:0 copies priv to pub until noise wired.
- `store.zig:PreKey` — signed pre-key fields including 64-byte signature slot.
- `store.zig:Device` — whatsmeow-style device with keys, names, optional `container` opaque handle.
- `store.zig:Device.init` — new device with generated keys, random `registration_id`, default signed pre-key id 1.
- `store.zig:Device.deinit` — frees allocated name/uuid/nonce strings if non-empty.
- `store.zig:Device.isLoggedIn` — true when `id` is set and not empty.
- `store.zig:IdentityStoreVTable` — function pointers: `putIdentity`, `deleteAll`, `deleteOne`, `isTrusted`.
- `store.zig:SessionStoreVTable` — function pointers: `getSession`, `hasSession`, `putSession`, `deleteSession`.

## Invariants

- `schema.zig:latest_schema` — `whatsmeow_device` enforces 32-byte noise/identity/signed pre-key/adv sig-key blobs, 64-byte signature blobs, and bounded `registration_id` / `signed_pre_key_id` (see inline `CHECK` clauses).
- `schema.zig:latest_schema` — child tables reference `whatsmeow_device(jid)` with `ON DELETE CASCADE` where declared; `whatsmeow_lid_map` has no FK to device.
- `schema.zig:pragmatic_pragmas` — foreign key enforcement is expected at runtime when applied by `Container.open`.
- `sqlite.zig:Container.putDevice` — returns `Error.DeviceIdMustBeSet` when `dev.jid.len == 0`.
- `sqlite.zig:Container.open` — always executes full `latest_schema` on open (greenfield folded schema, not incremental migrations).
- `sqlite.zig:scanDevice` / `sqlite.zig:columnArray` — fixed-width blobs must match expected lengths or `Error.InvalidLength`.
- `sqlite.zig:Container.nextPreKeyId` — returns `1` when no rows or NULL max; otherwise `max+1` bounded to `u32`.
- `store.zig:Device.isLoggedIn` — login state is derived only from non-empty `id` JID, not from SQLite.
- `store.zig:KeyPair.generate` — public bytes equal private bytes until real X25519 derivation is wired.

## Side Effects

- `sqlite.zig:Container.open` — creates/opens SQLite file at `path`, allocates duped path, runs DDL and pragmas (disk writes).
- `sqlite.zig:Container.checkpoint` — may truncate WAL to main database file.
- `sqlite.zig:Container.deinit` — checkpoint, closes connection, frees path memory.
- `sqlite.zig:Container.deleteDevice` — deletes row and calls `checkpoint` so restarts do not see stale device via `getAnyDevice`.
- `sqlite.zig:Container.putLidMap` — deletes from `whatsmeow_lid_map` where `lid<>?1 AND pn=?2` before insert/update.
- `sqlite.zig:Container.getDevice` / `getAnyDevice` / `getSession` / `getSenderKey` / lid lookups / `getUnuploadedPreKeys` — allocate returned data via container or caller allocator.
- `sqlite.zig:Device.deinit` — frees owned slices on heap when `owned`.
- `store.zig:JID.format` — allocates formatted JID string on success.
- `store.zig:Device.init` — reads random bytes via `compat.fillRandom` / `compat.randomInt`.
- `store.zig:Device.deinit` — frees heap copies of string fields when lengths non-zero.

## Verification

- Run: `zig build test`
