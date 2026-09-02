//! Signal sender-key (group) cipher — port of Baileys' local libsignal Group
//! implementation (`node_modules/@whiskeysockets/baileys/lib/Signal/Group/*.js`) on top of the
//! libsignal `SenderKeyRecordStructure` protobuf.
//!
//! Wire formats pinned against the JS (where the JS and a spec disagree, the JS wins):
//!   SenderKeyDistributionMessage = [0x33] + proto{id=1, iteration=2, chainKey=3, signingKey=4}
//!     — chainKey is the 32-byte chain seed; signingKey is the 33-byte 0x05-prefixed Curve25519
//!     public key (libsignal `prefixKeyInPublicKey`, `keyhelper.generateSenderSigningKey`).
//!   SenderKeyMessage = [0x33] + proto{id=1, iteration=2, ciphertext=3} + 64 raw signature bytes
//!     — WhatsApp's SenderKeyMessage proto has *no* signature field: the 64 bytes trail the
//!     protobuf and are Ed25519-over-X25519 (`curve_sigs`) over (version byte || protobuf),
//!     keyed by the 32-byte signing private key.
//!   SenderKeyRecord blob = proto{senderKeyStates=1: [{senderKeyId=1,
//!     senderChainKey=2 {iteration=1, seed=2}, senderSigningKey=3 {public=1, private=2},
//!     senderMessageKeys=4 {iteration=1, seed=2}}]} — what `store.putSenderKey` persists.
//!
//! Ratchet and derivation follow `sender-chain-key.js` / `sender-message-key.js`:
//!   message seed = HMAC-SHA256(chainKey, 0x01), next chain = HMAC-SHA256(chainKey, 0x02),
//!   HKDF-SHA256(ikm=seed, salt=32 zero bytes, info="WhisperGroup", 48 bytes)
//!   -> iv = out[0..16], cipher key = out[16..48].
//! `GroupCipher.getSenderKey` semantics — including Baileys asking for `iteration + 1` on every
//! encrypt after the first, which stages the key it skips — are reproduced exactly so both
//! directions interoperate with a Baileys/phone peer (cross-checked in the tests below).
//!
//! Failure vocabulary (functions carry inferred error sets, as elsewhere in the native port):
//! `InvalidMessage`, `InvalidChainKey`, `InvalidSigningKey` for malformed input;
//! `NoSenderKeyState`, `UnknownSenderKeyId`, `NoSigningPrivateKey` for missing state;
//! `BadSignature`, `OldCounter`, `TooManySkipped`, `DecryptFailed` for cipher-level rejection;
//! plus `OutOfMemory`.

const std = @import("std");
const proto = @import("proto.zig");
const signal = @import("signal.zig");
const curve_sigs = @import("curve_sigs.zig");
const nc = @import("noise_crypto.zig");

const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// CiphertextMessage.CURRENT_VERSION; SKM and SKDM both carry (3 << 4) | 3.
pub const current_version: u8 = 3;
pub const version_byte: u8 = (current_version << 4) | current_version;
/// SenderKeyMessage.SIGNATURE_LENGTH.
pub const signature_length: usize = 64;
/// SenderKeyState.MAX_MESSAGE_KEYS.
pub const max_message_keys: usize = 2000;
/// SenderKeyRecord.MAX_STATES.
pub const max_states: usize = 5;
/// GroupCipher.getSenderKey future-iteration window.
pub const max_skip: u32 = 2000;
/// libsignal chain seed, message-key seed and signing key width.
pub const key_len: usize = 32;

/// `SenderMessageKey`: `deriveSecrets(seed, Buffer.alloc(32), Buffer.from('WhisperGroup'))`.
const hkdf_salt: [key_len]u8 = [_]u8{0} ** key_len;
const hkdf_info = "WhisperGroup";
const message_key_seed: [1]u8 = .{0x01};
const chain_key_seed: [1]u8 = .{0x02};

// --------------------------------------------------------------------------------------------
// Names (sender-key-name.js)
// --------------------------------------------------------------------------------------------

/// libsignal `ProtocolAddress`: sender JID plus device id.
pub const DeviceAddress = struct {
    id: []const u8,
    device_id: u32,

    pub fn eql(self: DeviceAddress, other: DeviceAddress) bool {
        return self.device_id == other.device_id and std.mem.eql(u8, self.id, other.id);
    }
};

/// SenderKeyName: group + sender. `serialize()` matches the JS store key
/// (`"<groupId>::<sender.id>::<sender.deviceId>"`); our store keeps the same triple as
/// separate columns (see `store.zig`).
pub const SenderKeyName = struct {
    group_id: []const u8,
    sender: DeviceAddress,

    /// Memory: caller frees.
    pub fn serialize(self: SenderKeyName, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}::{s}::{d}",
            .{ self.group_id, self.sender.id, self.sender.device_id },
        );
    }

    pub fn eql(self: SenderKeyName, other: SenderKeyName) bool {
        return std.mem.eql(u8, self.group_id, other.group_id) and self.sender.eql(other.sender);
    }
};

// --------------------------------------------------------------------------------------------
// Keys (sender-chain-key.js, sender-message-key.js)
// --------------------------------------------------------------------------------------------

/// SenderMessageKey: HKDF-expanded AES material plus the seed it came from — the seed is what
/// the record persists, the expansion is re-derived on load (as in the JS).
pub const SenderMessageKey = struct {
    iteration: u32,
    seed: [key_len]u8,
    iv: [16]u8,
    cipher_key: [key_len]u8,

    pub fn init(iteration: u32, seed: [key_len]u8) SenderMessageKey {
        const prk = Hkdf.extract(&hkdf_salt, &seed);
        var okm: [48]u8 = undefined;
        Hkdf.expand(&okm, hkdf_info, prk);
        var out = SenderMessageKey{
            .iteration = iteration,
            .seed = seed,
            .iv = undefined,
            .cipher_key = undefined,
        };
        @memcpy(&out.iv, okm[0..16]);
        @memcpy(&out.cipher_key, okm[16..48]);
        return out;
    }
};

/// SenderChainKey: iteration counter plus 32-byte chain seed.
pub const SenderChainKey = struct {
    iteration: u32,
    seed: [key_len]u8,

    pub fn getSenderMessageKey(self: SenderChainKey) SenderMessageKey {
        return SenderMessageKey.init(self.iteration, derivative(&self.seed, &message_key_seed));
    }

    pub fn getNext(self: SenderChainKey) SenderChainKey {
        return .{ .iteration = self.iteration +% 1, .seed = derivative(&self.seed, &chain_key_seed) };
    }
};

/// `SenderChainKey.getDerivative(seed, key)` == `calculateMAC(key, seed)`.
fn derivative(key: *const [key_len]u8, seed: []const u8) [key_len]u8 {
    return nc.hmacSha256(key, seed);
}

// --------------------------------------------------------------------------------------------
// State (sender-key-state.js)
// --------------------------------------------------------------------------------------------

/// SenderKeyState: one sender's chain, signing pair and skipped (staged) message keys.
/// `signing_public` holds the bare 32-byte Curve25519 point; the wire form re-adds the 0x05
/// type byte (`signal.encodeDjb`).
pub const SenderKeyState = struct {
    key_id: u32,
    chain: SenderChainKey,
    signing_public: [key_len]u8,
    signing_private: ?[key_len]u8 = null,
    message_keys: std.ArrayList(SenderMessageKey) = .empty,

    pub fn deinit(self: *SenderKeyState, allocator: std.mem.Allocator) void {
        self.message_keys.deinit(allocator);
        self.message_keys = .empty;
    }

    pub fn hasSenderMessageKey(self: *const SenderKeyState, iteration: u32) bool {
        for (self.message_keys.items) |key| {
            if (key.iteration == iteration) return true;
        }
        return false;
    }

    /// addSenderMessageKey: append, keeping at most `max_message_keys` (JS `shift()`s oldest).
    pub fn addSenderMessageKey(
        self: *SenderKeyState,
        allocator: std.mem.Allocator,
        key: SenderMessageKey,
    ) !void {
        try self.message_keys.append(allocator, key);
        if (self.message_keys.items.len > max_message_keys) {
            _ = self.message_keys.orderedRemove(0);
        }
    }

    /// removeSenderMessageKey: pop the staged key for `iteration`, if held.
    pub fn removeSenderMessageKey(self: *SenderKeyState, iteration: u32) ?SenderMessageKey {
        for (self.message_keys.items, 0..) |key, i| {
            if (key.iteration == iteration) return self.message_keys.orderedRemove(i);
        }
        return null;
    }

    pub fn setSenderChainKey(self: *SenderKeyState, next: SenderChainKey) void {
        self.chain = next;
    }
};

// --------------------------------------------------------------------------------------------
// Record (sender-key-record.js over libsignal's SenderKeyRecordStructure)
// --------------------------------------------------------------------------------------------

/// SenderKeyRecord: up to `max_states` states, newest first (Baileys appends and reads the last
/// element — same state, and this blob is only ever read back by this module).
pub const SenderKeyRecord = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(SenderKeyState) = .empty,

    pub fn init(allocator: std.mem.Allocator) SenderKeyRecord {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SenderKeyRecord) void {
        for (self.states.items) |*state| state.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.states = .empty;
    }

    pub fn isEmpty(self: *const SenderKeyRecord) bool {
        return self.states.items.len == 0;
    }

    /// getSenderKeyState() — the state encryption uses (newest).
    pub fn getSenderKeyState(self: *SenderKeyRecord) ?*SenderKeyState {
        if (self.states.items.len == 0) return null;
        return &self.states.items[0];
    }

    /// getSenderKeyState(keyId) — the state decryption uses.
    pub fn getSenderKeyStateById(self: *SenderKeyRecord, key_id: u32) ?*SenderKeyState {
        for (self.states.items) |*state| {
            if (state.key_id == key_id) return state;
        }
        return null;
    }

    /// addSenderKeyState: receiver side (no signing private key); newest first, capped.
    pub fn addSenderKeyState(
        self: *SenderKeyRecord,
        key_id: u32,
        iteration: u32,
        chain_key: [key_len]u8,
        signing_public: [key_len]u8,
    ) !void {
        const state = SenderKeyState{
            .key_id = key_id,
            .chain = .{ .iteration = iteration, .seed = chain_key },
            .signing_public = signing_public,
        };
        try self.states.insert(self.allocator, 0, state);
        if (self.states.items.len > max_states) {
            if (self.states.pop()) |dropped| {
                var owned = dropped;
                owned.deinit(self.allocator);
            }
        }
    }

    /// setSenderKeyState: create side — replaces the record with a single local state.
    pub fn setSenderKeyState(
        self: *SenderKeyRecord,
        key_id: u32,
        iteration: u32,
        chain_key: [key_len]u8,
        signing_key: nc.KeyPair,
    ) !void {
        self.clear();
        const state = SenderKeyState{
            .key_id = key_id,
            .chain = .{ .iteration = iteration, .seed = chain_key },
            .signing_public = signing_key.pub_key,
            .signing_private = signing_key.priv_key,
        };
        try self.states.append(self.allocator, state);
    }

    pub fn clear(self: *SenderKeyRecord) void {
        for (self.states.items) |*state| state.deinit(self.allocator);
        self.states.clearRetainingCapacity();
    }

    /// SenderKeyRecordStructure protobuf — the blob `store.putSenderKey` persists.
    /// Memory: caller frees.
    pub fn serialize(self: *const SenderKeyRecord, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        for (self.states.items) |*state| {
            const body = try encodeStateStructure(allocator, state);
            defer allocator.free(body);
            try proto.writeBytes(&buf, allocator, 1, body);
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Parse a SenderKeyRecordStructure blob. Caller owns the record: `deinit` when done.
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !SenderKeyRecord {
        var record = SenderKeyRecord.init(allocator);
        errdefer record.deinit();
        var idx: usize = 0;
        while (idx < bytes.len) {
            const tag = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
            const field: u32 = @intCast(tag >> 3);
            const wire: u3 = @intCast(tag & 7);
            if (field != 1 or wire != 2) {
                proto.skipField(bytes, &idx, wire) catch return error.InvalidMessage;
                continue;
            }
            const body = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
            var state = try parseStateStructure(allocator, body);
            errdefer state.deinit(allocator);
            try record.states.append(allocator, state);
        }
        return record;
    }
};

fn encodeStateStructure(allocator: std.mem.Allocator, state: *const SenderKeyState) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buf.deinit(allocator);
    // senderKeyId = 1 — protobufjs emits it whenever the property exists, which Baileys'
    // structures always do (`senderKeyId: id || 0`), zero included.
    try proto.writeVarintField(&buf, allocator, 1, state.key_id);
    // senderChainKey = 2 { iteration = 1, seed = 2 }
    {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 2 + key_len);
        defer inner.deinit(allocator);
        try proto.writeVarintField(&inner, allocator, 1, state.chain.iteration);
        try proto.writeBytes(&inner, allocator, 2, &state.chain.seed);
        const body = try inner.toOwnedSlice(allocator);
        defer allocator.free(body);
        try proto.writeBytes(&buf, allocator, 2, body);
    }
    // senderSigningKey = 3 { public = 1, private = 2 }
    {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 2 + key_len + 2 + key_len);
        defer inner.deinit(allocator);
        const public = signal.encodeDjb(state.signing_public);
        try proto.writeBytes(&inner, allocator, 1, &public);
        if (state.signing_private) |priv| try proto.writeBytes(&inner, allocator, 2, &priv);
        const body = try inner.toOwnedSlice(allocator);
        defer allocator.free(body);
        try proto.writeBytes(&buf, allocator, 3, body);
    }
    // senderMessageKeys = 4 { iteration = 1, seed = 2 }, in staged order
    for (state.message_keys.items) |key| {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 2 + key_len);
        defer inner.deinit(allocator);
        try proto.writeVarintField(&inner, allocator, 1, key.iteration);
        try proto.writeBytes(&inner, allocator, 2, &key.seed);
        const body = try inner.toOwnedSlice(allocator);
        defer allocator.free(body);
        try proto.writeBytes(&buf, allocator, 4, body);
    }
    return buf.toOwnedSlice(allocator);
}

fn parseStateStructure(allocator: std.mem.Allocator, bytes: []const u8) !SenderKeyState {
    var state = SenderKeyState{
        .key_id = 0,
        .chain = .{ .iteration = 0, .seed = [_]u8{0} ** key_len },
        .signing_public = [_]u8{0} ** key_len,
    };
    var have_signing = false;
    errdefer state.deinit(allocator);
    var idx: usize = 0;
    while (idx < bytes.len) {
        const tag = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
        const field: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 7);
        switch (field) {
            1 => {
                if (wire != 0) return error.InvalidMessage;
                const v = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
                state.key_id = std.math.cast(u32, v) orelse return error.InvalidMessage;
            },
            2 => {
                if (wire != 2) return error.InvalidMessage;
                const body = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                state.chain = try parseChainKeyStructure(body);
            },
            3 => {
                if (wire != 2) return error.InvalidMessage;
                const body = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                const pair = try parseSigningKeyStructure(body);
                state.signing_public = pair.public;
                state.signing_private = pair.private;
                have_signing = true;
            },
            4 => {
                if (wire != 2) return error.InvalidMessage;
                const body = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                const key = try parseMessageKeyStructure(body);
                try state.message_keys.append(allocator, key);
            },
            else => try proto.skipField(bytes, &idx, wire),
        }
    }
    if (!have_signing) return error.InvalidSigningKey;
    return state;
}

fn parseChainKeyStructure(bytes: []const u8) !SenderChainKey {
    var chain = SenderChainKey{ .iteration = 0, .seed = [_]u8{0} ** key_len };
    var have_seed = false;
    var idx: usize = 0;
    while (idx < bytes.len) {
        const tag = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
        const field: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 7);
        switch (field) {
            1 => {
                if (wire != 0) return error.InvalidMessage;
                const v = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
                chain.iteration = std.math.cast(u32, v) orelse return error.InvalidMessage;
            },
            2 => {
                if (wire != 2) return error.InvalidMessage;
                const raw = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                if (raw.len != key_len) return error.InvalidChainKey;
                @memcpy(&chain.seed, raw);
                have_seed = true;
            },
            else => try proto.skipField(bytes, &idx, wire),
        }
    }
    if (!have_seed) return error.InvalidChainKey;
    return chain;
}

fn parseMessageKeyStructure(bytes: []const u8) !SenderMessageKey {
    var iteration: u32 = 0;
    var seed: ?[key_len]u8 = null;
    var idx: usize = 0;
    while (idx < bytes.len) {
        const tag = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
        const field: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 7);
        switch (field) {
            1 => {
                if (wire != 0) return error.InvalidMessage;
                const v = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
                iteration = std.math.cast(u32, v) orelse return error.InvalidMessage;
            },
            2 => {
                if (wire != 2) return error.InvalidMessage;
                const raw = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                if (raw.len != key_len) return error.InvalidChainKey;
                var buf: [key_len]u8 = undefined;
                @memcpy(&buf, raw);
                seed = buf;
            },
            else => try proto.skipField(bytes, &idx, wire),
        }
    }
    return SenderMessageKey.init(iteration, seed orelse return error.InvalidChainKey);
}

fn parseSigningKeyStructure(bytes: []const u8) !struct {
    public: [key_len]u8,
    private: ?[key_len]u8,
} {
    var public: ?[key_len]u8 = null;
    var private: ?[key_len]u8 = null;
    var idx: usize = 0;
    while (idx < bytes.len) {
        const tag = proto.readVarint(bytes, &idx) catch return error.InvalidMessage;
        const field: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 7);
        switch (field) {
            1 => {
                if (wire != 2) return error.InvalidMessage;
                const raw = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                public = signal.parseDjb(raw) catch return error.InvalidSigningKey;
            },
            2 => {
                if (wire != 2) return error.InvalidMessage;
                const raw = proto.readBytes(bytes, &idx) catch return error.InvalidMessage;
                if (raw.len != key_len) return error.InvalidSigningKey;
                var buf: [key_len]u8 = undefined;
                @memcpy(&buf, raw);
                private = buf;
            },
            else => try proto.skipField(bytes, &idx, wire),
        }
    }
    return .{ .public = public orelse return error.InvalidSigningKey, .private = private };
}

// --------------------------------------------------------------------------------------------
// SenderKeyDistributionMessage / SenderKeyMessage
// --------------------------------------------------------------------------------------------

/// Parsed SenderKeyDistributionMessage — the payload of the inner
/// `Message.sender_key_distribution` (`proto.zig SenderKeyDistribution.axolotl`).
pub const SenderKeyDistributionMessage = struct {
    version: u8 = version_byte,
    id: u32 = 0,
    iteration: u32 = 0,
    chain_key: [key_len]u8 = [_]u8{0} ** key_len,
    /// Bare Curve25519 point; the wire form carries the 0x05 type byte.
    signing_key: [key_len]u8 = [_]u8{0} ** key_len,

    /// Parse `[version] + proto{id, iteration, chainKey, signingKey}`.
    pub fn parse(bytes: []const u8) !SenderKeyDistributionMessage {
        if (bytes.len < 2) return error.InvalidMessage;
        var msg = SenderKeyDistributionMessage{ .version = bytes[0] };
        const body = bytes[1..];
        var idx: usize = 0;
        var have_chain = false;
        var have_signing = false;
        while (idx < body.len) {
            const tag = proto.readVarint(body, &idx) catch return error.InvalidMessage;
            const field: u32 = @intCast(tag >> 3);
            const wire: u3 = @intCast(tag & 7);
            switch (field) {
                1 => {
                    if (wire != 0) return error.InvalidMessage;
                    const v = proto.readVarint(body, &idx) catch return error.InvalidMessage;
                    msg.id = std.math.cast(u32, v) orelse return error.InvalidMessage;
                },
                2 => {
                    if (wire != 0) return error.InvalidMessage;
                    const v = proto.readVarint(body, &idx) catch return error.InvalidMessage;
                    msg.iteration = std.math.cast(u32, v) orelse return error.InvalidMessage;
                },
                3 => {
                    if (wire != 2) return error.InvalidMessage;
                    const raw = proto.readBytes(body, &idx) catch return error.InvalidMessage;
                    if (raw.len != key_len) return error.InvalidChainKey;
                    @memcpy(&msg.chain_key, raw);
                    have_chain = true;
                },
                4 => {
                    if (wire != 2) return error.InvalidMessage;
                    const raw = proto.readBytes(body, &idx) catch return error.InvalidMessage;
                    msg.signing_key = signal.parseDjb(raw) catch return error.InvalidSigningKey;
                    have_signing = true;
                },
                else => try proto.skipField(body, &idx, wire),
            }
        }
        if (!have_chain or !have_signing) return error.InvalidMessage;
        return msg;
    }

    /// `[0x33] + proto{id, iteration, chainKey, signingKey}` — the axolotl blob to wrap in
    /// `Message.encodeSenderKeyDistribution`. Memory: caller frees.
    pub fn serialize(
        self: *const SenderKeyDistributionMessage,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 4 + key_len + 34);
        defer buf.deinit(allocator);
        try proto.writeVarintField(&buf, allocator, 1, self.id);
        try proto.writeVarintField(&buf, allocator, 2, self.iteration);
        try proto.writeBytes(&buf, allocator, 3, &self.chain_key);
        const signing_key = signal.encodeDjb(self.signing_key);
        try proto.writeBytes(&buf, allocator, 4, &signing_key);
        var out = try allocator.alloc(u8, buf.items.len + 1);
        errdefer allocator.free(out);
        out[0] = self.version;
        @memcpy(out[1..], buf.items);
        return out;
    }
};

/// Parsed SenderKeyMessage. `ciphertext` and `signed` alias the buffer given to `parse`.
pub const SenderKeyMessage = struct {
    version: u8 = version_byte,
    id: u32 = 0,
    iteration: u32 = 0,
    ciphertext: []const u8 = &.{},
    signature: [signature_length]u8 = [_]u8{0} ** signature_length,
    /// version byte + protobuf: exactly the bytes the signature covers.
    signed: []const u8 = &.{},

    pub fn parse(bytes: []const u8) !SenderKeyMessage {
        if (bytes.len <= 1 + signature_length) return error.InvalidMessage;
        var msg = SenderKeyMessage{
            .version = bytes[0],
            .signed = bytes[0 .. bytes.len - signature_length],
        };
        @memcpy(&msg.signature, bytes[bytes.len - signature_length ..]);
        const body = msg.signed[1..];
        var idx: usize = 0;
        var have_id = false;
        var have_iteration = false;
        var have_ciphertext = false;
        while (idx < body.len) {
            const tag = proto.readVarint(body, &idx) catch return error.InvalidMessage;
            const field: u32 = @intCast(tag >> 3);
            const wire: u3 = @intCast(tag & 7);
            switch (field) {
                1 => {
                    if (wire != 0) return error.InvalidMessage;
                    const v = proto.readVarint(body, &idx) catch return error.InvalidMessage;
                    msg.id = std.math.cast(u32, v) orelse return error.InvalidMessage;
                    have_id = true;
                },
                2 => {
                    if (wire != 0) return error.InvalidMessage;
                    const v = proto.readVarint(body, &idx) catch return error.InvalidMessage;
                    msg.iteration = std.math.cast(u32, v) orelse return error.InvalidMessage;
                    have_iteration = true;
                },
                3 => {
                    if (wire != 2) return error.InvalidMessage;
                    msg.ciphertext = proto.readBytes(body, &idx) catch return error.InvalidMessage;
                    have_ciphertext = true;
                },
                else => try proto.skipField(body, &idx, wire),
            }
        }
        if (!have_id or !have_iteration or !have_ciphertext or msg.ciphertext.len == 0) {
            return error.InvalidMessage;
        }
        return msg;
    }

    /// Ed25519-over-X25519 check of the trailing 64 bytes over (version || protobuf).
    pub fn verifySignature(self: *const SenderKeyMessage, signing_public: [key_len]u8) !void {
        curve_sigs.verify(signing_public, self.signed, self.signature) catch return error.BadSignature;
    }
};

/// Encode a SenderKeyMessage: `[0x33] + proto{id, iteration, ciphertext} + 64-byte signature`
/// made with `signing_private` over the version+protobuf prefix. Memory: caller frees.
pub fn encodeSenderKeyMessage(
    allocator: std.mem.Allocator,
    id: u32,
    iteration: u32,
    ciphertext: []const u8,
    signing_private: [key_len]u8,
    random: [64]u8,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 1 + ciphertext.len + 16);
    errdefer buf.deinit(allocator);
    try buf.append(allocator, version_byte);
    try proto.writeVarintField(&buf, allocator, 1, id);
    try proto.writeVarintField(&buf, allocator, 2, iteration);
    try proto.writeBytes(&buf, allocator, 3, ciphertext);
    const signature = try curve_sigs.sign(signing_private, buf.items, random);
    try buf.appendSlice(allocator, &signature);
    return buf.toOwnedSlice(allocator);
}

// --------------------------------------------------------------------------------------------
// Group cipher (group_cipher.js) and session builder (group-session-builder.js)
// --------------------------------------------------------------------------------------------

/// keyhelper.generateSenderKeyId: `randomInt(2147483647)`.
pub fn generateSenderKeyId(io: std.Io) u32 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const wide = std.mem.readInt(u64, &raw, .little);
    return @intCast(wide % 2147483647);
}

/// keyhelper.generateSenderKey: 32 random chain-key bytes.
pub fn generateSenderKey(io: std.Io) [key_len]u8 {
    var seed: [key_len]u8 = undefined;
    io.random(&seed);
    return seed;
}

/// keyhelper.generateSenderSigningKey: a Curve25519 pair (public travels 0x05-prefixed).
pub fn generateSenderSigningKey(io: std.Io) nc.KeyPair {
    return nc.KeyPair.generate(io);
}

/// GroupSessionBuilder.process: adopt a peer's distributed sender key into `record`. The caller
/// persists the record afterwards (Baileys does the same through its `storeSenderKey`).
pub fn processDistribution(record: *SenderKeyRecord, skdm: []const u8) !void {
    const msg = try SenderKeyDistributionMessage.parse(skdm);
    try record.addSenderKeyState(msg.id, msg.iteration, msg.chain_key, msg.signing_key);
}

/// GroupSessionBuilder.create: make sure the record holds a local sender-key state (generated
/// only when the record is empty, exactly like the JS) and return the
/// SenderKeyDistributionMessage bytes to hand to participant devices. Memory: caller frees.
pub fn create(allocator: std.mem.Allocator, record: *SenderKeyRecord, io: std.Io) ![]u8 {
    if (record.isEmpty()) try ensureSenderKeyState(record, io);
    const state = record.getSenderKeyState() orelse return error.NoSenderKeyState;
    return distributionBytes(allocator, state);
}

/// The generation half of GroupSessionBuilder.create, for callers that own the record.
pub fn ensureSenderKeyState(record: *SenderKeyRecord, io: std.Io) !void {
    try record.setSenderKeyState(
        generateSenderKeyId(io),
        0,
        generateSenderKey(io),
        generateSenderSigningKey(io),
    );
}

/// The axolotl `SenderKeyDistributionMessage` for our own state. Memory: caller frees.
pub fn distributionBytes(
    allocator: std.mem.Allocator,
    state: *const SenderKeyState,
) ![]u8 {
    const msg = SenderKeyDistributionMessage{
        .id = state.key_id,
        .iteration = state.chain.iteration,
        .chain_key = state.chain.seed,
        .signing_key = state.signing_public,
    };
    return msg.serialize(allocator);
}

/// GroupCipher.getSenderKey: ratchet the chain up to `iteration`, staging skipped keys.
pub fn getSenderKey(
    allocator: std.mem.Allocator,
    state: *SenderKeyState,
    iteration: u32,
) !SenderMessageKey {
    var chain = state.chain;
    if (chain.iteration > iteration) {
        // Either a replay of a consumed iteration or a skipped key still held.
        if (state.removeSenderMessageKey(iteration)) |staged| return staged;
        return error.OldCounter;
    }
    if (iteration - chain.iteration > max_skip) return error.TooManySkipped;
    while (chain.iteration < iteration) {
        try state.addSenderMessageKey(allocator, chain.getSenderMessageKey());
        chain = chain.getNext();
    }
    const used = chain.getSenderMessageKey();
    state.setSenderChainKey(chain.getNext());
    return used;
}

/// GroupCipher.encrypt over already-padded plaintext (pad with `proto.padMessageRandom`).
/// One chain step per message, signature nonce from `io`. Fails with `NoSenderKeyState` or
/// `NoSigningPrivateKey`. Memory: caller frees.
pub fn encrypt(
    allocator: std.mem.Allocator,
    record: *SenderKeyRecord,
    padded_plaintext: []const u8,
    io: std.Io,
) ![]u8 {
    var random: [64]u8 = undefined;
    io.random(&random);
    return encryptWithSignatureRandom(allocator, record, padded_plaintext, random);
}

/// Deterministic `encrypt` (explicit 64-byte signature nonce), for tests and fixtures.
pub fn encryptWithSignatureRandom(
    allocator: std.mem.Allocator,
    record: *SenderKeyRecord,
    padded_plaintext: []const u8,
    random: [64]u8,
) ![]u8 {
    const state = record.getSenderKeyState() orelse return error.NoSenderKeyState;
    // Checked before ratcheting so a failed call cannot burn chain keys (JS throws after the
    // ratchet but before storeSenderKey, i.e. also unpersisted).
    const private = state.signing_private orelse return error.NoSigningPrivateKey;
    const iteration = state.chain.iteration;
    const target = if (iteration == 0) 0 else iteration + 1;
    const key = try getSenderKey(allocator, state, target);
    const ciphertext = try signal.aesCbcEncrypt(allocator, key.cipher_key, key.iv, padded_plaintext);
    defer allocator.free(ciphertext);
    return encodeSenderKeyMessage(
        allocator,
        state.key_id,
        key.iteration,
        ciphertext,
        private,
        random,
    );
}

/// GroupCipher.decrypt: verify the signature, ratchet to the message's iteration, then
/// AES-256-CBC. Returns the padded plaintext — unpad with `proto.unpadMessage`.
/// Fails with `UnknownSenderKeyId`, `BadSignature`, `OldCounter` (replay), `TooManySkipped`,
/// `InvalidMessage` or `DecryptFailed`. A failure can still leave the record ratcheted (keys
/// staged, chain advanced): persist it only after success, which is where Baileys calls
/// `storeSenderKey`, so a re-delivered ciphertext gets the same treatment as the JS.
/// Memory: caller frees.
pub fn decrypt(
    allocator: std.mem.Allocator,
    record: *SenderKeyRecord,
    sender_key_message: []const u8,
) ![]u8 {
    const msg = try SenderKeyMessage.parse(sender_key_message);
    const state = record.getSenderKeyStateById(msg.id) orelse return error.UnknownSenderKeyId;
    try msg.verifySignature(state.signing_public);
    const key = try getSenderKey(allocator, state, msg.iteration);
    return signal.aesCbcDecrypt(allocator, key.cipher_key, key.iv, msg.ciphertext) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DecryptFailed,
    };
}

// --------------------------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------------------------

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Fresh sender + receiver records sharing one distributed sender key.
fn testPair(allocator: std.mem.Allocator) !struct {
    sender: SenderKeyRecord,
    receiver: SenderKeyRecord,
} {
    var sender = SenderKeyRecord.init(allocator);
    errdefer sender.deinit();
    const skdm = try create(allocator, &sender, testIo());
    defer allocator.free(skdm);
    var receiver = SenderKeyRecord.init(allocator);
    errdefer receiver.deinit();
    try processDistribution(&receiver, skdm);
    return .{ .sender = sender, .receiver = receiver };
}

test "sender key name serializes like the JS store key" {
    const allocator = std.testing.allocator;
    const name = SenderKeyName{
        .group_id = "120363421845733873@g.us",
        .sender = .{ .id = "481234567890@s.whatsapp.net", .device_id = 3 },
    };
    const key = try name.serialize(allocator);
    defer allocator.free(key);
    try std.testing.expectEqualStrings(
        "120363421845733873@g.us::481234567890@s.whatsapp.net::3",
        key,
    );
    try std.testing.expect(name.eql(.{
        .group_id = "120363421845733873@g.us",
        .sender = .{ .id = "481234567890@s.whatsapp.net", .device_id = 3 },
    }));
    try std.testing.expect(!name.eql(.{
        .group_id = "120363421845733873@g.us",
        .sender = .{ .id = "481234567890@s.whatsapp.net", .device_id = 4 },
    }));
}

test "sender key roundtrip: create, distribute, process, encrypt, decrypt" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();

    const plaintext = "hello group";
    const message = try encrypt(allocator, &pair.sender, plaintext, testIo());
    defer allocator.free(message);
    try std.testing.expectEqual(version_byte, message[0]);
    const decrypted = try decrypt(allocator, &pair.receiver, message);
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(plaintext, decrypted);

    // The receiver adopted exactly the distributed state: same id, chain at 0 -> 1 after the
    // decrypt, signing public key, and no private half (so it cannot encrypt).
    const sent = try SenderKeyMessage.parse(message);
    const send_state = pair.sender.getSenderKeyState().?;
    const recv_state = pair.receiver.getSenderKeyStateById(sent.id).?;
    try std.testing.expectEqual(@as(u32, send_state.key_id), sent.id);
    try std.testing.expectEqual(@as(u32, 0), sent.iteration);
    try std.testing.expectEqual(@as(u32, 1), send_state.chain.iteration);
    try std.testing.expectEqual(@as(u32, 1), recv_state.chain.iteration);
    try std.testing.expectEqualSlices(u8, &send_state.signing_public, &recv_state.signing_public);
    try std.testing.expect(recv_state.signing_private == null);
    try std.testing.expectError(
        error.NoSigningPrivateKey,
        encryptWithSignatureRandom(allocator, &pair.receiver, plaintext, [_]u8{0} ** 64),
    );

    // Empty-plaintext messages (one pure padding block) roundtrip too.
    const empty_message = try encrypt(allocator, &pair.sender, "", testIo());
    defer allocator.free(empty_message);
    const empty_plain = try decrypt(allocator, &pair.receiver, empty_message);
    defer allocator.free(empty_plain);
    try std.testing.expectEqual(@as(usize, 0), empty_plain.len);
}

test "SKDM survives parse plus serialize and rejects junk" {
    const allocator = std.testing.allocator;
    var record = SenderKeyRecord.init(allocator);
    defer record.deinit();
    const skdm = try create(allocator, &record, testIo());
    defer allocator.free(skdm);
    const parsed = try SenderKeyDistributionMessage.parse(skdm);
    try std.testing.expectEqual(version_byte, parsed.version);
    const reencoded = try parsed.serialize(allocator);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, skdm, reencoded);

    // Chain seed must be 32 bytes; signing key 32 or 33.
    try std.testing.expectError(error.InvalidMessage, SenderKeyDistributionMessage.parse(&.{0x33}));
    var short_chain = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer short_chain.deinit(allocator);
    try short_chain.append(allocator, version_byte);
    try proto.writeVarintField(&short_chain, allocator, 1, 7);
    try proto.writeVarintField(&short_chain, allocator, 2, 0);
    try proto.writeBytes(&short_chain, allocator, 3, &[_]u8{1} ** 8);
    try proto.writeBytes(&short_chain, allocator, 4, &signal.encodeDjb([_]u8{2} ** 32));
    try std.testing.expectError(
        error.InvalidChainKey,
        SenderKeyDistributionMessage.parse(short_chain.items),
    );
}

test "out of order sender key messages decrypt from staged keys" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();

    // Baileys asks for iteration + 1 after the first message, so these carry 0, 2, 4, 6.
    var messages: [4][]u8 = undefined;
    const texts = [_][]const u8{ "m1", "m2", "m3", "m4" };
    for (texts, 0..) |text, i| {
        messages[i] = try encrypt(allocator, &pair.sender, text, testIo());
        errdefer allocator.free(messages[i]);
        const view = try SenderKeyMessage.parse(messages[i]);
        try std.testing.expectEqual(@as(u32, @intCast(i * 2)), view.iteration);
    }

    // Newest first, then the two older ones out of order, then the newest-but-one.
    for ([_]usize{ 2, 0, 1, 3 }) |index| {
        const plain = try decrypt(allocator, &pair.receiver, messages[index]);
        defer allocator.free(plain);
        allocator.free(messages[index]);
        try std.testing.expectEqualStrings(texts[index], plain);
    }
    const state = pair.receiver.getSenderKeyState().?;
    try std.testing.expectEqual(@as(u32, 7), state.chain.iteration);
    // Iteration 5 was staged while jumping to 6; 1, 3 were skipped by the sender.
    try std.testing.expectEqual(@as(usize, 3), state.message_keys.items.len);
    for (state.message_keys.items, [_]u32{ 1, 3, 5 }) |key, want| {
        try std.testing.expectEqual(want, key.iteration);
    }
}

test "replayed sender key iterations are rejected" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();

    const first = try encrypt(allocator, &pair.sender, "first", testIo());
    defer allocator.free(first);
    const second = try encrypt(allocator, &pair.sender, "second", testIo());
    defer allocator.free(second);
    const third = try encrypt(allocator, &pair.sender, "third", testIo());
    defer allocator.free(third);

    // Current iteration: used, then refused.
    const p1 = try decrypt(allocator, &pair.receiver, first);
    allocator.free(p1);
    try std.testing.expectError(error.OldCounter, decrypt(allocator, &pair.receiver, first));

    // The newest message (iteration 4) stages 1..3; every staged key works exactly once.
    const p3 = try decrypt(allocator, &pair.receiver, third);
    allocator.free(p3);
    const p2 = try decrypt(allocator, &pair.receiver, second);
    allocator.free(p2);
    try std.testing.expectError(error.OldCounter, decrypt(allocator, &pair.receiver, second));
    try std.testing.expectError(error.OldCounter, decrypt(allocator, &pair.receiver, third));
    // Iterations 1 and 3 are left staged (2 was just consumed, 0 came from the chain).
    const staged = pair.receiver.getSenderKeyState().?.message_keys.items;
    try std.testing.expectEqual(@as(usize, 2), staged.len);
    try std.testing.expectEqual(@as(u32, 1), staged[0].iteration);
    try std.testing.expectEqual(@as(u32, 3), staged[1].iteration);
}

test "tampered sender key messages are rejected" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();
    const message = try encrypt(allocator, &pair.sender, "tamper me", testIo());
    defer allocator.free(message);

    // Ciphertext lives inside the signed protobuf, so any edit breaks the signature.
    var ct_edit = try allocator.dupe(u8, message);
    defer allocator.free(ct_edit);
    ct_edit[ct_edit.len - signature_length - 2] ^= 0x40;
    try std.testing.expectError(error.BadSignature, decrypt(allocator, &pair.receiver, ct_edit));

    var sig_edit = try allocator.dupe(u8, message);
    defer allocator.free(sig_edit);
    sig_edit[sig_edit.len - 1] ^= 0x01;
    try std.testing.expectError(error.BadSignature, decrypt(allocator, &pair.receiver, sig_edit));

    // Same tamper, re-signed with the real key: the padding check catches it instead.
    const sent = try SenderKeyMessage.parse(message);
    const state = pair.sender.getSenderKeyState().?;
    var forged = try allocator.dupe(u8, sent.ciphertext);
    defer allocator.free(forged);
    forged[forged.len - 1] ^= 0x80; // guarantees a final pad byte > 16
    const resigned = try encodeSenderKeyMessage(
        allocator,
        sent.id,
        sent.iteration,
        forged,
        state.signing_private.?,
        [_]u8{0} ** 64,
    );
    defer allocator.free(resigned);
    try std.testing.expectError(error.DecryptFailed, decrypt(allocator, &pair.receiver, resigned));

    // A message signed by an unrelated key must not decrypt even with a matching id.
    var other = SenderKeyRecord.init(allocator);
    defer other.deinit();
    try ensureSenderKeyState(&other, testIo());
    const imposter = try encodeSenderKeyMessage(
        allocator,
        state.key_id,
        state.chain.iteration,
        forged,
        other.getSenderKeyState().?.signing_private.?,
        [_]u8{0} ** 64,
    );
    defer allocator.free(imposter);
    try std.testing.expectError(error.BadSignature, decrypt(allocator, &pair.receiver, imposter));

    // Unknown key id, and structurally invalid messages.
    const stranger_id = try encodeSenderKeyMessage(
        allocator,
        state.key_id +% 1,
        0,
        forged,
        state.signing_private.?,
        [_]u8{0} ** 64,
    );
    defer allocator.free(stranger_id);
    try std.testing.expectError(error.UnknownSenderKeyId, decrypt(allocator, &pair.receiver, stranger_id));
    try std.testing.expectError(error.InvalidMessage, decrypt(allocator, &pair.receiver, &.{}));
    try std.testing.expectError(
        error.InvalidMessage,
        decrypt(allocator, &pair.receiver, &[_]u8{version_byte} ** (1 + signature_length)),
    );
}

test "sender key chain refuses jumps beyond the skip window" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();

    const state = pair.receiver.getSenderKeyState().?;
    // From a fresh chain at 0, max_skip + 1 is already past the window, max_skip is not.
    try std.testing.expectError(error.TooManySkipped, getSenderKey(allocator, state, max_skip + 1));
    const far = try getSenderKey(allocator, state, max_skip);
    try std.testing.expectEqual(max_skip, far.iteration);
    try std.testing.expectEqual(max_skip + 1, state.chain.iteration);
    try std.testing.expectEqual(max_message_keys, state.message_keys.items.len);

    // Staged keys cap at max_message_keys, oldest dropped first (JS shift()).
    var staging = SenderKeyState{
        .key_id = 1,
        .chain = .{ .iteration = 0, .seed = [_]u8{0} ** key_len },
        .signing_public = [_]u8{0} ** key_len,
    };
    defer staging.deinit(allocator);
    for (0..max_message_keys + 2) |i| {
        try staging.addSenderMessageKey(allocator, SenderMessageKey.init(@intCast(i), [_]u8{ @intCast(i % 256) } ** key_len));
    }
    try std.testing.expectEqual(max_message_keys, staging.message_keys.items.len);
    try std.testing.expectEqual(@as(u32, 2), staging.message_keys.items[0].iteration);
    try std.testing.expect(staging.hasSenderMessageKey(max_message_keys + 1));
}

test "record keeps five newest states" {
    const allocator = std.testing.allocator;
    var record = SenderKeyRecord.init(allocator);
    defer record.deinit();
    for (0..max_states + 2) |i| {
        var seed: [key_len]u8 = undefined;
        @memset(&seed, @intCast(i + 1));
        try record.addSenderKeyState(100 + @as(u32, @intCast(i)), 0, seed, [_]u8{0} ** key_len);
    }
    try std.testing.expectEqual(max_states, record.states.items.len);
    try std.testing.expectEqual(@as(u32, max_states + 101), record.getSenderKeyState().?.key_id);
    try std.testing.expect(record.getSenderKeyStateById(100) == null);
    try std.testing.expect(record.getSenderKeyStateById(101) == null);
    try std.testing.expect(record.getSenderKeyStateById(102) != null);
}

test "record serialize roundtrip keeps chain, staged keys and future messages" {
    const allocator = std.testing.allocator;
    var pair = try testPair(allocator);
    defer pair.sender.deinit();
    defer pair.receiver.deinit();

    const m1 = try encrypt(allocator, &pair.sender, "one", testIo());
    defer allocator.free(m1);
    const m2 = try encrypt(allocator, &pair.sender, "two", testIo());
    defer allocator.free(m2);
    const m3 = try encrypt(allocator, &pair.sender, "three", testIo());
    defer allocator.free(m3);

    // Sender side: chain at 5 with the skipped keys (1, 3) staged and the private signing
    // key held.
    const sender_bytes = try pair.sender.serialize(allocator);
    defer allocator.free(sender_bytes);
    var sender_copy = try SenderKeyRecord.deserialize(allocator, sender_bytes);
    defer sender_copy.deinit();
    const reserialized = try sender_copy.serialize(allocator);
    defer allocator.free(reserialized);
    try std.testing.expectEqualSlices(u8, sender_bytes, reserialized);

    const from_live = try encryptWithSignatureRandom(allocator, &pair.sender, "four", [_]u8{0} ** 64);
    defer allocator.free(from_live);
    const from_copy = try encryptWithSignatureRandom(allocator, &sender_copy, "four", [_]u8{0} ** 64);
    defer allocator.free(from_copy);
    try std.testing.expectEqualSlices(u8, from_live, from_copy);

    // Receiver side: consume the newest message first so skipped keys get staged, then
    // restore mid-chain and keep decrypting older and newer messages.
    const p3_live = try decrypt(allocator, &pair.receiver, m3);
    allocator.free(p3_live);
    const staged_before = pair.receiver.getSenderKeyState().?.message_keys.items.len;
    try std.testing.expectEqual(@as(usize, 4), staged_before);
    const receiver_bytes = try pair.receiver.serialize(allocator);
    defer allocator.free(receiver_bytes);
    var receiver_copy = try SenderKeyRecord.deserialize(allocator, receiver_bytes);
    defer receiver_copy.deinit();
    try std.testing.expectEqual(staged_before, receiver_copy.getSenderKeyState().?.message_keys.items.len);
    const restored_bytes = try receiver_copy.serialize(allocator);
    defer allocator.free(restored_bytes);
    try std.testing.expectEqualSlices(u8, receiver_bytes, restored_bytes);

    const p2 = try decrypt(allocator, &receiver_copy, m2);
    defer allocator.free(p2);
    try std.testing.expectEqualStrings("two", p2);
    const p1 = try decrypt(allocator, &receiver_copy, m1);
    defer allocator.free(p1);
    try std.testing.expectEqualStrings("one", p1);
    const p4 = try decrypt(allocator, &receiver_copy, from_live);
    defer allocator.free(p4);
    try std.testing.expectEqualStrings("four", p4);

    // Garbage records are refused rather than half-accepted.
    try std.testing.expectError(error.InvalidMessage, SenderKeyRecord.deserialize(allocator, &.{0xFF}));
    try std.testing.expectError(
        error.InvalidSigningKey,
        SenderKeyRecord.deserialize(allocator, &.{ 0x0A, 0x02, 0x08, 0x07 }),
    );
    var empty_record = try SenderKeyRecord.deserialize(allocator, &.{});
    defer empty_record.deinit();
    try std.testing.expect(empty_record.isEmpty());
}

test "sender key helpers use fresh randomness" {
    const io = testIo();
    try std.testing.expect(generateSenderKeyId(io) < 2147483647);
    try std.testing.expect(generateSenderKeyId(io) < 2147483647);
    const a = generateSenderKey(io);
    const b = generateSenderKey(io);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const pair_a = generateSenderSigningKey(io);
    const pair_b = generateSenderSigningKey(io);
    try std.testing.expect(!std.mem.eql(u8, &pair_a.pub_key, &pair_b.pub_key));
    const shared_a = try nc.KeyPair.sharedSecret(pair_a.priv_key, pair_b.pub_key);
    const shared_b = try nc.KeyPair.sharedSecret(pair_b.priv_key, pair_a.pub_key);
    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
}

// --------------------------------------------------------------------------------------------
// Wire-format cross-check against the Baileys JS port (the oracle)
//
// Fixtures come from /tmp/groupvec/gen.mjs, which drives Baileys' own Group classes and
// serialises the SenderKeyRecordStructure with the bundled protobufjs definitions.
// /tmp/groupvec/verify_zig.mjs is the reverse leg: Baileys decrypting what this file emits.
// Both legs skip themselves when the oracle checkout is absent.
// --------------------------------------------------------------------------------------------

const fixtures_dir = "/tmp/groupvec";
const zig_fixtures_dir = "/tmp/groupvec/zig_out";
const node_shim = "/tmp/groupvec/run_node.sh";
const zig_verifier = "/tmp/groupvec/verify_zig.mjs";

fn hexNibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// `<fixtures_dir>/<name>` hex-decoded. Skips the running test when fixtures are absent.
/// Memory: caller frees.
fn readHexFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var path: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&path, "{s}/{s}", .{ fixtures_dir, name }) catch return error.NameTooLong;
    const raw = std.Io.Dir.cwd().readFileAlloc(testIo(), full, allocator, .limited(1 << 22)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(raw);
    var nibbles: usize = 0;
    for (raw) |ch| {
        if (hexNibble(ch) != null) nibbles += 1;
    }
    if (nibbles % 2 != 0) return error.BadFixture;
    var out = try allocator.alloc(u8, nibbles / 2);
    errdefer allocator.free(out);
    var w: usize = 0;
    var high: ?u8 = null;
    for (raw) |ch| {
        const nib = hexNibble(ch) orelse continue;
        if (high) |hi| {
            out[w] = (hi << 4) | nib;
            w += 1;
            high = null;
        } else high = nib;
    }
    return out;
}

fn fixtureExists(name: []const u8) bool {
    var path: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&path, "{s}/{s}", .{ fixtures_dir, name }) catch return false;
    var file = std.Io.Dir.cwd().openFile(testIo(), full, .{ .mode = .read_only }) catch return false;
    file.close(testIo());
    return true;
}

/// Tracks fixture buffers so a test can free them all on exit (a `defer` inside the loading
/// loop would release the fixtures while later assertions still read them).
const FixtureOwner = struct {
    allocator: std.mem.Allocator,
    slices: [24][]u8 = [_][]u8{&[_]u8{}} ** 24,
    len: usize = 0,

    pub fn own(self: *FixtureOwner, slice: []u8) []u8 {
        std.debug.assert(self.len < self.slices.len);
        self.slices[self.len] = slice;
        self.len += 1;
        return slice;
    }

    pub fn freeAll(self: *FixtureOwner) void {
        for (self.slices[0..self.len]) |slice| self.allocator.free(slice);
        self.* = .{ .allocator = self.allocator };
    }
};

fn writeFixtureFile(name: []const u8, bytes: []const u8, hex: bool) !void {
    const io = testIo();
    var path: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&path, "{s}/{s}", .{ zig_fixtures_dir, name }) catch return error.NameTooLong;
    var file = try std.Io.Dir.createFileAbsolute(io, full, .{});
    defer file.close(io);
    if (!hex) {
        try file.writeStreamingAll(io, bytes);
        return;
    }
    var buf: [2]u8 = undefined;
    for (bytes) |byte| {
        const pair = std.fmt.bufPrint(&buf, "{x:0>2}", .{byte}) catch return error.FormatFailed;
        try file.writeStreamingAll(io, pair);
    }
    try file.writeStreamingAll(io, "\n");
}

test "group message seam: wa-v2 padding plus the proto SKDM wrapper round-trip" {
    const allocator = std.testing.allocator;
    var sender = SenderKeyRecord.init(allocator);
    defer sender.deinit();
    var receiver = SenderKeyRecord.init(allocator);
    defer receiver.deinit();
    const skdm = try create(allocator, &sender, testIo());
    defer allocator.free(skdm);
    try processDistribution(&receiver, skdm);

    // Outbound pads like Baileys/whatsmeow; inbound unpads with the stanza version.
    const padded = try proto.padMessageRandom(allocator, "ping", testIo());
    defer allocator.free(padded);
    const message = try encrypt(allocator, &sender, padded, testIo());
    defer allocator.free(message);
    const got_padded = try decrypt(allocator, &receiver, message);
    defer allocator.free(got_padded);
    try std.testing.expectEqualSlices(u8, padded, got_padded);
    const got = try proto.unpadMessage(got_padded, 2);
    try std.testing.expectEqualStrings("ping", got);

    // The axolotl blob survives the Message wrapper the parent puts on the wire, and the
    // copy pulled back out of it installs a working sender key.
    const group_id = "120363421845733873@g.us";
    const wrapper = try proto.Message.encodeSenderKeyDistribution(allocator, group_id, skdm);
    defer allocator.free(wrapper);
    const decoded = try proto.Message.decode(wrapper);
    const inner = decoded.sender_key_distribution orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(group_id, inner.group_id);
    try std.testing.expectEqualSlices(u8, skdm, inner.axolotl);

    var unwrapped = SenderKeyRecord.init(allocator);
    defer unwrapped.deinit();
    try processDistribution(&unwrapped, inner.axolotl);
    const later = try encrypt(allocator, &sender, padded, testIo());
    defer allocator.free(later);
    const later_plain = try decrypt(allocator, &unwrapped, later);
    defer allocator.free(later_plain);
    try std.testing.expectEqualStrings("ping", try proto.unpadMessage(later_plain, 2));
}

test "cross-check node -> zig: Baileys SKDM, messages and record decrypt in Zig" {
    if (!fixtureExists("skdm.hex")) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var owned = FixtureOwner{ .allocator = allocator };
    defer owned.freeAll();

    const skdm = owned.own(try readHexFixture(allocator, "skdm.hex"));
    const signing_pub = owned.own(try readHexFixture(allocator, "signing_pub.hex"));
    var texts: [5][]u8 = undefined;
    var messages: [5][]u8 = undefined;
    for (0..5) |i| {
        var label: [16]u8 = undefined;
        texts[i] = owned.own(try readHexFixture(allocator, std.fmt.bufPrint(&label, "pt{d}.hex", .{i + 1}) catch return error.FormatFailed));
        label = [_]u8{0} ** 16;
        messages[i] = owned.own(try readHexFixture(allocator, std.fmt.bufPrint(&label, "m{d}.hex", .{i + 1}) catch return error.FormatFailed));
    }

    // The SKDM Baileys produced parses here and re-encodes to the very same bytes.
    const distributed = try SenderKeyDistributionMessage.parse(skdm);
    try std.testing.expectEqual(version_byte, distributed.version);
    try std.testing.expectEqual(@as(u32, 0), distributed.iteration);
    const reencoded = try distributed.serialize(allocator);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, skdm, reencoded);
    // signingKey width: 33 bytes, 0x05-prefixed Curve25519 point.
    try std.testing.expectEqual(@as(usize, 33), signing_pub.len);
    try std.testing.expectEqualSlices(u8, signing_pub, &signal.encodeDjb(distributed.signing_key));

    // SenderKeyMessage: version byte, id, iteration and signature all check out.
    const first = try SenderKeyMessage.parse(messages[0]);
    try std.testing.expectEqual(version_byte, first.version);
    try std.testing.expectEqual(distributed.id, first.id);
    try std.testing.expectEqual(@as(u32, 0), first.iteration);
    try first.verifySignature(distributed.signing_key);

    // Sequential decrypts, ending on exactly the record state Baileys recorded.
    var sequential = SenderKeyRecord.init(allocator);
    defer sequential.deinit();
    try processDistribution(&sequential, skdm);
    for (0..5) |i| {
        const plain = try decrypt(allocator, &sequential, messages[i]);
        defer allocator.free(plain);
        try std.testing.expectEqualSlices(u8, texts[i], plain);
    }
    const seq_want = owned.own(try readHexFixture(allocator, "record_recv_seq.hex"));
    const seq_mine = try sequential.serialize(allocator);
    defer allocator.free(seq_mine);
    try std.testing.expectEqualSlices(u8, seq_want, seq_mine);

    // Out-of-order path: m3 (iteration 4) first, then m1, m2 — the record has to match Baileys
    // mid-flight, again after m4, and finally after m5.
    var receiver = SenderKeyRecord.init(allocator);
    defer receiver.deinit();
    try processDistribution(&receiver, skdm);
    for ([_]usize{ 2, 0, 1 }) |i| {
        const plain = try decrypt(allocator, &receiver, messages[i]);
        defer allocator.free(plain);
        try std.testing.expectEqualSlices(u8, texts[i], plain);
    }
    const staged_want = owned.own(try readHexFixture(allocator, "record_recv.hex"));
    const staged_mine = try receiver.serialize(allocator);
    defer allocator.free(staged_mine);
    try std.testing.expectEqualSlices(u8, staged_want, staged_mine);

    const m4_plain = try decrypt(allocator, &receiver, messages[3]);
    defer allocator.free(m4_plain);
    try std.testing.expectEqualSlices(u8, texts[3], m4_plain);
    const m4_want = owned.own(try readHexFixture(allocator, "record_recv_m4.hex"));
    const m4_mine = try receiver.serialize(allocator);
    defer allocator.free(m4_mine);
    try std.testing.expectEqualSlices(u8, m4_want, m4_mine);

    const m5_plain = try decrypt(allocator, &receiver, messages[4]);
    defer allocator.free(m5_plain);
    try std.testing.expectEqualSlices(u8, texts[4], m5_plain);
    const m5_mine = try receiver.serialize(allocator);
    defer allocator.free(m5_mine);
    try std.testing.expectEqualSlices(u8, seq_want, m5_mine);

    // Baileys' own sender record (chain 9, keys 1/3/5/7 staged, private signing key) loads here.
    const sender_want = owned.own(try readHexFixture(allocator, "record_sender.hex"));
    var sender = try SenderKeyRecord.deserialize(allocator, sender_want);
    defer sender.deinit();
    const sender_state = sender.getSenderKeyState().?;
    try std.testing.expectEqual(distributed.id, sender_state.key_id);
    try std.testing.expectEqual(@as(u32, 9), sender_state.chain.iteration);
    try std.testing.expectEqual(@as(usize, 4), sender_state.message_keys.items.len);
    try std.testing.expect(sender_state.signing_private != null);
    const sender_mine = try sender.serialize(allocator);
    defer allocator.free(sender_mine);
    try std.testing.expectEqualSlices(u8, sender_want, sender_mine);
    // Continuing that chain yields Baileys' iteration 10 (chain + 1, staging 9).
    const onward = try encryptWithSignatureRandom(allocator, &sender, "sixth from zig", [_]u8{0} ** 64);
    defer allocator.free(onward);
    const onward_view = try SenderKeyMessage.parse(onward);
    try std.testing.expectEqual(@as(u32, 10), onward_view.iteration);

    // Negatives Baileys also rejects.
    const other_id = owned.own(try readHexFixture(allocator, "m_other_id.hex"));
    try std.testing.expectError(error.UnknownSenderKeyId, decrypt(allocator, &receiver, other_id));
    const sig_tamper = owned.own(try readHexFixture(allocator, "m5_tampered_sig.hex"));
    try std.testing.expectError(error.BadSignature, decrypt(allocator, &receiver, sig_tamper));
    // Payload tamper (Baileys rejects it the same way): the ciphertext sits inside the signed
    // protobuf, so this can only be a signature failure.
    const ct_tamper = owned.own(try readHexFixture(allocator, "m5_tampered_ct.hex"));
    try std.testing.expectError(error.BadSignature, decrypt(allocator, &receiver, ct_tamper));
    // Length-varint tamper: the declared ciphertext runs past the protobuf (JS "index out of
    // range"), so this one is refused by the parser before the signature is even considered.
    const len_tamper = owned.own(try readHexFixture(allocator, "m5_bad_ct_len.hex"));
    try std.testing.expectError(error.InvalidMessage, decrypt(allocator, &receiver, len_tamper));
}

test "cross-check zig -> node: Baileys decrypts what this file emits" {
    if (!fixtureExists("skdm.hex") or !fixtureExists("verify_zig.mjs") or !fixtureExists("run_node.sh")) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    var sender = SenderKeyRecord.init(allocator);
    defer sender.deinit();
    const skdm = try create(allocator, &sender, testIo());
    defer allocator.free(skdm);

    var owned = FixtureOwner{ .allocator = allocator };
    defer owned.freeAll();
    const texts = [_][]const u8{ "zig message one", "zig message two", "zig message three", "zig message four" };
    var messages: [4][]u8 = undefined;
    for (texts, 0..) |text, i| {
        messages[i] = owned.own(try encryptWithSignatureRandom(allocator, &sender, text, [_]u8{0} ** 64));
        const view = try SenderKeyMessage.parse(messages[i]);
        try std.testing.expectEqual(@as(u32, @intCast(i * 2)), view.iteration);
    }

    // Snapshot after three messages: Baileys' receiver should be at the same point once it has
    // consumed m1, m3, m2 in that order. m4 is sent afterwards to prove the chains agree.
    const record_bytes = try sender.serialize(allocator);
    defer allocator.free(record_bytes);
    const state = sender.getSenderKeyState().?;
    var staged = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer staged.deinit(allocator);
    for (state.message_keys.items, 0..) |key, i| {
        var label: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "{s}{d}", .{ if (i == 0) "" else ",", key.iteration }) catch return error.FormatFailed;
        try staged.appendSlice(allocator, text);
    }
    var meta: [256]u8 = undefined;
    const meta_json = std.fmt.bufPrint(
        &meta,
        "{{\"key_id\":{d},\"chain_iteration\":{d},\"staged\":[{s}]}}",
        .{ state.key_id, state.chain.iteration, staged.items },
    ) catch return error.FormatFailed;

    const io = testIo();
    // The fixtures directory is the oracle's; its absence means nothing to verify against.
    std.Io.Dir.createDirAbsolute(io, zig_fixtures_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound, error.NotDir, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try writeFixtureFile("skdm.hex", skdm, true);
    for (texts, 0..) |text, i| {
        var label: [16]u8 = undefined;
        try writeFixtureFile(std.fmt.bufPrint(&label, "m{d}.hex", .{i + 1}) catch return error.FormatFailed, messages[i], true);
        label = [_]u8{0} ** 16;
        try writeFixtureFile(std.fmt.bufPrint(&label, "pt{d}.hex", .{i + 1}) catch return error.FormatFailed, text, true);
    }
    try writeFixtureFile("record.hex", record_bytes, true);
    try writeFixtureFile("meta.json", meta_json, false);

    // `std.Io.Threaded.global_single_threaded` cannot spawn (its processSpawn always fails),
    // so build a real one. Its environment is empty by design: run_node.sh locates node
    // without PATH, and the verifier imports Baileys through absolute paths.
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const result = std.process.run(
        gpa,
        threaded.io(),
        .{
            .argv = &[_][]const u8{ "/bin/sh", node_shim, zig_verifier, zig_fixtures_dir },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        },
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return error.NodeCrashed,
    };
    if (code == 127) return error.SkipZigTest; // no node binary on this box
    if (code != 0) {
        std.debug.print("verify_zig.mjs exit {d}\n{s}\n{s}\n", .{ code, result.stdout, result.stderr });
        return error.NodeRejectedZigOutput;
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PASS") != null);
}
