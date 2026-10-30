# WhatsApp native (Zig)

Live WhatsApp transport. Pair with `zeptoclaw whatsapp pair`. Session store: `{auth_dir}/native.sqlite`.

See [./ARCHITECTURE.md](./ARCHITECTURE.md) for the whatsmeow → Zig map.

## Overview

Live WhatsApp multi-device transport in Zig (whatsmeow port): WebSocket upgrade (`ws_upgrade.zig`, `ws_client.zig`), WA connection header and Noise XX handshake (`noise_crypto.zig`, `noise_handshake.zig`, `handshake.zig`, `socket.zig`), length-prefixed frames (`framesocket.zig`), binary stanza codec (`binary.zig`, `tokens.zig`), protobuf payloads (`proto.zig`), QR pairing and ADV signatures (`pair.zig`, `qrcode.zig`), Signal 1:1 and sender-key groups (`signal.zig`, `signal_groups.zig`, `curve_sigs.zig`), stanza builders/parsers (`stanza.zig`), group metadata and fan-out (`groups.zig`), media upload/download (`media.zig`), encryption IQ helpers (`encrypt.zig`), JID utilities (`jid.zig`), app-state LTHash (`appstate.zig`), and the connection lifecycle client (`client.zig`, alias `client_native.zig:NativeClient`). SQLite persistence is opened through `store.zig` (schema and CRUD in [./store/README.md](./store/README.md)). Design map: [./ARCHITECTURE.md](./ARCHITECTURE.md).

## Interface

Column-0 `pub` symbols in this directory (excluding `store/`). Persistence types and SQL live under [./store/README.md](./store/README.md). Grouped by file.

### `appstate.zig`

- `appstate.zig:hash_size` — Port of whatsmeow/appstate/lthash — pointwise uint16 add/sub (mod 2^16) — over a 128-byte HKDF-SHA256 expansion of each mutation.
- `appstate.zig:LTHash` — `const` at line 9: `pub const LTHash = struct {`.

### `binary.zig`

- `binary.zig:DictVersion` — Binary TLV layer — port of whatsmeow/binary/{encoder,decoder,node,attrs,token} — DictVersion 3, WA binary framing (not XML on wire). 0x00 uncompressed / 0x02 zlib.
- `binary.zig:Tag` — Token tag types (token.go)
- `binary.zig:Content` — Node — WhatsApp binary node (XMPP-like stanza)
- `binary.zig:Node` — `const` at line 36: `pub const Node = struct {`.
- `binary.zig:marshal` — Memory: caller frees. Uncompressed WA binary (leading 0x00).
- `binary.zig:BinaryError` — `const` at line 101: `pub const BinaryError = error{ InvalidToken, InvalidNode, InvalidJIDType, OutOfMemory, EndOfStream };`.
- `binary.zig:Encoder` — Encoder — binaryEncoder{data []u8} with [0] uncompressed prefix
- `binary.zig:Decoder` — Decoder — port of whatsmeow binary/decoder.go (DictVersion 3)
- `binary.zig:unpack` — Memory: caller owns returned buffer (zlib-decoded or prefix-stripped copy).
- `binary.zig:decodeNode` — Memory: unpacks (0x00 / 0x02 prefix) then readNode. Caller owns Node; call deinit.

### `client.zig`

- `client.zig:InboundMessage` — Decrypted chat message handed to the channel. Memory: receiver calls deinit.
- `client.zig:Event` — One server frame → one event (see `Client.poll`).
- `client.zig:Client` — `const` at line 137: `pub const Client = struct {`.

### `client_native.zig`

- `client_native.zig:NativeClient` — Facade over `client.zig` for WhatsAppChannel.use_native. Pairing IQ + Noise — connect live here; sendText still needs a Signal session with the peer.

### `curve_sigs.zig`

- `curve_sigs.zig:sign` — Sign `message` with an X25519 private key. `random` is 64 bytes of nonce — (libsignal uses CSPRNG; tests may pass zeros).
- `curve_sigs.zig:verify` — Verify `signature` over `message` with an X25519 (Montgomery) public key.

### `encrypt.zig`

- `encrypt.zig:server_jid` — WhatsApp `xmlns=encrypt` prekey IQ (whatsmeow FetchKeys). — GET: `<iq xmlns=encrypt type=get><key><user jid=…/></key></iq>` — RESULT: `<iq><list><user jid=…><registration/><identity/><skey>…</skey></user></list></iq>`
- `encrypt.zig:beUint` — function `beUint`.
- `encrypt.zig:writeBe` — function `writeBe`.
- `encrypt.zig:ParsedUser` — `const` at line 31: `pub const ParsedUser = struct {`.
- `encrypt.zig:parseUser` — Parse one `<user>` from an encrypt IQ result. Slices alias the node.
- `encrypt.zig:encodeEncryptGet` — Memory: caller frees.
- `encrypt.zig:encodeEncryptResult` — Fake server result for tests. Memory: caller frees.
- `encrypt.zig:isEncryptResult` — function `isEncryptResult`.

### `framesocket.zig`

- `framesocket.zig:FrameSocket` — First send prefixes WA\x06\x03; later sends are 3-byte BE length + payload. — Incoming websocket payloads are 3-byte length + payload (no WA header).

### `groups.zig`

- `groups.zig:buildGroupInfoQuery` — whatsmeow `getGroupInfo` (wm2_group.go:658) → `sendGroupIQ(iqGet, jid, — <query request="interactive">)`; xmlns goes on the `<iq>` (wm_request.go:119), — not on the `<query>`. WhatsApp web `groupMetadata` (Socket/grou...
- `groups.zig:Participant` — One `<participant>` of a `<group>`/`<query>` element. `jid` is the wire attr — verbatim; `lid` follows WhatsApp web (groups.js:316): ...
- `groups.zig:GroupInfo` — Group metadata as reported by `w:g2`. Every string is an allocator-owned dupe.
- `groups.zig:parseGroupInfo` — Parse a group-info IQ result (or a bare `<group>` / `<query>` element). Handles — both attribute spellings: current `w:g2` (`s_o`/`s_t`, whatsmeow wm2_group.go:741) — and the legacy `subject-owner`/`subject-time` pair...
- `groups.zig:adString` — `user.agent@server`         -> raw_agent A, device 0 — `server` (no `@`)           -> user "", server "server" — `a@b@c@server`              -> server stops at the second `@` (Go splits on `@` — and only ever reads pa...
- `groups.zig:participantListHashV2` — Exact port of whatsmeow `participantListHashV2` (wm2_send.go:682): — `ADString()` every participant device JID, sort bytewise, sha256 the concatenation — (no separator), then `"2:" ++ base64.RawStdEncoding(hash[:6])` ...
- `groups.zig:GroupMessageOpts` — Inputs for `groups.zig:buildGroupMessageNode`: message id, group JID, own device JIDs to drop from the fanout, addressing mode, participant device JIDs, and the skmsg ciphertext.
- `groups.zig:buildGroupMessageNode` — Assemble the exact whatsmeow `sendGroup` stanza: — `<message id to type [addressing_mode] [t] [notify] phash>` with children — `<participants><to jid><enc v="2" type="pkmsg|msg">skdm-ct</enc></to>…</participants>`, — ...

### `handshake.zig`

- `handshake.zig:clientHelloBytes` — Noise_XX_25519_AESGCM_SHA256 handshake framing + crypto driver. — Port of whatsmeow/handshake.go doHandshake — protobuf + Mix/Decrypt/Encrypt only. — No socket I/O. — Memory: caller frees with allocator. HandshakeMess...
- `handshake.zig:parseServerHello` — Memory: caller frees `static_ct` and `payload_ct` with allocator.
- `handshake.zig:clientFinishBytes` — Memory: caller frees with allocator. HandshakeMessage.clientFinish nested.
- `handshake.zig:HandshakeCryptoResult` — `const` at line 41: `pub const HandshakeCryptoResult = struct {`.
- `handshake.zig:runHandshakeCrypto` — Drive NoiseHandshake Mix/Decrypt/Encrypt for the client half of Noise XX. — `server_hello` is the parsed ServerHello parts (ciphertext). No socket. — Memory: caller deinit()s the result.
- `handshake.zig:HandshakeKeys` — `const` at line 110: `pub const HandshakeKeys = struct {`.
- `handshake.zig:doHandshake` — Drive the 3-message Noise XX handshake over a frame transport. — `sock` must provide `sendFrame([]const u8) !void` and `recvFrameAlloc() ![]u8` — (NoiseSocket or a test mock). Cert-chain verify is left to the caller. ...
- `handshake.zig:MockSock` — `const` at line 150: `pub const MockSock = struct {`.

### `jid.zig`

- `jid.zig:atIndex` — Index of `@` in a JID, or null.
- `jid.zig:server` — function `server`.
- `jid.zig:userDevice` — function `userDevice`.
- `jid.zig:user` — function `user`.
- `jid.zig:device` — function `device`.
- `jid.zig:isLid` — function `isLid`.
- `jid.zig:isPn` — function `isPn`.
- `jid.zig:signalId` — Signal protocol address string (`user.device`, or just `user` when device is 0). — Memory: caller frees.
- `jid.zig:format` — Memory: caller frees. Device 0 omits `:0`.
- `jid.zig:pnJid` — function `pnJid`.
- `jid.zig:lidJid` — function `lidJid`.

### `media.zig`

- `media.zig:media_hmac_length` — Truncated HMAC length appended to media ciphertext (whatsmeow — `mediaHMACLength`, WhatsApp web `hmac.digest().slice(0, 10)`).
- `media.zig:hkdf_expand_length` — HKDF expansion length (WhatsApp web `hkdf(buffer, 112, ...)`, whatsmeow — `hkdfutil.SHA256(mediaKey, nil, info, 112)`).
- `media.zig:mmg_host` — Default media download host (WhatsApp web `DEF_HOST`).
- `media.zig:Kind` — Media classes with their per-type key/info strings.
- `media.zig:Keys` — Keys derived from a 32-byte media key.
- `media.zig:deriveKeys` — function `deriveKeys`.
- `media.zig:decryptMedia` — Decrypt an encrypted media blob (ciphertext || 10-byte HMAC). The — returned slice is allocated with `alloc`; caller frees.
- `media.zig:encryptMedia` — Encrypt `plaintext` into an upload-ready blob (deterministic: the IV is — derived from the media key, matching whatsmeow `Upload` and WhatsApp web — `encryptedStream` for a fixed key). The returned slice is allocated ...
- `media.zig:buildDownloadUrl` — Build the download URL exactly as WhatsApp web `downloadContentFromMessage`: — absolute `https://mmg.whatsapp.net/...` urls pass through, a leading-'/' — directPath gets the host prefix. `kind` does not affect the URL...
- `media.zig:Transport` — Minimal HTTP vtable the parent backs with its own socket/TLS stack. — Contract: implementations return the response body as a slice whose — memory is owned by the transport (valid at least until the next call to — the...
- `media.zig:download` — Fetch + decrypt in one call. Caller frees the result.
- `media.zig:buildUploadUrl` — Upload URL per whatsmeow `rawUpload`. `file_enc_sha256` must be 32 — bytes. Caller frees the result.
- `media.zig:upload` — POST an already-encrypted blob (`encryptMedia` output) and parse the — server response. `file_enc_sha256` (32 bytes) is the SHA-256 of — `enc_file`; it forms the path/query token. Caller frees fields via — `UploadResu...
- `media.zig:UploadResult` — `const` at line 309: `pub const UploadResult = struct {`.
- `media.zig:parseUploadResponse` — Sniff the upload response: JSON (current servers — WhatsApp web and all — fetched whatsmeow revisions decode JSON) or the older XML form.
- `media.zig:parseUploadJson` — Parse `{"url":"...","direct_path":"...", ...}` (extra fields ignored).
- `media.zig:parseUploadXml` — Parse the classic upload response. Supports both child-text form — `<upload><url>..</url><direct_path>..</direct_path></upload>` (optionally — wrapped, e.g. in `<response>`) and attribute form — `<upload url=".." dire...

### `noise.zig`

- `noise.zig:WACertPubKey` — Ed25519 root public key for cert-chain intermediate verification (same bytes as `noise_crypto.zig:wa_cert_pub_key`).
- `noise.zig:NoiseStartPattern` — `const` at line 7: `pub const NoiseStartPattern = "Noise_XX_25519_AESGCM_SHA256\x00\x00\x00\x00";`.
- `noise.zig:WAPrefix` — `const` at line 8: `pub const WAPrefix: []const u8 = "WA";`.
- `noise.zig:WAVersion` — `const` at line 9: `pub const WAVersion: u8 = 6; // WAConnHeader version 6, DictVersion 3`.
- `noise.zig:NoiseHandshake` — `const` at line 11: `pub const NoiseHandshake = struct {`.

### `noise_crypto.zig`

- `noise_crypto.zig:noise_start_pattern` — Noise protocol name `Noise_XX_25519_AESGCM_SHA256` plus four trailing NUL bytes.
- `noise_crypto.zig:wa_magic_value` — constant `wa_magic_value`.
- `noise_crypto.zig:dict_version` — constant `dict_version`.
- `noise_crypto.zig:wa_conn_header` — constant `wa_conn_header`.
- `noise_crypto.zig:wa_origin` — constant `wa_origin`.
- `noise_crypto.zig:wa_ws_url` — constant `wa_ws_url`.
- `noise_crypto.zig:frame_max_size` — constant `frame_max_size`.
- `noise_crypto.zig:frame_length_size` — constant `frame_length_size`.
- `noise_crypto.zig:noise_handshake_timeout_ms` — constant `noise_handshake_timeout_ms`.
- `noise_crypto.zig:wa_cert_pub_key` — WACertPubKey — Ed25519 root public key for CertChain intermediate verification. — Port of handshake.go: WACertPubKey [32]byte{0x14,0x23,...}
- `noise_crypto.zig:wa_cert_issuer_serial` — constant `wa_cert_issuer_serial`.
- `noise_crypto.zig:sha256` — One-shot SHA-256 of the input; returns 32 bytes.
- `noise_crypto.zig:sha256Slice` — function `sha256Slice`.
- `noise_crypto.zig:hmacSha256` — HMAC-SHA256 (timing-safe not needed here but available via std).
- `noise_crypto.zig:generateIV` — Generate 12-byte AEAD IV from u32 counter (big-endian at offset 8). — Matches Go generateIV.
- `noise_crypto.zig:KeyPair` — X25519 keypair with clamping (exactly as whatsmeow/util/keys KeyPair).
- `noise_crypto.zig:hkdfExtractExpand` — HKDF-SHA256 extract+expand producing 64 bytes split into write[32] + read[32]. — Mirrors Go's extractAndExpand(salt, data) using hkdf.New(sha256, data, salt, nil).
- `noise_crypto.zig:aesGcmSeal` — AES-256-GCM seal: c = Enc(key, nonce, plaintext, ad); caller provides buf of len plaintext+16.
- `noise_crypto.zig:aesGcmOpen` — AES-256-GCM open: m = Dec(key, nonce, ciphertext||tag, ad); ciphertextAndTag = ciphertext+16
- `noise_crypto.zig:sealAlloc` — Convenience seal that allocates.
- `noise_crypto.zig:verifyEd25519` — Ed25519 verify (WA cert chain). Returns error.SignatureVerificationFailed on fail.

### `noise_handshake.zig`

- `noise_handshake.zig:NoiseHandshake` — Noise_XX_25519_AESGCM_SHA256 handshake — port of whatsmeow/socket/noisehandshake.go — Only crypto; no I/O. Caller drives the 3-message WA handshake (see handshake.zig).

### `pair.zig`

- `pair.zig:server_jid` — Port of whatsmeow/{pair,qrchan,pair-code}.go — QR + pair-device IQ + pair-success HMAC. — QR + pair-device IQ used by the native WhatsApp client.
- `pair.zig:PairClientType` — `const` at line 11: `pub const PairClientType = enum {`.
- `pair.zig:default_client_type` — Matches DeviceProps.platform_type=CHROME (WhatsApp web ubuntu/Chrome companion).
- `pair.zig:adv_account_sig_prefix` — constant `adv_account_sig_prefix`.
- `pair.zig:adv_device_sig_prefix` — constant `adv_device_sig_prefix`.
- `pair.zig:adv_hosted_account_sig_prefix` — constant `adv_hosted_account_sig_prefix`.
- `pair.zig:adv_hosted_device_sig_prefix` — constant `adv_hosted_device_sig_prefix`.
- `pair.zig:makeQRData` — WhatsApp Linked Devices camera comma-splits the QR payload, same as — WhatsApp web 6.7 / web.whatsapp.com: `ref,noiseB64,identityB64,advB64`. — A `wa.me` URL prefix makes the first field an invalid ref and the phone —...
- `pair.zig:qrCodesFromPairDevice` — Memory: caller frees each code and the slice.
- `pair.zig:encodeIqResult` — Empty IQ result acknowledging pair-device. Memory: caller frees.
- `pair.zig:encodePairError` — IQ error for failed pair-success. Memory: caller frees.
- `pair.zig:encodePairDeviceSign` — pair-device-sign confirmation. Memory: caller frees.
- `pair.zig:hmacPairDetails` — function `hmacPairDetails`.
- `pair.zig:hmacMatches` — function `hmacMatches`.
- `pair.zig:verifyAccountSignature` — function `verifyAccountSignature`.
- `pair.zig:generateDeviceSignature` — Device signature over (prefix || details || identity.Pub || accountSignatureKey).
- `pair.zig:PairDeviceEvent` — `const` at line 225: `pub const PairDeviceEvent = struct {`.
- `pair.zig:handlePairDevice` — Parse a pair-device IQ, ACK it, and build QR strings.
- `pair.zig:PairSuccessParts` — `const` at line 259: `pub const PairSuccessParts = struct {`.
- `pair.zig:parsePairSuccess` — function `parsePairSuccess`.

### `proto.zig`

- `proto.zig:writeVarint` — function `writeVarint`.
- `proto.zig:writeTag` — function `writeTag`.
- `proto.zig:writeBytes` — function `writeBytes`.
- `proto.zig:writeVarintField` — function `writeVarintField`.
- `proto.zig:writeBoolField` — function `writeBoolField`.
- `proto.zig:writeSfixed32` — function `writeSfixed32`.
- `proto.zig:writeDouble` — function `writeDouble`.
- `proto.zig:readVarint` — function `readVarint`.
- `proto.zig:readBytes` — Slice aliases `data`. Does not allocate.
- `proto.zig:skipField` — function `skipField`.
- `proto.zig:HandshakeMessage` — ClientHello  field 1 ephemeral — HandshakeMessage.clientHello  = 2 — ServerHello  ephemeral=1 static=2 payload=3 — HandshakeMessage.serverHello  = 3 — ClientFinish static=1 payload=2 — HandshakeMessage.clientFinish = ...
- `proto.zig:AppVersion` — connectType=12 connectReason=13 device=18 devicePairingData=19 pull=33 — UserAgent: platform=1 appVersion=2 mcc=3 mnc=4 osVersion=5 manufacturer=6 — device=7 osBuildNumber=8 releaseChannel=10 localeLanguage=11 localeC...
- `proto.zig:UserAgent` — `const` at line 301: `pub const UserAgent = struct {`.
- `proto.zig:WebInfo` — `const` at line 337: `pub const WebInfo = struct {`.
- `proto.zig:DevicePairingRegistrationData` — `const` at line 349: `pub const DevicePairingRegistrationData = struct {`.
- `proto.zig:ClientPayload` — `const` at line 375: `pub const ClientPayload = struct {`.
- `proto.zig:CertChain` — `const` at line 420: `pub const CertChain = struct {`.
- `proto.zig:DeviceProps` — waCompanionReg.DeviceProps: os=1 version=2 platformType=3 requireFullSync=4. — PlatformType: UNKNOWN=0 CHROME=1 FIREFOX=2 ... DESKTOP=7.
- `proto.zig:ADVSignedDeviceIdentityHMAC` — ADVSignedDeviceIdentityHMAC: details=1 HMAC=2 accountType=3 — ADVSignedDeviceIdentity...
- `proto.zig:ADVSignedDeviceIdentity` — `const` at line 600: `pub const ADVSignedDeviceIdentity = struct {`.
- `proto.zig:ADVDeviceIdentity` — `const` at line 639: `pub const ADVDeviceIdentity = struct {`.
- `proto.zig:MessageKey` — pad: 1–15 bytes of value=length (whatsmeow padMessage). Unpad for enc v=2. — ...
- `proto.zig:Geo` — `const` at line 767: `pub const Geo = struct { lat: f64, lon: f64 };`.
- `proto.zig:Media` — image 3{url=1,mimetype=2,caption=3,fileSha256=4,fileLength=5,height=6,width=7, — mediaKey=8,fileEncSha256=9,directPath=11}; video 9{url=1,mimetype=2,fileSha256=3, — fileLength=4,seconds=5,mediaKey=6,caption=7,height=9...
- `proto.zig:SenderKeyDistribution` — Message{senderKeyDistributionMessage=2{groupId=1, axolotlSenderKeyDistributionMessage=2}}.
- `proto.zig:Message` — `const` at line 1157: `pub const Message = struct {`.
- `proto.zig:ConversationMessage` — `const` at line 1681: `pub const ConversationMessage = struct {`.
- `proto.zig:padMessage` — Memory: caller frees. `pad_len` must be 1..=15.
- `proto.zig:padMessageRandom` — function `padMessageRandom`.
- `proto.zig:unpadMessage` — Alias into `plaintext` (no alloc). Version 3 is unpadded.

### `qrcode.zig`

- `qrcode.zig:Matrix` — `const` at line 558: `pub const Matrix = struct {`.
- `qrcode.zig:encode` — Memory: caller deinit.
- `qrcode.zig:renderUtf8` — Memory: caller frees.
- `qrcode.zig:renderAscii` — Memory: caller frees.

### `signal.zig`

- `signal.zig:MessageKeys` — `const` at line 17: `pub const MessageKeys = struct {`.
- `signal.zig:skipped_capacity` — Inline skipped-message-key cache (libsignal ReceiverChain keys). Oldest evicted.
- `signal.zig:max_skip` — Refuse to derive more than this many keys for one ciphertext (libsignal MAX_SKIP).
- `signal.zig:session_ser_version` — constant `session_ser_version`.
- `signal.zig:Session` — `const` at line 38: `pub const Session = struct {`.
- `signal.zig:aesCbcEncrypt` — function `aesCbcEncrypt`.
- `signal.zig:aesCbcDecrypt` — function `aesCbcDecrypt`.
- `signal.zig:djb_type_byte` — constant `djb_type_byte`.
- `signal.zig:encodeDjb` — function `encodeDjb`.
- `signal.zig:parseDjb` — function `parseDjb`.
- `signal.zig:PreKeyBundle` — `const` at line 656: `pub const PreKeyBundle = struct {`.
- `signal.zig:PreKeyHeader` — `const` at line 666: `pub const PreKeyHeader = struct {`.
- `signal.zig:LocalKeys` — `const` at line 674: `pub const LocalKeys = struct {`.
- `signal.zig:InitiateResult` — `const` at line 682: `pub const InitiateResult = struct {`.
- `signal.zig:initiateFromBundle` — Alice: X3DH against Bob's signed prekey (and optional one-time), then init ratchet.
- `signal.zig:acceptPreKey` — Bob: consume Alice's PreKey WhisperMessage header and init as receiver.
- `signal.zig:encodePreKeyMessage` — Memory: caller frees. Version byte 0x33 + protobuf (no outer MAC).
- `signal.zig:ParsedPreKey` — `const` at line 767: `pub const ParsedPreKey = struct {`.
- `signal.zig:decodePreKeyMessage` — `whisper` aliases `blob`.

### `signal_groups.zig`

- `signal_groups.zig:current_version` — CiphertextMessage.CURRENT_VERSION; SKM and SKDM both carry (3 << 4) | 3.
- `signal_groups.zig:version_byte` — constant `version_byte`.
- `signal_groups.zig:signature_length` — SenderKeyMessage.SIGNATURE_LENGTH.
- `signal_groups.zig:max_message_keys` — SenderKeyState.MAX_MESSAGE_KEYS.
- `signal_groups.zig:max_states` — SenderKeyRecord.MAX_STATES.
- `signal_groups.zig:max_skip` — GroupCipher.getSenderKey future-iteration window.
- `signal_groups.zig:key_len` — libsignal chain seed, message-key seed and signing key width.
- `signal_groups.zig:DeviceAddress` — libsignal `ProtocolAddress`: sender JID plus device id.
- `signal_groups.zig:SenderKeyName` — SenderKeyName: group + sender. `serialize()` matches the JS store key — (`"<groupId>::<sender.id>::<sender.deviceId>"`); our store keeps the same triple as — separate columns (see `store.zig`).
- `signal_groups.zig:SenderMessageKey` — HKDF-expanded AES material (IV, cipher key) plus the seed it came from; the record persists the seed and re-derives the expansion on load.
- `signal_groups.zig:SenderChainKey` — SenderChainKey: iteration counter plus 32-byte chain seed.
- `signal_groups.zig:SenderKeyState` — One sender's chain, signing pair, and skipped (staged) message keys; `signing_public` is the bare 32-byte Curve25519 point and the wire form re-adds the 0x05 type byte (`signal.encodeDjb`).
- `signal_groups.zig:SenderKeyRecord` — Up to `max_states` sender-key states, newest first; the serialized blob is only read back by this module.
- `signal_groups.zig:SenderKeyDistributionMessage` — Parsed SKDM (`[version] + proto{id, iteration, chainKey, signingKey}`), the payload of the inner `Message.sender_key_distribution`.
- `signal_groups.zig:SenderKeyMessage` — Parsed SenderKeyMessage. `ciphertext` and `signed` alias the buffer given to `parse`.
- `signal_groups.zig:encodeSenderKeyMessage` — Encode a SenderKeyMessage: `[0x33] + proto{id, iteration, ciphertext} + 64-byte signature` — made with `signing_private` over the version+protobuf prefix. Memory: caller frees.
- `signal_groups.zig:generateSenderKeyId` — keyhelper.generateSenderKeyId: `randomInt(2147483647)`, from 8 random bytes.
- `signal_groups.zig:generateSenderKey` — keyhelper.generateSenderKey: 32 random chain-key bytes.
- `signal_groups.zig:generateSenderSigningKey` — keyhelper.generateSenderSigningKey: a Curve25519 pair (public travels 0x05-prefixed).
- `signal_groups.zig:processDistribution` — GroupSessionBuilder.process: adopt a peer's distributed sender key into `record`. The caller — persists the record afterwards (the JS does the same through its `storeSenderKey`).
- `signal_groups.zig:create` — GroupSessionBuilder.create: make sure the record holds a local sender-key state (generated — only when the record is empty, exactly like the JS) and return the — SenderKeyDistributionMessage bytes to hand to participa...
- `signal_groups.zig:ensureSenderKeyState` — The generation half of GroupSessionBuilder.create, for callers that own the record.
- `signal_groups.zig:distributionBytes` — The axolotl `SenderKeyDistributionMessage` for our own state. Memory: caller frees.
- `signal_groups.zig:getSenderKey` — GroupCipher.getSenderKey: ratchet the chain up to `iteration`, staging skipped keys.
- `signal_groups.zig:encrypt` — GroupCipher.encrypt over already-padded plaintext (pad with `proto.padMessageRandom`). — One chain step per message, signature nonce from `io`. Fails with `NoSenderKeyState` or — `NoSigningPrivateKey`. Memory: caller ...
- `signal_groups.zig:encryptWithSignatureRandom` — Deterministic `encrypt` (explicit 64-byte signature nonce), for tests and fixtures.
- `signal_groups.zig:decrypt` — GroupCipher.decrypt: verify the signature, ratchet to the message's iteration, then — AES-256-CBC. Returns the padded plaintext — unpad with `proto.unpadMessage`. — Fails with `UnknownSenderKeyId`, `BadSignature`, `Ol...

### `socket.zig`

- `socket.zig:FrameCipher` — Port of whatsmeow/socket/{framesocket,noisesocket}.go transport side: — WSS client + WA 3-byte length frames. Post-handshake AES-256-GCM lives here — (handshake Mix/Encrypt is in handshake.zig; AD is empty after Finis...
- `socket.zig:NoiseSocket` — `const` at line 37: `pub const NoiseSocket = struct {`.

### `stanza.zig`

- `stanza.zig:server_jid` — Binary stanza builders for chat messages (whatsmeow send.go / receipt.go / prekeys.go / user.go). — Ciphertext is Signal-layer; this only wraps it in `<message><enc/></message>`.
- `stanza.zig:EncType` — `const` at line 10: `pub const EncType = enum {`.
- `stanza.zig:encodeEncryptedMessage` — Memory: caller frees. Uncompressed WA binary node.
- `stanza.zig:receiptType` — function `receiptType`.
- `stanza.zig:EncPayload` — `const` at line 54: `pub const EncPayload = struct {`.
- `stanza.zig:parseEnc` — function `parseEnc`.
- `stanza.zig:encodeAck` — Memory: caller frees. whatsmeow sendAck: class=tag, to=from, optional participant/recipient/type.
- `stanza.zig:encodeReceipt` — Memory: caller frees. `<receipt to id [type] [t] [participant]/>`. — `t` is Unix seconds, required on explicit read/read-self receipts.
- `stanza.zig:encodePingIq` — Memory: caller frees. Keepalive: `<iq to=s.whatsapp.net type=get xmlns=w:p id><ping/></iq>`.
- `stanza.zig:encodeIqResult` — Memory: caller frees. `<iq type=result to id/>`.
- `stanza.zig:encodePassiveIq` — Memory: caller frees. whatsmeow SetPassive: `<iq xmlns=passive type=set to=s.whatsapp.net id><active/>|<passive/></iq>`.
- `stanza.zig:encodeMediaConnIq` — Memory: caller frees. `<iq xmlns=w:m type=set to=s.whatsapp.net id><media_conn/></iq>`.
- `stanza.zig:MediaConn` — `const` at line 204: `pub const MediaConn = struct {`.
- `stanza.zig:parseMediaConn` — Slices alias `node` attrs. Looks for `<media_conn auth ttl>` with a `<host hostname>`.
- `stanza.zig:encodePresence` — Memory: caller frees. `<presence type=… [name]/>`.
- `stanza.zig:encodeChatState` — Memory: caller frees. `<chatstate to=jid><composing|paused/></chatstate>`.
- `stanza.zig:PreKeyPub` — `const` at line 255: `pub const PreKeyPub = struct { id: u32, pub_key: [32]u8 };`.
- `stanza.zig:encodePreKeyUpload` — Memory: caller frees. whatsmeow uploadPreKeys: registration 4B BE, type 0x05, identity 32B raw, list of key, skey.
- `stanza.zig:encodePreKeyCountIq` — Memory: caller frees. `<iq xmlns=encrypt type=get to=s.whatsapp.net id><count/></iq>`.
- `stanza.zig:parsePreKeyCount` — function `parsePreKeyCount`.
- `stanza.zig:encodeUsyncDevices` — Memory: caller frees. whatsmeow GetUserDevices usync query.
- `stanza.zig:DeviceEntry` — Slices alias the parsed node. Memory: caller frees the returned slice.
- `stanza.zig:parseUsyncDevices` — Memory: caller frees the slice; DeviceEntry strings alias `node`.
- `stanza.zig:Participant` — `const` at line 448: `pub const Participant = struct { jid: []const u8, enc_type: EncType, ciphertext: []const u8 };`.
- `stanza.zig:encodeMessageMulti` — Memory: caller frees. `<message to id type=text [peer_recipient_pn]><participants>…</participants>[device-identity]</message>`. — `peer_recipient_pn` is the recipient's phone JID; required for LID-addressed 1:1 DMs — ...
- `stanza.zig:encodeRetryResend` — Memory: caller frees. Single-device resend of a message that got a — `<receipt type=retry>`: bare `<enc>` (no `<participants>` wrapper), — addressed directly at the retrying device with `device_fanout=false` — (whatsm...
- `stanza.zig:MessageInfo` — Strings alias `node`. Memory: caller frees `encs`.
- `stanza.zig:parseMessageInfo` — whatsmeow parseMessageSource + parseMessageInfo. Memory: caller frees `encs`.
- `stanza.zig:parseStreamErrorCode` — function `parseStreamErrorCode`.
- `stanza.zig:isServerPing` — function `isServerPing`.
- `stanza.zig:parseOfflineCount` — function `parseOfflineCount`.
- `stanza.zig:parseNotificationType` — function `parseNotificationType`.
- `stanza.zig:RetryKeys` — `const` at line 639: `pub const RetryKeys = struct {`.
- `stanza.zig:encodeRetryReceipt` — Memory: caller frees. whatsmeow sendRetryReceipt.

### `store.zig`

- `store.zig:sqlite_store` — handle (including ":memory:") and applies schema.pragmatic_pragmas + latest_schema. — Parent must add vendor/sqlite amalgamation to the zeptoclaw module — see sqlite.zig header.
- `store.zig:Device` — `const` at line 9: `pub const Device = sqlite.Device;`.
- `store.zig:Container` — `const` at line 10: `pub const Container = sqlite.Container;`.
- `store.zig:PreKeyRecord` — `const` at line 11: `pub const PreKeyRecord = sqlite.PreKeyRecord;`.
- `store.zig:Store` — `const` at line 13: `pub const Store = struct {`.

### `tokens.zig`

- `tokens.zig:dict_version` — Generated from whatsmeow binary/token/token.go DictVersion 3
- `tokens.zig:single_byte_tokens` — constant `single_byte_tokens`.
- `tokens.zig:double_byte_tokens` — constant `double_byte_tokens`.
- `tokens.zig:singleIndexOf` — function `singleIndexOf`.
- `tokens.zig:doubleIndexOf` — function `doubleIndexOf`.
- `tokens.zig:getSingleToken` — function `getSingleToken`.
- `tokens.zig:getDoubleToken` — function `getDoubleToken`.

### `ws_client.zig`

- `ws_client.zig:WsConfig` — FrameSocket / ws_client — skeleton for WhatsApp Web websocket. — Real path requires: Io.net.Stream + std.crypto.tls.Client + RFC6455 frames. — Today exposed as no-IO codec + WA header/frame packing; TLS/WS dial wired ...
- `ws_client.zig:encodeFrame` — WA frame packing — mirrors Go FrameSocket.SendFrame: — [optional header once] + 3-byte BE length + payload
- `ws_client.zig:Deframer` — Streaming deframer — mirrors Go FrameSocket.processData/frameComplete. — Caller feeds websocket message payloads; complete WA frames are returned.
- `ws_client.zig:WsOpcode` — Minimal RFC6455 frame codec helpers (masked client frames, unmasked server). — Big enough for the WA task; full spec deferred.
- `ws_client.zig:wsEncodeFrame` — function `wsEncodeFrame`.
- `ws_client.zig:wsDecodeHeader` — function `wsDecodeHeader`.
- `ws_client.zig:connectTls` — TLS-over-TCP connect helper signature (to be used by socket.zig). — Kept allocation-free; caller supplies read/write buffers sized min_buffer_len.
- `ws_client.zig:wsAcceptKey` — Compute Sec-WebSocket-Accept per RFC6455 §4.2.2.
- `ws_client.zig:wsGenKey` — Generate Sec-WebSocket-Key (16 random bytes base64 = 24 chars).

### `ws_upgrade.zig`

- `ws_upgrade.zig:default_host` — WebSocket upgrade over TCP+TLS for `wss://web.whatsapp.com/ws/chat`. — Port of coder/websocket + whatsmeow FrameSocket transport (RFC6455). —  — Zig 0.16 has no `std.Io.tls`; the TLS record layer is `std.crypto.tls.Cl...
- `ws_upgrade.zig:default_path` — constant `default_path`.
- `ws_upgrade.zig:default_origin` — constant `default_origin`.
- `ws_upgrade.zig:default_port` — constant `default_port`.
- `ws_upgrade.zig:ParsedUrl` — `const` at line 17: `pub const ParsedUrl = struct {`.
- `ws_upgrade.zig:ParsedUpgrade` — `const` at line 24: `pub const ParsedUpgrade = struct {`.
- `ws_upgrade.zig:parseWssUrl` — Parse `wss://host[:port]/path` (slices alias `url`).
- `ws_upgrade.zig:buildUpgradeRequest` — Memory: caller owns the returned request bytes (`allocator.free`).
- `ws_upgrade.zig:parseUpgradeResponse` — Parse an HTTP/1.1 upgrade response. `accept` aliases `bytes`.
- `ws_upgrade.zig:verifyAccept` — function `verifyAccept`.
- `ws_upgrade.zig:performUpgrade` — RFC6455 upgrade on an already-decrypted (TLS or test) byte stream. — `raw_writer`: transport beneath `writer` (tls.Client.flush only encrypts into — its output buffer and never flushes it to the socket).
- `ws_upgrade.zig:WsClient` — `const` at line 285: `pub const WsClient = struct {`.

## Invariants

- `binary.zig:DictVersion` — wire dictionary version is 3 (`tokens.zig:dict_version`).
- `noise_crypto.zig:wa_conn_header` — four-byte prefix `WA` + magic 6 + dict version 3 on every connection.
- `noise_crypto.zig:noise_start_pattern` — Noise protocol name matches WhatsApp `Noise_XX_25519_AESGCM_SHA256` with four trailing NUL bytes.
- `signal.zig:max_skip` — Double Ratchet forward jumps are capped at 2000 message keys per session.
- `signal_groups.zig:max_skip` — Sender-key chain forward jumps use the same 2000 cap.
- `signal_groups.zig:max_states` — At most five sender-key states retained per `SenderKeyRecord`.
- `client.zig:Client` — `write_mu` serializes Noise socket writes; `state_mu` guards sessions and store-backed state from poll and send paths.
- `client.zig:Client` — Automatic retry-receipt resend stops after `max_auto_retries` (5) per cached outbound message id.
- `pair.zig:hmacMatches` — Pair-device HMAC must match `hmacPairDetails` over the ADV container before signatures are checked.
- `encrypt.zig:isEncryptResult` — Only IQ results tagged as encrypt responses are parsed for device bundles.
- `jid.zig:device` — Missing `:device` in a JID parses as device 0.
- `media.zig:media_hmac_length` — Trailing HMAC on encrypted media blobs is 10 bytes.
- `stanza.zig:isServerPing` — Server `<iq xmlns="urn:xmpp:ping">` stanzas are answered without entering application handlers.
- `ws_upgrade.zig:verifyAccept` — WebSocket accept must match RFC 6455 SHA-1 of client key + magic GUID.

## Side Effects

- `ws_upgrade.zig:performUpgrade` — TLS TCP connect, HTTP GET upgrade, reads 101 response headers.
- `ws_client.zig:connectTls` — Opens TLS socket and completes WebSocket framing on the wire.
- `handshake.zig:doHandshake` — Exchanges Noise handshake messages on the frame socket until transport keys are derived.
- `socket.zig:NoiseSocket` — Encrypts/decrypts length-prefixed frames with AES-GCM after handshake (`socket.zig:FrameCipher`).
- `framesocket.zig:FrameSocket` — Reads/writes 3-byte big-endian frame lengths capped by `noise_crypto.zig:frame_max_size`.
- `client.zig:Client` — `connect`/`poll`/`sendText` perform network I/O, SQLite via optional `store.zig:Store`, and spawn keepalive/retry worker threads.
- `store.zig:Store.open` — Opens `{auth_dir}/native.sqlite`, applies pragmas and DDL from the store package (see [./store/README.md](./store/README.md)).
- `store.zig:Store.putDevice` — Writes device row then WAL checkpoint through the inner container.
- `pair.zig:handlePairDevice` — Emits marshaled IQ responses on the open Noise socket during QR pairing.
- `media.zig:download` / `media.zig:upload` — HTTPS GET/POST to `mmg.whatsapp.net` (or `media.zig:Transport` override) with decrypted/plaintext buffers allocated for callers.
- `binary.zig:marshal` / `binary.zig:unpack` / `binary.zig:decodeNode` — Allocate encoded nodes or zlib-expanded copies; callers free via `binary.zig:Node.deinit`.
- `signal.zig:Session` — Mutates ratchet state and may persist serialized sessions through the client's store hooks on encrypt/decrypt.
- `signal_groups.zig:SenderKeyRecord` — Updates in-memory sender-key state used for group decrypt/encrypt paths.
- `stanza.zig:encodeAck` / `stanza.zig:encodeReceipt` — Allocate marshaled stanza bytes sent immediately by the client write path.

## Verification

- Run: `zig build test`
