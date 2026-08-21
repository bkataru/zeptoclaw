# Native WhatsApp Zig Architecture — whatsmeow Port Audit

**Source:** `tulir/whatsmeow` (Go, MPL-2.0) at `/tmp/whatsmeow` — Zig 0.16.0 target
**Scope audited:** `client.go` 1066 lines, `store/store.go` 324, `store/sqlstore/*`, `appstate/*`, `qrchan.go` 222, `pair.go` 314, `pair-code.go` 248, `pair-passkey.go` 324, `handshake.go` 182, `socket/*`
**Existing shim:** `src/channels/whatsapp/whatsapp_channel.zig` — Baileys Node.js bridge via JSON-RPC over stdio + reader thread (`compat.getIo()` Io API, `std.Thread`, `std.Io.Mutex`). Native port must implement same `WhatsAppChannel` surface so `zeptoclaw whatsapp pair` / gateway need no CLI change.

---

## 1. client.go (1066 lines) — connection lifecycle

**Shape:**
```go
type Client struct {
  Store *store.Device
  Log   waLog.Logger
  socket *socket.NoiseSocket; socketLock sync.RWMutex; socketWait chan struct{}
  isLoggedIn, paired atomic.Bool; expectedDisconnect *exsync.Event; forceAutoReconnect atomic.Bool
  EnableAutoReconnect, InitialAutoReconnect bool; LastSuccessfulConnect time.Time; AutoReconnectErrors int
  AutoReconnectHook func(error) bool; SynchronousAck bool
  // ~15 more maps/mutexes: responseWaiters, nodeHandlers, handlerQueue chan *Node (2048), eventHandlers []wrappedEventHandler
  // appStateProc *appstate.Processor; historySyncNotifications chan *HistSync (32)
  // mediaConnCache, retry maps, presence/TT tokens, group/user caches, recentMessages ring, signal session history
}
```

**Lifecycle:** `NewClient(deviceStore, log)` → `Connect()` → `ConnectContext(ctx)` → `unlockedConnect` (picks `preLoginHTTP` vs `websocketHTTP` by `Store.ID==nil`, `socket.NewFrameSocket` → `doHandshake` with ephemeral `KeyPair` → `keepAliveLoop` + `handlerQueueLoop`) → `WaitForConnection` / `IsConnected` / `IsLoggedIn` → `Disconnect`/`ResetConnection`/`Logout` (logout sends `remove-companion-device` IQ then `Store.Delete`).

**I/O:** `handleFrame` (decompress `waBinary.Unpack` → `waBinary.Unmarshal` → `receiveResponse` or `handlerQueue chan *Node` with backpressure fallback to goroutine), `handlerQueueLoop` (10-deep concurrency, 30 s ticker warns if handler stalls), `onDisconnect` (stops NoiseSocket, clears waiters, dispatches `events.Disconnected` + `autoReconnect` unless `expectedDisconnect`).

**Event bus:** `AddEventHandler`/`AddEventHandlerWithSuccessStatus` (`atomic.AddUint32` IDs) / `RemoveEventHandler` (copy-on-remove, warns not to call from handler — needs goroutine) / `dispatchEvent` fans out under `RLock`.

**Reconnect:** `autoReconnect` — `EnableAutoReconnect && Store.ID!=nil` only, backoff `AutoReconnectErrors*2s`, `expectedDisconnect.WaitTimeoutCtx` break, `AutoReconnectHook` can veto, `InitialAutoReconnect` retries even initial `Connect` on 408/500-504 / dial failure.

**Zig translation notes:**
- `handlerQueue (chan 2048)` → bounded `std.atomic.Queue` or `channels` lib or `std.Io` queue + worker thread pool. Simplest: `std.ArrayList` + `Mutex` + `Condition`.
- Goroutines per frame → `std.Thread.spawn` or single `handlerQueueLoop` thread dispatching via thread pool.
- `atomic.Bool/Value`, `sync.RWMutex` → `std.atomic.Value`, `std.Thread.RwLock` / `std.Io.Mutex`.
- `responseWaiters map[string]chan *Node` → `StringHashMap(Channel)` where channel = `std.Thread.Condition` + pending node.
- `BackgroundEventCtx` → parent `std.Io` cancellation `Event`.
- `uniqueID`, `idCounter`, `serverTimeOffset atomic.Int64`, `mediaConnCache` → keep verbatim.
- **Pitfall:** `RemoveEventHandler` deadlock if called from handler — document `spawn` requirement.

---

## 2. store/store.go (324) + sqlstore

**Interfaces in `store.go`:**
- `IdentityStore` (Put/Delete/IsTrusted, `DeleteAllIdentities phone:%`), `SessionStore` (Get/Has/GetMany/PutMany/Delete, `MigratePNToLID`), `PreKeyStore` (GetOrGen/GenOne/Get/Remove/MarkUploaded/Count), `SenderKeyStore` (Put/Get by group+user), `AppStateSyncKeyStore`, `AppStateStore` (version+hash + mutation MACs), `ContactStore`, `ChatSettingsStore`, `DeviceContainer`, `MsgSecretStore`, `PrivacyTokenStore`, `NCTSaltStore`, `EventBuffer` (decryption txn, ciphertext hash, outgoing retry), `LIDStore` (global, pn↔lid). Composed as `AllSessionSpecificStores` (per-JID) + `AllGlobalStores` + `AllStores`. `Device` holds `NoiseKey/IdentityKey *KeyPair`, `SignedPreKey *PreKey`, `RegistrationID u32`, `AdvSecretKey []byte`, `ID *JID`, `LID JID`, `Account *ADVSignedDeviceIdentity`, `Platform/BusinessName/PushName`, `LIDMigrationTimestamp`, `CompanionMetaNonce`, `FacebookUUID uuid.UUID`, plus store handles + `Container DeviceContainer`.

**`store/sqlstore/` specifics (`container.go` 300, `store.go` 1110, `lidmap.go`, `upgrades/`):**
- `Container{db *dbutil.Database, log, LIDMap *CachedLIDMap}` — `New`/`NewWithDB`/`NewWithWrappedDB`, `Upgrade` checks `PRAGMA foreign_keys` on sqlite.
- `SQLStore{*Container, JID string, preKeyLock, contactCache map[JID]*ContactInfo, migratedPNSessionsCache *Set}` implements `AllSessionSpecificStores`.
- 18 tables (see `upgrades/00-latest-schema.sql`): `whatsmeow_device` (PK jid, 32-byte keys, 64-byte sigs), `identity_keys/sessions/pre_keys/sender_keys/app_state_{sync_keys,version,mutation_macs}/contacts/chat_settings/message_secrets/privacy_tokens/nct_salt/lid_map/event_buffer/retry_buffer` — all FK `ON DELETE CASCADE` to device jid.
- Query style: `$1` placeholders via `dbutil` (`PostgresArrayWrapper` for `ANY($2)`), `ON CONFLICT DO UPDATE`, dialect switch (`dbutil.SQLite` vs `Postgres`). Contact cache in-memory + `GetMassInsertValues`.

**Zig translation — recommended `store` layout:**
```
src/channels/whatsapp/native/store/
  store.zig        // interface vtables + Device struct + errors
  sqlite.zig       // Container + SQLStore (sqlite3 via @cImport)
  schema.zig       // embedded 00-latest-schema.sql + incremental upgrades 03-15
  lidmap.zig
```
- **SQLite binding:** no dep in `build.zig.zon` today; add either `zig-sqlite` (pure Zig wrapper) or raw `libsqlite3` via `linkSystemLibrary("sqlite3")` + `@cImport(@cInclude("sqlite3.h"))`. Recommend `cImport` + thin wrapper: matches `dbutil` semantics, keeps `PRAGMA foreign_keys=ON`, `PRAGMA journal_mode=WAL` parity. Host already has `libsqlite3`.
- **Interfaces → vtables:** Go interfaces don't exist; use `struct { ptr: *anyopaque, vtable: *const VTable }` per store trait or single `Store { ctx, putIdentity_fn, ... }`. Or comptime generic `StoreImpl anytype` with `@hasDecl` checks — prefer vtable for `Device` to hold `*anyopaque` + table so `Device.SetAllStores` still works.
- **Transactions:** `DoDecryptionTxn` needs `BEGIN IMMEDIATE` — expose `txn(TxFn)` helper.
- **Migrations:** embed `upgrades/*.sql` via `@embedFile`, version table `whatsmeow_version`, apply in order on `Container.Upgrade`.
- **Global vs per-device:** `LIDStore` is global (`whatsmeow_lid_map` keyed by lid→pn); keep `Container.LIDMap` separate from per-`SQLStore`.
- **Pitfall:** CHECK lengths (32/64/128) — enforce in Zig before insert; Postgres `uuid` → Zig `std.uuid` or string.

---

## 3. appstate/*

| file | lines | role |
|------|-------|------|
| `keys.go` | 227 | `WAPatchName` consts (5 names), `Index*` constants (~60), HKDF-derived `ExpandedAppStateKeys` cache, `getAppStateKey` with in-memory + DB lookup |
| `hash.go` | 101 | `Mutation{KeyID,Op,Action,Version,Index,IndexMAC,ValueMAC}`, `HashState{Version, Hash [128]}`; `updateHash` collects `added/removed valueMACs` → `lthash.WAPatchIntegrity.SubtractThenAdd`, helpers `generateSnapshotMAC`/`generatePatchMAC`/`generateContentMAC` (`HMAC-SHA256`/`SHA512`, `concatAndHMAC`) |
| `decode.go` | 407 | `ParsePatchList` (snapshot+external blob download via `DownloadExternalFunc`), `Processor.decodeMutation` (decrypt blob via `cbcutil`, verify `valueMAC`, AES-CBC, `generateContentMAC` check, indexMAC HMAC), `patchOutput{RemovedMACs,AddedMACs,Mutations}` |
| `encode.go` | 375 | `BuildMute/Abs, BuildPin, BuildArchive, BuildMarkChatAsRead` → `PatchInfo{Type, Mutations []MutationInfo{Index,Version,Value}}` helpers; `EncodePatch` (marshal `SyncActionValue` proto, encrypt, MAC, wrap `SyncdPatch`) |
| `lthash/lthash.go` | ~80 | literal LTHash: `pointwise {+,-} mod 2^16` over 128 bytes using HKDF-SHA256 of valueMACs |
| `recovery.go` | 97 | `ParseRecovery` (gzip decompress `PeerDataOperationResult`) + `ProcessRecovery` (reset version/hash, bulk MAC insert) |
| `errors.go` | 19 | sentinel errors |

**Zig notes:**
- `lthash` is small, pure `std.crypto` + `hkdfutil.SHA256` — port first, high testability.
- `hash.go` HMACs → `std.crypto.auth.hmac.sha2.HmacSha256/512`.
- `decode/encode` need `waServerSync`/`waSyncAction` protos + `std.crypto.cipher.aes`, `cbcutil` equivalent. Recommend `std.crypto` AES-CBC (or `zig-aes`).
- `Processor` holds `Store *Device` + `log`; cache `ExpandedAppStateKeys` in `StringHashMap`.
- Defer full `appstate` until store + binary done — matches existing `native/README.md` "defer".

---

## 4. Pairing — qrchan.go 222, pair.go 314, pair-code.go 248, pair-passkey.go 324

**`qrchan.go`:** `QRChannelItem{Event, Error, Code, Timeout, PasskeyRequest, PasskeyConfirmation}`; sentinels `QRChannelSuccess/Timeout/ErrUnexpectedEvent/ClientOutdated/ScannedWithoutMultidevice`; `qrChannel{Mutex, cli, log, ctx, handlerID, closed atomic.Bool, output chan QRChannelItem, stopQRs chan struct{}}`. `emitQRs(codes []string)` paces 60 s for first of 6 codes else 20 s, backpressure via `select default` → close + `RemoveEventHandler` + `Disconnect`; `handleEvent` switches on `*events.QR/*QRScannedWithoutMultidevice/*PairPasskeyRequest/*PairPasskeyConfirmation` → forwards or auto-confirms if `SkipHandoffUX`.

**`pair.go`:** `Adv*SignaturePrefix [2]byte{6,0/1/5/6}`; `handleIQ` dispatches `pair-device` (ACK IQ result, build `events.QR{Codes: makeQRData(ref, clientType)}` where `makeQRData = https://wa.me/settings/linked_devices#ref,base64(noisePub),base64(idPub),base64(advKey),clientType`) vs `pair-success` (parse `device-identity/biz/device[jid+lid]/platform/client-props` proto, goroutine `handlePair` → `PairSuccess`/`PairError` + `sendUnifiedSession`). `getQRClientType` maps `store.DeviceProps.PlatformType` + `ClientPayload.UserAgent` → `PairClientType`.

**`pair-code.go`:** `PairClientType` enum `"0"`/`"1"` … `"c"`/`"e"`; `linkingBase32 = "123456789…XYZ"`; `phoneLinkingCache{jid, keyPair, linkingCode, pairingRef}`; `generateCompanionEphemeralKey` → `pbkdf2(5-byte code, salt 32, 65536, sha256) → AES-CTR` wrap of ephemeral pubkey → 80-byte blob `[salt|iv|encPub]`; `PairPhone(phone, showPush, clientType, displayName)` validates `phone` (strip non-digits, reject leading `0`, <=6), sends IQ `link_code_companion_reg{jid, stage:companion_hello, wrappedPub, serverAuthPub, platform_id, platform_display, nonce:0}` → store cache, returns `XXXX-XXXX`; `handleCodePairNotification` path uses `curve25519`, `hkdfutil`, `gcmutil`.

**`pair-passkey.go`:** `passkeyLinkingCache{keyPair, companionNonce 32, pairingRef, deviceType}` + `passkeyHandoffKey{hmac 32, ts}` (valid 5 min, `HKDF(advKey, "shortcake-passkey-handoff-v1")`); `handlePasskeyNotification` (verify `from==ServerJID`, parse `pubKey` or fallback `getPasskeyRequestOptions`, store handoffKey, rotate `AdvSecretKey=random(32)`, emit `PairPasskeyRequest`); `SendPasskeyResponse(WebAuthnResponse)` (json marshal, `getCompanionRef`, new ephemeral + 32 nonce, `CompanionEphemeralIdentity{pub, deviceType, ref}` → `sha256(ident+nonce)` commitment → `ProloguePayload` proto + optional `HMAC(prologue, handoffKey)` proof → IQ `passkey_prologue{credential_id, webauthn_assertion, prologue_payload, [pairing_handoff_proof]}`).

**Zig notes:**
- QR pacing needs timer: `std.Io` timer or `std.time.Timer` + `select` emulation via `std.Thread.Condition` + deadline checks. `atomic.Bool closed` directly maps.
- `makeQRData` base64 is `std.base64.standard`.
- Pair-code PBKDF2/AES-CTR: `std.crypto.pwhash.pbkdf2` + `std.crypto.core.aes`.
- Pair-passkey: `std.crypto.dh.X25519`, `std.crypto.auth.hmac.sha2`, `std.json`, protobuf for `CompanionReg`.
- All three pairing modes share IQ path (`sendIQ` with `infoQuery{Namespace:"md", Type:"set"}`) — factor `iq.zig`.

---

## 5. handshake.go + socket/*

- `handshake.go:doHandshake(ctx, fs *FrameSocket, ephemeralKP)` — Noise_XX_25519_AESGCM_SHA256: `NewNoiseHandshake.Start(NoiseStartPattern, header)` → `Authenticate(ephemeralPub)` → send `HandshakeMessage{ClientHello{Ephemeral}}` → await `ServerHello{Ephemeral, Static(ciphertext), Payload(certCiphertext)}` (20 s timeout) → `Authenticate(serverEphemeral)` → `MixSharedSecret(ephemeralPriv, serverEphem)` → `Decrypt(staticCiphertext)` → `MixSharedSecret(ephemeralPriv, staticPlain)` → `Decrypt(cert)` → `verifyServerCert` (proto `CertChain`, check `WACertPubKey [32]`, validity window) → `Encrypt(noisePub)` → `MixSharedSecret(noisePriv, serverEphem)` → `ClientFinish{Static(encNoisePub), Payload(enc(ClientPayload proto))}` → `nh.Finish(ctx, fs, handleFrame, onDisconnect)` → `NoiseSocket` (read/write AEAD keys, 12-byte IV `bigEndian(counter)`).

- `socket/noisesocket.go` 124: `NoiseSocket{fs, onFrame, writeKey/readKey cipher.AEAD, writeCounter/readCounter u32, writeLock, destroyed atomic.Bool, stopConsumer}`; `SendFrame` seals `writeKey.Seal(nonce=IV(counter))`, async `fs.SendFrame`; `receiveEncryptedFrame` opens `readKey`.
- `socket/framesocket.go` + `noisehandshake.go` + `socket/constants.go` — websocket `wss://web.whatsapp.com/ws/chat` (`coder/websocket`), header/frame packing.

**Zig translation:** `native/socket.zig` should split into `framesocket.zig` (websocket — use `std.http.Client` websockets or raw `std.net` + `websocket` lib), `noise.zig` (handshake state machine, `std.crypto.dh.X25519`, `std.crypto.aead.aes_gcm`, `sha256`), `handshake.zig`. Needs X.509 `WACertPubKey` constant.

---

## 6. Existing Zig wrapper audit — `whatsapp_channel.zig` 529 lines

- Holds `node_process Child`, `node_std/stdout/stderr File`, `connected bool`, `self_jid/self_e164 ?[]u8`, handlers, `reader_thread Thread`, `mutex Io.Mutex`.
- `connect` spawns `node baileys_wrapper.js`, sends `init{auth_dir, print_qr, allow_from}` then `onMessage/onConnection/onQr` JSON-RPC; `readerLoop` (8 KiB buf, line-buffered `\n` split) → `processLine` (dispatch `message/connection/qr`), `sendRequest` placeholder (fire-and-forget today — needs id→future).
- `disconnect` sends `disconnect` RPC, `nanosleep 100ms`, `kill+wait`, `thread.join`; `waitForConnection` polls `connected` with 100 ms sleep until timeout.
- `sendMessage/sendMedia/sendReaction/sendPoll/markRead/sendPresence/getContactInfo/getGroupMetadata` all JSON-RPC.
- `compat.getIo()` threaded Io introduced for 0.16; builds GREEN.

**Migration strategy:** keep `whatsapp_channel.zig` as façade, add compile flag `config.whatsapp_native: bool` (or runtime fallback) that picks `native/client.zig` vs child process. Interface stays `{connect, disconnect, waitForConnection, sendMessage, onMessage, onConnection, onQr}`.

---

## 7. Proposed Zig architecture

### File layout

```
src/channels/whatsapp/
  whatsapp_channel.zig   // façade, picks native vs baileys
  types.zig              // unchanged
  config.zig, inbound.zig, outbound.zig, session.zig  // unchanged
  pairing.zig            // thin CLI entry, delegates to native/pair.zig
  native/
    ARCHITECTURE.md
    client.zig           // Client lifecycle (port of client.go)
    socket.zig           // NoiseSocket + FrameSocket facade
    framesocket.zig      // websocket, frame packing
    noise.zig            // noise handshake state
    handshake.zig        // doHandshake + verifyServerCert
    binary.zig           // Node/Attrs/encode/decode (attrs.go + encoder/decoder/node/unpack)
    iq.zig               // infoQuery + sendIQ/responseWaiters
    pair.zig             // qrchan + pair + pair-code + pair-passkey
    store/
      store.zig          // Device + vtable traits (AllStores)
      sqlite.zig         // Container + SQLStore + prepared statements
      schema.zig         // @embedFile upgrades/00-latest-schema.sql
      lidmap.zig
    appstate/
      mod.zig
      keys.zig
      hash.zig
      lthash.zig
      decode.zig
      encode.zig
      recovery.zig
    signal/              // defer — libsignal / x3dh / double-ratchet
    proto/               // zig-protobuf generated from /tmp/whatsmeow/proto/*.proto
```

### Store replacement (sqlite) — concrete steps

1. **Embed schema:** copy `00-latest-schema.sql` verbatim (replace `bytea → BLOB`, `uuid` → `TEXT` for sqlite). Ship `upgrades/*.sql` as `@embedFile`, implement `Container.Upgrade` that reads `whatsmeow_version` and applies missing files.
2. **SQLite binding:** `build.zig` → `exe.linkLibC(); exe.linkSystemLibrary("sqlite3");` + `mod.addCSourceFiles` if needed. Minimal wrapper: `open(path)`, `exec(sql)`, `prepare(sql) -> Stmt{step, columnBytes/Text/Int, bindBlob/Text/Int, finalize}`, `lastInsertRowId`, `changes`. Enable `PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;`.
3. **Traits → vtables:** define `IdentityStoreVTable{putIdentity, deleteAll, deleteOne, isTrusted}` etc; `Device` holds `store_ctx: *anyopaque` + `vtable: *const DeviceVTable` so `Device.Save/Delete/GetJID/GetAltJID` work unchanged. Provide `SqliteStore` struct that satisfies all vtables; also `NoopStore` for `ErrDeviceDeleted` path.
4. **Container:** `Container.init(allocator, path)` opens DB, runs migrations, exposes `getDevice(jid)`, `getAllDevices()`, `newDevice()`. `LIDMap` table `whatsmeow_lid_map(lid TEXT PK, pn TEXT UNIQUE)`.
5. **Testing:** in-memory `":memory:"` DB, round-trip each table.

### Client port — phased plan

**Phase 0 — façade (1 day):** add `config.whatsapp_native: bool = false`; `whatsapp_channel.zig` branches; all native stubs return `error.NotImplemented` → build stays green.

**Phase 1 — binary + framing (1 week):** `binary.zig` (WA binary format: `0x00` list tags, token dict `binary/token/token.go`, `util/packed`); `framesocket.zig` (websocket dial via `std.http.Client` or `websocket` zig lib, `SendFrame/Frames channel`). Unit-test against Go `binary` vectors.

**Phase 2 — store (1 week):** ship `store/sqlite.zig` + schema; `Device` CRUD; add `zig build test` that opens temp DB and exercises `PutIdentity/GetSession/PutAppStateVersion`.

**Phase 3 — handshake + pairing (1–2 weeks):** `noise.zig` + `handshake.zig` (hardest crypto — validate against Go `handshake.go` with shared `WACertPubKey`); `pair.zig` (QR channel + pair-code + pair-passkey) with timer pacing.

**Phase 4 — client loop (2 weeks):** `client.zig` core: `connect/unlockedConnect`, `handleFrame`, `handlerQueue`, `responseWaiters`, `eventHandlers` list, `autoReconnect`, `WaitForConnection`, `Disconnect/Logout`, plus `iq.zig`, `keepalive.go` equivalent (`send !` every 30 s), `update.go`/`notification.go` dispatch.

**Phase 5 — e2e + appstate (defer or 3+ weeks):** Signal `libsignal` (double-ratchet, X3DH, sender keys) — either bind `libsignal-protocol-c` or pure-Zig port; `appstate` decode/encode/hash/lthash depend on signal keys.

**Hard dependency:** protobuf. whatsmeow has ~30 `wa*.proto` files. Use `zig-protobuf` (generate `proto/*.zig`) or `prost`-style runtime. Needed for `ClientPayload`, `HandshakeMessage`, `SyncdPatch`, `CertChain`, `WebAuthnResponse`, `CompanionReg`.

### Compat / allocator notes

- Follow `compat.zig` pattern (`getIo()`, `getSelfExeDir`, `Io.Mutex`). All `std.process.Child`/`File.readStreaming/writeStreamingAll` already use `Io`.
- Allocators: `Client` owns `allocator`; per-frame use `std.heap.ArenaAllocator` reset after `handleFrame`, per-node `allocator.dupe` for retained `Device.ID`.
- No `golang.org/x/sync/semaphore` — use `std.Thread.Semaphore`.
- Errors: map Go sentinel `ErrNotLoggedIn/ErrAlreadyConnected/ErrClientIsNil/ErrInvalidLength` to `error{NotLoggedIn, AlreadyConnected, ClientIsNil, InvalidLength}`.

### Risks

- **Signal** is the long pole; without it `handleEncryptedMessage` can't decrypt. Recommend keeping Baileys fallback until Signal phase passes interop tests.
- **Zig 0.16 Io** is still evolving — `compat.zig` already abstracts it.
- **Protobuf churn** — pin `proto` at same commit as whatsmeow Go mod.
- **SQLite WAL** on network FS — document local `~/.local/share/zeptoclaw/` path only.

---

## 8. Quick reference — sizes

| source | size | Zig effort |
|--------|------|------------|
| client.go | 1066 | L — state machine + threads |
| store.go + sqlstore 1500 | M — straightforward sql |
| binary/* 600 | M — spec-heavy |
| handshake+noise 300 | M — crypto, testable |
| qrchan/pair/pair-code/pair-passkey ~1100 total | M — crypto + timers |
| appstate 1200 total | M — HMAC/CBC/lthash |
| signal (not audited) | XL — bind or port |

All native stubs at `src/channels/whatsapp/native/*.zig` today are `BUILD:0` placeholders — `BUILD:0` preserved until phased plan lands.
