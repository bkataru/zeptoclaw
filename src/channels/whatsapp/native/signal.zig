const std = @import("std");
const nc = @import("noise_crypto.zig");

/// Minimal libsignal-compatible 1:1 Double Ratchet (WhisperMessage v3).
/// Enough to encrypt/decrypt when both sides share an X3DH secret. PreKey
/// (X3DH) against WhatsApp prekey bundles is still separate.

const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256 = std.crypto.core.aes.Aes256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

const djb_type: u8 = 5;
const msg_version: u8 = 0x33; // current=3, max=3
const whisper_ratchet = "WhisperRatchet";
const whisper_keys = "WhisperMessageKeys";

pub const MessageKeys = struct {
    cipher_key: [32]u8 = [_]u8{0} ** 32,
    mac_key: [32]u8 = [_]u8{0} ** 32,
    iv: [16]u8 = [_]u8{0} ** 16,
    index: u32 = 0,
};

/// Inline skipped-message-key cache (libsignal ReceiverChain keys). Oldest evicted.
pub const skipped_capacity: usize = 64;
/// Refuse to derive more than this many keys for one ciphertext (libsignal MAX_SKIP).
pub const max_skip: u32 = 2000;
pub const session_ser_version: u8 = 1;

const SkippedKey = struct {
    ratchet_pub: [32]u8 = [_]u8{0} ** 32,
    index: u32 = 0,
    keys: MessageKeys = .{},
};

const RecvWhich = enum { current, previous };

pub const Session = struct {
    local_identity: [32]u8,
    remote_identity: [32]u8,
    root: [32]u8,
    dh_local: nc.KeyPair,
    dh_remote: ?[32]u8 = null,
    send_ck: ?[32]u8 = null,
    recv_ck: ?[32]u8 = null,
    ns: u32 = 0,
    nr: u32 = 0,
    pn: u32 = 0,
    prev_dh_remote: ?[32]u8 = null,
    prev_recv_ck: ?[32]u8 = null,
    prev_nr: u32 = 0,
    skipped: [skipped_capacity]SkippedKey = [_]SkippedKey{.{}} ** skipped_capacity,
    skipped_len: u8 = 0,
    skipped_head: u8 = 0,

    /// Alice has Bob's ratchet public key and the X3DH shared secret.
    pub fn initAlice(shared: [32]u8, bob_ratchet_pub: [32]u8, local_id: [32]u8, remote_id: [32]u8, io: std.Io) !Session {
        const dh_local = nc.KeyPair.generate(io);
        const dh = try nc.KeyPair.sharedSecret(dh_local.priv_key, bob_ratchet_pub);
        const k = kdfRk(shared, dh);
        return .{
            .local_identity = local_id,
            .remote_identity = remote_id,
            .root = k.rk,
            .dh_local = dh_local,
            .dh_remote = bob_ratchet_pub,
            .send_ck = k.ck,
        };
    }

    /// Bob holds the ratchet keypair corresponding to the public Alice used.
    pub fn initBob(shared: [32]u8, bob_ratchet: nc.KeyPair, local_id: [32]u8, remote_id: [32]u8) Session {
        return .{
            .local_identity = local_id,
            .remote_identity = remote_id,
            .root = shared,
            .dh_local = bob_ratchet,
        };
    }

    /// Memory: caller frees the WhisperMessage (version + proto + 8-byte MAC).
    pub fn encrypt(self: *Session, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const ck = self.send_ck orelse return error.NoSendChain;
        const mk = try messageKeys(ck, self.ns);
        self.send_ck = nextChain(ck);
        self.ns += 1;
        const ct = try aesCbcEncrypt(allocator, mk.cipher_key, mk.iv, plaintext);
        defer allocator.free(ct);
        const proto_bytes = try encodeSignalMessage(allocator, self.dh_local.pub_key, mk.index, self.pn, ct);
        defer allocator.free(proto_bytes);
        return macWrap(allocator, mk.mac_key, self.local_identity, self.remote_identity, proto_bytes);
    }

    /// Memory: caller frees plaintext.
    pub fn decrypt(self: *Session, allocator: std.mem.Allocator, blob: []const u8) ![]u8 {
        if (blob.len < 10) return error.InvalidMessage;
        if (blob[0] != msg_version) return error.InvalidVersion;
        const mac = blob[blob.len - 8 ..];
        const proto_bytes = blob[1 .. blob.len - 8];
        const parsed = try decodeSignalMessage(proto_bytes);
        if (parsed.ratchet_key.len != 32) return error.InvalidRatchetKey;

        const ratchet = parsed.ratchet_key;
        if (self.lookupSkipped(ratchet, parsed.counter)) |mk| {
            try verifyMac(mk.mac_key, self.remote_identity, self.local_identity, proto_bytes, mac);
            self.removeSkipped(ratchet, parsed.counter);
            return aesCbcDecrypt(allocator, mk.cipher_key, mk.iv, parsed.ciphertext);
        }

        if (self.chainMatches(.current, ratchet)) {
            return self.decryptWithChain(allocator, .current, parsed, proto_bytes, mac);
        }
        if (self.chainMatches(.previous, ratchet)) {
            return self.decryptWithChain(allocator, .previous, parsed, proto_bytes, mac);
        }
        try self.dhRatchet(ratchet);
        return self.decryptWithChain(allocator, .current, parsed, proto_bytes, mac);
    }

    /// Memory: caller frees the versioned little-endian session blob.
    pub fn serialize(self: *const Session, allocator: std.mem.Allocator) ![]u8 {
        const entry_size: usize = 32 + 4 + 32 + 32 + 16;
        const header_size: usize = 342;
        const out = try allocator.alloc(u8, header_size + @as(usize, self.skipped_len) * entry_size);
        errdefer allocator.free(out);
        var i: usize = 0;
        putU8(out, &i, session_ser_version);
        putArr(out, &i, &self.local_identity);
        putArr(out, &i, &self.remote_identity);
        putArr(out, &i, &self.root);
        putArr(out, &i, &self.dh_local.priv_key);
        putArr(out, &i, &self.dh_local.pub_key);
        putOpt32(out, &i, self.dh_remote);
        putOpt32(out, &i, self.send_ck);
        putOpt32(out, &i, self.recv_ck);
        putU32(out, &i, self.ns);
        putU32(out, &i, self.nr);
        putU32(out, &i, self.pn);
        const prev_on = self.prev_recv_ck != null and self.prev_dh_remote != null;
        putU8(out, &i, if (prev_on) 1 else 0);
        const prev_dh = self.prev_dh_remote orelse [_]u8{0} ** 32;
        const prev_ck = self.prev_recv_ck orelse [_]u8{0} ** 32;
        putArr(out, &i, &prev_dh);
        putArr(out, &i, &prev_ck);
        putU32(out, &i, self.prev_nr);
        putU8(out, &i, self.skipped_len);
        var off: usize = 0;
        while (off < self.skipped_len) : (off += 1) {
            const slot = self.skipped[(self.skipped_head + off) % skipped_capacity];
            putArr(out, &i, &slot.ratchet_pub);
            putU32(out, &i, slot.index);
            putArr(out, &i, &slot.keys.cipher_key);
            putArr(out, &i, &slot.keys.mac_key);
            put16(out, &i, &slot.keys.iv);
        }
        std.debug.assert(i == out.len);
        return out;
    }

    pub fn deserialize(bytes: []const u8) !Session {
        if (bytes.len < 342) return error.Truncated;
        var i: usize = 0;
        const ver = getU8(bytes, &i);
        if (ver != session_ser_version) return error.UnsupportedVersion;
        var session = Session{
            .local_identity = getArr(bytes, &i),
            .remote_identity = getArr(bytes, &i),
            .root = getArr(bytes, &i),
            .dh_local = .{
                .priv_key = getArr(bytes, &i),
                .pub_key = getArr(bytes, &i),
            },
            .dh_remote = getOpt32(bytes, &i),
            .send_ck = getOpt32(bytes, &i),
            .recv_ck = getOpt32(bytes, &i),
            .ns = getU32(bytes, &i),
            .nr = getU32(bytes, &i),
            .pn = getU32(bytes, &i),
        };
        const prev_on = getU8(bytes, &i) != 0;
        const prev_dh = getArr(bytes, &i);
        const prev_ck = getArr(bytes, &i);
        session.prev_nr = getU32(bytes, &i);
        if (prev_on) {
            session.prev_dh_remote = prev_dh;
            session.prev_recv_ck = prev_ck;
        }
        const nskip = getU8(bytes, &i);
        if (nskip > skipped_capacity) return error.InvalidSession;
        const entry_size: usize = 32 + 4 + 32 + 32 + 16;
        const need = 342 + @as(usize, nskip) * entry_size;
        if (bytes.len < need) return error.Truncated;
        session.skipped_head = 0;
        session.skipped_len = nskip;
        var off: u8 = 0;
        while (off < nskip) : (off += 1) {
            const ratchet = getArr(bytes, &i);
            const idx = getU32(bytes, &i);
            const cipher = getArr(bytes, &i);
            const mac_key = getArr(bytes, &i);
            if (i + 16 > bytes.len) return error.Truncated;
            var iv: [16]u8 = undefined;
            @memcpy(&iv, bytes[i .. i + 16]);
            i += 16;
            session.skipped[off] = .{
                .ratchet_pub = ratchet,
                .index = idx,
                .keys = .{
                    .cipher_key = cipher,
                    .mac_key = mac_key,
                    .iv = iv,
                    .index = idx,
                },
            };
        }
        return session;
    }

    fn chainMatches(self: Session, which: RecvWhich, ratchet: [32]u8) bool {
        const remote = switch (which) {
            .current => self.dh_remote,
            .previous => self.prev_dh_remote,
        };
        const ck = switch (which) {
            .current => self.recv_ck,
            .previous => self.prev_recv_ck,
        };
        return ck != null and remote != null and std.mem.eql(u8, &remote.?, &ratchet);
    }

    fn decryptWithChain(
        self: *Session,
        allocator: std.mem.Allocator,
        which: RecvWhich,
        parsed: ParsedMsg,
        proto_bytes: []const u8,
        mac: []const u8,
    ) ![]u8 {
        var ck: [32]u8 = undefined;
        var n: u32 = undefined;
        switch (which) {
            .current => {
                ck = self.recv_ck orelse return error.NoRecvChain;
                n = self.nr;
            },
            .previous => {
                ck = self.prev_recv_ck orelse return error.NoRecvChain;
                n = self.prev_nr;
            },
        }
        if (parsed.counter < n) return error.DuplicateMessage;
        if (parsed.counter - n > max_skip) return error.TooManySkipped;
        while (n < parsed.counter) {
            const skipped_mk = try messageKeys(ck, n);
            self.stashSkipped(parsed.ratchet_key, n, skipped_mk);
            ck = nextChain(ck);
            n += 1;
        }
        const mk = try messageKeys(ck, n);
        try verifyMac(mk.mac_key, self.remote_identity, self.local_identity, proto_bytes, mac);
        ck = nextChain(ck);
        n += 1;
        switch (which) {
            .current => {
                self.recv_ck = ck;
                self.nr = n;
            },
            .previous => {
                self.prev_recv_ck = ck;
                self.prev_nr = n;
            },
        }
        return aesCbcDecrypt(allocator, mk.cipher_key, mk.iv, parsed.ciphertext);
    }

    fn lookupSkipped(self: Session, ratchet: [32]u8, index: u32) ?MessageKeys {
        var off: usize = 0;
        while (off < self.skipped_len) : (off += 1) {
            const slot = self.skipped[(self.skipped_head + off) % skipped_capacity];
            if (slot.index == index and std.mem.eql(u8, &slot.ratchet_pub, &ratchet)) return slot.keys;
        }
        return null;
    }

    fn removeSkipped(self: *Session, ratchet: [32]u8, index: u32) void {
        var off: usize = 0;
        while (off < self.skipped_len) : (off += 1) {
            const idx = (self.skipped_head + off) % skipped_capacity;
            const slot = self.skipped[idx];
            if (slot.index == index and std.mem.eql(u8, &slot.ratchet_pub, &ratchet)) {
                var j = off;
                while (j + 1 < self.skipped_len) : (j += 1) {
                    const dst = (self.skipped_head + j) % skipped_capacity;
                    const src = (self.skipped_head + j + 1) % skipped_capacity;
                    self.skipped[dst] = self.skipped[src];
                }
                self.skipped_len -= 1;
                return;
            }
        }
    }

    fn stashSkipped(self: *Session, ratchet: [32]u8, index: u32, keys: MessageKeys) void {
        const entry = SkippedKey{ .ratchet_pub = ratchet, .index = index, .keys = keys };
        if (self.skipped_len == skipped_capacity) {
            self.skipped[self.skipped_head] = entry;
            self.skipped_head = @intCast((self.skipped_head + 1) % skipped_capacity);
            return;
        }
        const idx = (self.skipped_head + self.skipped_len) % skipped_capacity;
        self.skipped[idx] = entry;
        self.skipped_len += 1;
    }

    fn dhRatchet(self: *Session, their_pub: [32]u8) !void {
        if (self.recv_ck != null) {
            self.prev_recv_ck = self.recv_ck;
            self.prev_dh_remote = self.dh_remote;
            self.prev_nr = self.nr;
        }
        self.pn = self.ns;
        self.ns = 0;
        self.nr = 0;
        const dh1 = try nc.KeyPair.sharedSecret(self.dh_local.priv_key, their_pub);
        const k1 = kdfRk(self.root, dh1);
        self.root = k1.rk;
        self.recv_ck = k1.ck;
        self.dh_remote = their_pub;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.dh_local = nc.KeyPair.generate(io);
        const dh2 = try nc.KeyPair.sharedSecret(self.dh_local.priv_key, their_pub);
        const k2 = kdfRk(self.root, dh2);
        self.root = k2.rk;
        self.send_ck = k2.ck;
    }
};

const ParsedMsg = struct {
    ratchet_key: [32]u8 = [_]u8{0} ** 32,
    counter: u32 = 0,
    previous: u32 = 0,
    ciphertext: []const u8 = &.{},
};

fn putU8(buf: []u8, i: *usize, v: u8) void {
    buf[i.*] = v;
    i.* += 1;
}

fn putArr(buf: []u8, i: *usize, v: *const [32]u8) void {
    @memcpy(buf[i.*..][0..32], v);
    i.* += 32;
}

fn put16(buf: []u8, i: *usize, v: *const [16]u8) void {
    @memcpy(buf[i.*..][0..16], v);
    i.* += 16;
}

fn putU32(buf: []u8, i: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[i.*..][0..4], v, .little);
    i.* += 4;
}

fn putOpt32(buf: []u8, i: *usize, v: ?[32]u8) void {
    if (v) |val| {
        putU8(buf, i, 1);
        putArr(buf, i, &val);
    } else {
        putU8(buf, i, 0);
        putArr(buf, i, &[_]u8{0} ** 32);
    }
}

fn getU8(buf: []const u8, i: *usize) u8 {
    const v = buf[i.*];
    i.* += 1;
    return v;
}

fn getArr(buf: []const u8, i: *usize) [32]u8 {
    var out: [32]u8 = undefined;
    @memcpy(&out, buf[i.*..][0..32]);
    i.* += 32;
    return out;
}

fn getU32(buf: []const u8, i: *usize) u32 {
    const v = std.mem.readInt(u32, buf[i.*..][0..4], .little);
    i.* += 4;
    return v;
}

fn getOpt32(buf: []const u8, i: *usize) ?[32]u8 {
    const flag = getU8(buf, i);
    const arr = getArr(buf, i);
    return if (flag != 0) arr else null;
}

fn kdfRk(root: [32]u8, dh: [32]u8) struct { rk: [32]u8, ck: [32]u8 } {
    const prk = Hkdf.extract(&root, &dh);
    var okm: [64]u8 = undefined;
    Hkdf.expand(&okm, whisper_ratchet, prk);
    var rk: [32]u8 = undefined;
    var ck: [32]u8 = undefined;
    @memcpy(&rk, okm[0..32]);
    @memcpy(&ck, okm[32..64]);
    return .{ .rk = rk, .ck = ck };
}

fn nextChain(ck: [32]u8) [32]u8 {
    return nc.hmacSha256(&ck, &[_]u8{0x02});
}

fn messageKeys(ck: [32]u8, index: u32) !MessageKeys {
    const seed = nc.hmacSha256(&ck, &[_]u8{0x01});
    const prk = Hkdf.extract(&[_]u8{}, &seed);
    var okm: [80]u8 = undefined;
    Hkdf.expand(&okm, whisper_keys, prk);
    var mk = MessageKeys{
        .cipher_key = undefined,
        .mac_key = undefined,
        .iv = undefined,
        .index = index,
    };
    @memcpy(&mk.cipher_key, okm[0..32]);
    @memcpy(&mk.mac_key, okm[32..64]);
    @memcpy(&mk.iv, okm[64..80]);
    return mk;
}

fn encodeSignalMessage(
    allocator: std.mem.Allocator,
    ratchet_pub: [32]u8,
    counter: u32,
    previous: u32,
    ciphertext: []const u8,
) ![]u8 {
    var key33: [33]u8 = undefined;
    key33[0] = djb_type;
    @memcpy(key33[1..], &ratchet_pub);
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buf.deinit(allocator);
    try writeBytes(&buf, allocator, 1, &key33);
    try writeVarintField(&buf, allocator, 2, counter);
    if (previous != 0) try writeVarintField(&buf, allocator, 3, previous);
    try writeBytes(&buf, allocator, 4, ciphertext);
    return buf.toOwnedSlice(allocator);
}

fn decodeSignalMessage(data: []const u8) !ParsedMsg {
    var out = ParsedMsg{};
    var idx: usize = 0;
    while (idx < data.len) {
        const key = try readVarint(data, &idx);
        const field: u32 = @intCast(key >> 3);
        const wire: u3 = @intCast(key & 7);
        switch (field) {
            1 => {
                if (wire != 2) return error.InvalidMessage;
                const bytes = try readLenBytes(data, &idx);
                if (bytes.len == 33 and bytes[0] == djb_type) {
                    @memcpy(&out.ratchet_key, bytes[1..33]);
                } else if (bytes.len == 32) {
                    @memcpy(&out.ratchet_key, bytes[0..32]);
                } else return error.InvalidRatchetKey;
            },
            2 => {
                if (wire != 0) return error.InvalidMessage;
                out.counter = @intCast(try readVarint(data, &idx));
            },
            3 => {
                if (wire != 0) return error.InvalidMessage;
                out.previous = @intCast(try readVarint(data, &idx));
            },
            4 => {
                if (wire != 2) return error.InvalidMessage;
                out.ciphertext = try readLenBytes(data, &idx);
            },
            else => try skipField(data, &idx, wire),
        }
    }
    return out;
}

fn macWrap(
    allocator: std.mem.Allocator,
    mac_key: [32]u8,
    sender_id: [32]u8,
    receiver_id: [32]u8,
    proto_bytes: []const u8,
) ![]u8 {
    var out = try allocator.alloc(u8, 1 + proto_bytes.len + 8);
    out[0] = msg_version;
    @memcpy(out[1 .. 1 + proto_bytes.len], proto_bytes);
    const mac = computeMac(mac_key, sender_id, receiver_id, proto_bytes);
    @memcpy(out[1 + proto_bytes.len ..], &mac);
    return out;
}

fn verifyMac(
    mac_key: [32]u8,
    sender_id: [32]u8,
    receiver_id: [32]u8,
    proto_bytes: []const u8,
    got: []const u8,
) !void {
    const want = computeMac(mac_key, sender_id, receiver_id, proto_bytes);
    if (got.len != 8 or !std.crypto.timing_safe.eql([8]u8, want, got[0..8].*))
        return error.MacMismatch;
}

fn computeMac(mac_key: [32]u8, sender_id: [32]u8, receiver_id: [32]u8, proto_bytes: []const u8) [8]u8 {
    var sender33: [33]u8 = undefined;
    var recv33: [33]u8 = undefined;
    sender33[0] = djb_type;
    recv33[0] = djb_type;
    @memcpy(sender33[1..], &sender_id);
    @memcpy(recv33[1..], &receiver_id);
    var h = Hmac.init(&mac_key);
    h.update(&sender33);
    h.update(&recv33);
    h.update(&[_]u8{msg_version});
    h.update(proto_bytes);
    var full: [32]u8 = undefined;
    h.final(&full);
    var out: [8]u8 = undefined;
    @memcpy(&out, full[0..8]);
    return out;
}

pub fn aesCbcEncrypt(allocator: std.mem.Allocator, key: [32]u8, iv: [16]u8, plaintext: []const u8) ![]u8 {
    const pad: u8 = @intCast(16 - (plaintext.len % 16));
    const out = try allocator.alloc(u8, plaintext.len + pad);
    @memcpy(out[0..plaintext.len], plaintext);
    @memset(out[plaintext.len..], pad);
    const ctx = Aes256.initEnc(key);
    var prev = iv;
    var i: usize = 0;
    while (i < out.len) : (i += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, out[i .. i + 16]);
        for (0..16) |j| block[j] ^= prev[j];
        var enc_block: [16]u8 = undefined;
        ctx.encrypt(&enc_block, &block);
        @memcpy(out[i .. i + 16], &enc_block);
        prev = enc_block;
    }
    return out;
}

pub fn aesCbcDecrypt(allocator: std.mem.Allocator, key: [32]u8, iv: [16]u8, ciphertext: []const u8) ![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.InvalidCiphertext;
    const buf = try allocator.dupe(u8, ciphertext);
    defer allocator.free(buf);
    const ctx = Aes256.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i < buf.len) : (i += 16) {
        const ct_block = buf[i .. i + 16][0..16].*;
        var dec: [16]u8 = undefined;
        ctx.decrypt(&dec, &ct_block);
        for (0..16) |j| buf[i + j] = dec[j] ^ prev[j];
        prev = ct_block;
    }
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or pad > buf.len) return error.AesPadding;
    var p: usize = buf.len - pad;
    while (p < buf.len) : (p += 1) {
        if (buf[p] != pad) return error.AesPadding;
    }
    return allocator.dupe(u8, buf[0 .. buf.len - pad]);
}

fn writeVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (x >= 0x80) {
        try buf.append(allocator, @as(u8, @intCast(x & 0x7F)) | 0x80);
        x >>= 7;
    }
    try buf.append(allocator, @intCast(x));
}

fn writeVarintField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, v: u64) !void {
    try writeVarint(buf, allocator, (@as(u64, field) << 3) | 0);
    try writeVarint(buf, allocator, v);
}

fn writeBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, bytes: []const u8) !void {
    try writeVarint(buf, allocator, (@as(u64, field) << 3) | 2);
    try writeVarint(buf, allocator, bytes.len);
    try buf.appendSlice(allocator, bytes);
}

fn readVarint(data: []const u8, idx: *usize) !u64 {
    var shift: u6 = 0;
    var result: u64 = 0;
    while (idx.* < data.len) {
        const b = data[idx.*];
        idx.* += 1;
        result |= @as(u64, b & 0x7F) << shift;
        if (b < 0x80) return result;
        shift += 7;
        if (shift >= 64) return error.InvalidVarint;
    }
    return error.EndOfStream;
}

fn readLenBytes(data: []const u8, idx: *usize) ![]const u8 {
    const n = try readVarint(data, idx);
    if (idx.* + n > data.len) return error.EndOfStream;
    const s = data[idx.* .. idx.* + n];
    idx.* += n;
    return s;
}

fn skipField(data: []const u8, idx: *usize, wire: u3) !void {
    switch (wire) {
        0 => _ = try readVarint(data, idx),
        1 => {
            if (idx.* + 8 > data.len) return error.EndOfStream;
            idx.* += 8;
        },
        2 => _ = try readLenBytes(data, idx),
        5 => {
            if (idx.* + 4 > data.len) return error.EndOfStream;
            idx.* += 4;
        },
        else => return error.InvalidWire,
    }
}

pub const djb_type_byte: u8 = djb_type;

pub fn encodeDjb(pub_key: [32]u8) [33]u8 {
    var out: [33]u8 = undefined;
    out[0] = djb_type;
    @memcpy(out[1..], &pub_key);
    return out;
}

pub fn parseDjb(bytes: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (bytes.len == 33 and bytes[0] == djb_type) {
        @memcpy(&out, bytes[1..33]);
        return out;
    }
    if (bytes.len == 32) {
        @memcpy(&out, bytes[0..32]);
        return out;
    }
    return error.InvalidDjbKey;
}

pub const PreKeyBundle = struct {
    registration_id: u32,
    prekey_id: u32 = 0,
    prekey_pub: ?[32]u8 = null,
    signed_prekey_id: u32,
    signed_prekey_pub: [32]u8,
    signed_prekey_sig: [64]u8,
    identity_pub: [32]u8,
};

pub const PreKeyHeader = struct {
    registration_id: u32,
    prekey_id: u32 = 0,
    signed_prekey_id: u32,
    base_pub: [32]u8,
    identity_pub: [32]u8,
};

pub const LocalKeys = struct {
    identity: nc.KeyPair,
    signed_prekey: nc.KeyPair,
    signed_prekey_id: u32,
    one_time: ?struct { id: u32, pair: nc.KeyPair } = null,
    registration_id: u32,
};

pub const InitiateResult = struct {
    session: Session,
    header: PreKeyHeader,
};

fn discontinuity() [32]u8 {
    return [_]u8{0xFF} ** 32;
}

fn x3dhSecret(dh1: [32]u8, dh2: [32]u8, dh3: [32]u8, dh4: ?[32]u8) [32]u8 {
    var ikm: [32 * 5]u8 = undefined;
    @memcpy(ikm[0..32], &discontinuity());
    @memcpy(ikm[32..64], &dh1);
    @memcpy(ikm[64..96], &dh2);
    @memcpy(ikm[96..128], &dh3);
    var len: usize = 128;
    if (dh4) |d| {
        @memcpy(ikm[128..160], &d);
        len = 160;
    }
    const salt = [_]u8{0} ** 32;
    const prk = Hkdf.extract(&salt, ikm[0..len]);
    var okm: [64]u8 = undefined;
    Hkdf.expand(&okm, "WhisperText", prk);
    var sk: [32]u8 = undefined;
    @memcpy(&sk, okm[0..32]);
    return sk;
}

/// Alice: X3DH against Bob's signed prekey (and optional one-time), then init ratchet.
pub fn initiateFromBundle(bundle: PreKeyBundle, our_identity: nc.KeyPair, io: std.Io) !InitiateResult {
    const base = nc.KeyPair.generate(io);
    const dh1 = try nc.KeyPair.sharedSecret(our_identity.priv_key, bundle.signed_prekey_pub);
    const dh2 = try nc.KeyPair.sharedSecret(base.priv_key, bundle.identity_pub);
    const dh3 = try nc.KeyPair.sharedSecret(base.priv_key, bundle.signed_prekey_pub);
    var dh4: ?[32]u8 = null;
    if (bundle.prekey_pub) |opk| {
        dh4 = try nc.KeyPair.sharedSecret(base.priv_key, opk);
    }
    const sk = x3dhSecret(dh1, dh2, dh3, dh4);
    const session = try Session.initAlice(sk, bundle.signed_prekey_pub, our_identity.pub_key, bundle.identity_pub, io);
    return .{
        .session = session,
        .header = .{
            .registration_id = bundle.registration_id,
            .prekey_id = bundle.prekey_id,
            .signed_prekey_id = bundle.signed_prekey_id,
            .base_pub = base.pub_key,
            .identity_pub = our_identity.pub_key,
        },
    };
}

/// Bob: consume Alice's PreKey WhisperMessage header and init as receiver.
pub fn acceptPreKey(our: LocalKeys, their_identity: [32]u8, their_base: [32]u8, signed_prekey_id: u32, prekey_id: u32) !Session {
    if (signed_prekey_id != our.signed_prekey_id) return error.UnknownSignedPreKey;
    const dh1 = try nc.KeyPair.sharedSecret(our.signed_prekey.priv_key, their_identity);
    const dh2 = try nc.KeyPair.sharedSecret(our.identity.priv_key, their_base);
    const dh3 = try nc.KeyPair.sharedSecret(our.signed_prekey.priv_key, their_base);
    var dh4: ?[32]u8 = null;
    if (prekey_id != 0) {
        const ot = our.one_time orelse return error.UnknownOneTimePreKey;
        if (ot.id != prekey_id) return error.UnknownOneTimePreKey;
        dh4 = try nc.KeyPair.sharedSecret(ot.pair.priv_key, their_base);
    }
    const sk = x3dhSecret(dh1, dh2, dh3, dh4);
    return Session.initBob(sk, our.signed_prekey, our.identity.pub_key, their_identity);
}

/// Memory: caller frees. Version byte 0x33 + protobuf (no outer MAC).
pub fn encodePreKeyMessage(allocator: std.mem.Allocator, header: PreKeyHeader, whisper: []const u8) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 1);
    errdefer buf.deinit(allocator);
    try buf.append(allocator, msg_version);
    if (header.prekey_id != 0) try writeVarintField(&buf, allocator, 1, header.prekey_id);
    const base = encodeDjb(header.base_pub);
    try writeBytes(&buf, allocator, 2, &base);
    const ident = encodeDjb(header.identity_pub);
    try writeBytes(&buf, allocator, 3, &ident);
    try writeBytes(&buf, allocator, 4, whisper);
    try writeVarintField(&buf, allocator, 5, header.registration_id);
    try writeVarintField(&buf, allocator, 6, header.signed_prekey_id);
    return buf.toOwnedSlice(allocator);
}

pub const ParsedPreKey = struct {
    header: PreKeyHeader,
    whisper: []const u8,
};

/// `whisper` aliases `blob`.
pub fn decodePreKeyMessage(blob: []const u8) !ParsedPreKey {
    if (blob.len < 2 or blob[0] != msg_version) return error.InvalidVersion;
    var header = PreKeyHeader{
        .registration_id = 0,
        .signed_prekey_id = 0,
        .base_pub = [_]u8{0} ** 32,
        .identity_pub = [_]u8{0} ** 32,
    };
    var whisper: []const u8 = &.{};
    var idx: usize = 1;
    const data = blob;
    while (idx < data.len) {
        const key = try readVarint(data, &idx);
        const field: u32 = @intCast(key >> 3);
        const wire: u3 = @intCast(key & 7);
        switch (field) {
            1 => {
                if (wire != 0) return error.InvalidMessage;
                header.prekey_id = @intCast(try readVarint(data, &idx));
            },
            2 => {
                if (wire != 2) return error.InvalidMessage;
                header.base_pub = try parseDjb(try readLenBytes(data, &idx));
            },
            3 => {
                if (wire != 2) return error.InvalidMessage;
                header.identity_pub = try parseDjb(try readLenBytes(data, &idx));
            },
            4 => {
                if (wire != 2) return error.InvalidMessage;
                whisper = try readLenBytes(data, &idx);
            },
            5 => {
                if (wire != 0) return error.InvalidMessage;
                header.registration_id = @intCast(try readVarint(data, &idx));
            },
            6 => {
                if (wire != 0) return error.InvalidMessage;
                header.signed_prekey_id = @intCast(try readVarint(data, &idx));
            },
            else => try skipField(data, &idx, wire),
        }
    }
    if (whisper.len == 0) return error.MissingWhisper;
    return .{ .header = header, .whisper = whisper };
}

test "signal two-party ratchet roundtrip" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const alice_id = nc.KeyPair.generate(io);
    const bob_id = nc.KeyPair.generate(io);
    const bob_ratchet = nc.KeyPair.generate(io);
    const shared = try nc.KeyPair.sharedSecret(alice_id.priv_key, bob_id.pub_key);

    var alice = try Session.initAlice(shared, bob_ratchet.pub_key, alice_id.pub_key, bob_id.pub_key, io);
    var bob = Session.initBob(shared, bob_ratchet, bob_id.pub_key, alice_id.pub_key);

    const ct1 = try alice.encrypt(alloc, "hi barvis");
    defer alloc.free(ct1);
    const pt1 = try bob.decrypt(alloc, ct1);
    defer alloc.free(pt1);
    try std.testing.expectEqualStrings("hi barvis", pt1);

    const ct2 = try bob.encrypt(alloc, "hello back");
    defer alloc.free(ct2);
    const pt2 = try alice.decrypt(alloc, ct2);
    defer alloc.free(pt2);
    try std.testing.expectEqualStrings("hello back", pt2);

    const ct3 = try alice.encrypt(alloc, "second");
    defer alloc.free(ct3);
    const pt3 = try bob.decrypt(alloc, ct3);
    defer alloc.free(pt3);
    try std.testing.expectEqualStrings("second", pt3);
}

test "x3dh prekey whisper roundtrip" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const alice_id = nc.KeyPair.generate(io);
    const bob_id = nc.KeyPair.generate(io);
    const bob_spk = nc.KeyPair.generate(io);
    const bundle = PreKeyBundle{
        .registration_id = 42,
        .signed_prekey_id = 7,
        .signed_prekey_pub = bob_spk.pub_key,
        .signed_prekey_sig = [_]u8{0} ** 64,
        .identity_pub = bob_id.pub_key,
    };
    var initiated = try initiateFromBundle(bundle, alice_id, io);
    const whisper = try initiated.session.encrypt(alloc, "hi barvis");
    defer alloc.free(whisper);
    const pk = try encodePreKeyMessage(alloc, initiated.header, whisper);
    defer alloc.free(pk);
    try std.testing.expectEqual(msg_version, pk[0]);

    const parsed = try decodePreKeyMessage(pk);
    try std.testing.expectEqual(@as(u32, 7), parsed.header.signed_prekey_id);
    try std.testing.expectEqualSlices(u8, &alice_id.pub_key, &parsed.header.identity_pub);

    var bob = try acceptPreKey(.{
        .identity = bob_id,
        .signed_prekey = bob_spk,
        .signed_prekey_id = 7,
        .registration_id = 42,
    }, parsed.header.identity_pub, parsed.header.base_pub, parsed.header.signed_prekey_id, parsed.header.prekey_id);
    const pt = try bob.decrypt(alloc, parsed.whisper);
    defer alloc.free(pt);
    try std.testing.expectEqualStrings("hi barvis", pt);
}

fn testPair() !struct { alice: Session, bob: Session } {
    const io = std.Io.Threaded.global_single_threaded.io();
    const alice_id = nc.KeyPair.generate(io);
    const bob_id = nc.KeyPair.generate(io);
    const bob_ratchet = nc.KeyPair.generate(io);
    const shared = try nc.KeyPair.sharedSecret(alice_id.priv_key, bob_id.pub_key);
    return .{
        .alice = try Session.initAlice(shared, bob_ratchet.pub_key, alice_id.pub_key, bob_id.pub_key, io),
        .bob = Session.initBob(shared, bob_ratchet, bob_id.pub_key, alice_id.pub_key),
    };
}

test "session serialize deserialize continues conversation" {
    const alloc = std.testing.allocator;
    const pair = try testPair();
    var alice = pair.alice;
    var bob = pair.bob;

    const ct1 = try alice.encrypt(alloc, "hi barvis");
    defer alloc.free(ct1);
    const pt1 = try bob.decrypt(alloc, ct1);
    defer alloc.free(pt1);
    try std.testing.expectEqualStrings("hi barvis", pt1);

    const ct2 = try bob.encrypt(alloc, "hello back");
    defer alloc.free(ct2);
    const pt2 = try alice.decrypt(alloc, ct2);
    defer alloc.free(pt2);
    try std.testing.expectEqualStrings("hello back", pt2);

    const ser_a = try alice.serialize(alloc);
    defer alloc.free(ser_a);
    const ser_b = try bob.serialize(alloc);
    defer alloc.free(ser_b);
    var alice2 = try Session.deserialize(ser_a);
    var bob2 = try Session.deserialize(ser_b);
    const ser_a2 = try alice2.serialize(alloc);
    defer alloc.free(ser_a2);
    const ser_b2 = try bob2.serialize(alloc);
    defer alloc.free(ser_b2);
    try std.testing.expectEqualSlices(u8, ser_a, ser_a2);
    try std.testing.expectEqualSlices(u8, ser_b, ser_b2);

    const more = try alice.encrypt(alloc, "more");
    defer alloc.free(more);
    const more2 = try alice2.encrypt(alloc, "more");
    defer alloc.free(more2);
    try std.testing.expectEqualSlices(u8, more, more2);

    const got = try bob.decrypt(alloc, more);
    defer alloc.free(got);
    const got2 = try bob2.decrypt(alloc, more2);
    defer alloc.free(got2);
    try std.testing.expectEqualStrings("more", got);
    try std.testing.expectEqualStrings("more", got2);
}

test "out of order decrypt m3 then m1 then m2" {
    const alloc = std.testing.allocator;
    const pair = try testPair();
    var alice = pair.alice;
    var bob = pair.bob;

    const m1 = try alice.encrypt(alloc, "m1");
    defer alloc.free(m1);
    const m2 = try alice.encrypt(alloc, "m2");
    defer alloc.free(m2);
    const m3 = try alice.encrypt(alloc, "m3");
    defer alloc.free(m3);

    const p3 = try bob.decrypt(alloc, m3);
    defer alloc.free(p3);
    try std.testing.expectEqualStrings("m3", p3);
    const p1 = try bob.decrypt(alloc, m1);
    defer alloc.free(p1);
    try std.testing.expectEqualStrings("m1", p1);
    const p2 = try bob.decrypt(alloc, m2);
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("m2", p2);
}

test "previous receiving chain decrypts delayed older message" {
    const alloc = std.testing.allocator;
    const pair = try testPair();
    var alice = pair.alice;
    var bob = pair.bob;

    const setup = try alice.encrypt(alloc, "setup");
    defer alloc.free(setup);
    const delayed = try alice.encrypt(alloc, "delayed");
    defer alloc.free(delayed);

    const psetup = try bob.decrypt(alloc, setup);
    defer alloc.free(psetup);
    try std.testing.expectEqualStrings("setup", psetup);

    const reply = try bob.encrypt(alloc, "reply");
    defer alloc.free(reply);
    const preply = try alice.decrypt(alloc, reply);
    defer alloc.free(preply);
    try std.testing.expectEqualStrings("reply", preply);

    const newer = try alice.encrypt(alloc, "newer");
    defer alloc.free(newer);
    const pnewer = try bob.decrypt(alloc, newer);
    defer alloc.free(pnewer);
    try std.testing.expectEqualStrings("newer", pnewer);

    const pdelayed = try bob.decrypt(alloc, delayed);
    defer alloc.free(pdelayed);
    try std.testing.expectEqualStrings("delayed", pdelayed);
}

test "replay of used skipped key fails" {
    const alloc = std.testing.allocator;
    const pair = try testPair();

    var alice = pair.alice;
    var bob = pair.bob;

    const m1 = try alice.encrypt(alloc, "m1");
    defer alloc.free(m1);
    const m2 = try alice.encrypt(alloc, "m2");
    defer alloc.free(m2);
    const m3 = try alice.encrypt(alloc, "m3");
    defer alloc.free(m3);

    const p3 = try bob.decrypt(alloc, m3);
    defer alloc.free(p3);
    try std.testing.expectEqualStrings("m3", p3);
    try std.testing.expectError(error.DuplicateMessage, bob.decrypt(alloc, m3));

    const p1 = try bob.decrypt(alloc, m1);
    defer alloc.free(p1);
    try std.testing.expectEqualStrings("m1", p1);
    try std.testing.expectError(error.DuplicateMessage, bob.decrypt(alloc, m1));

    const p2 = try bob.decrypt(alloc, m2);
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("m2", p2);
    try std.testing.expectError(error.DuplicateMessage, bob.decrypt(alloc, m2));
}
test "skipped keys survive serialize deserialize" {
    const alloc = std.testing.allocator;
    const pair = try testPair();
    var alice = pair.alice;
    var bob = pair.bob;

    const m1 = try alice.encrypt(alloc, "m1");
    defer alloc.free(m1);
    const m2 = try alice.encrypt(alloc, "m2");
    defer alloc.free(m2);
    const m3 = try alice.encrypt(alloc, "m3");
    defer alloc.free(m3);

    const p3 = try bob.decrypt(alloc, m3);
    defer alloc.free(p3);
    try std.testing.expectEqualStrings("m3", p3);

    const ser = try bob.serialize(alloc);
    defer alloc.free(ser);
    var bob2 = try Session.deserialize(ser);
    const p1 = try bob2.decrypt(alloc, m1);
    defer alloc.free(p1);
    try std.testing.expectEqualStrings("m1", p1);
    const p2 = try bob2.decrypt(alloc, m2);
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("m2", p2);
    try std.testing.expectError(error.DuplicateMessage, bob2.decrypt(alloc, m1));
}
