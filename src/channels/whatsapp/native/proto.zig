const std = @import("std");

// Proto2 varint/length-delimited helpers for whatsmeow hot protos (waWa6).
pub fn writeVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var val = v;
    while (val >= 0x80) {
        try buf.append(allocator, @intCast((val & 0x7F) | 0x80));
        val >>= 7;
    }
    try buf.append(allocator, @intCast(val));
}

pub fn writeTag(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, wire: u32) !void {
    try writeVarint(buf, allocator, (@as(u64, field) << 3) | wire);
}

pub fn writeBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, data: []const u8) !void {
    try writeTag(buf, allocator, field, 2);
    try writeVarint(buf, allocator, data.len);
    try buf.appendSlice(allocator, data);
}

pub fn writeVarintField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, v: u64) !void {
    try writeTag(buf, allocator, field, 0);
    try writeVarint(buf, allocator, v);
}

pub fn writeBoolField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, v: bool) !void {
    try writeVarintField(buf, allocator, field, if (v) 1 else 0);
}

pub fn writeSfixed32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, v: i32) !void {
    try writeTag(buf, allocator, field, 5);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

pub fn writeDouble(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, field: u32, v: f64) !void {
    try writeTag(buf, allocator, field, 1);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(v), .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readDouble(data: []const u8, idx: *usize) !f64 {
    if (idx.* + 8 > data.len) return error.EndOfStream;
    const bits = std.mem.readInt(u64, data[idx.*..][0..8], .little);
    idx.* += 8;
    return @bitCast(bits);
}

pub fn readVarint(data: []const u8, idx: *usize) !u64 {
    var res: u64 = 0;
    var shift: u6 = 0;
    while (idx.* < data.len) : (shift += 7) {
        const b = data[idx.*];
        idx.* += 1;
        res |= @as(u64, b & 0x7F) << shift;
        if (b & 0x80 == 0) return res;
        if (shift >= 63) return error.InvalidVarint;
    }
    return error.EndOfStream;
}

/// Slice aliases `data`. Does not allocate.
pub fn readBytes(data: []const u8, idx: *usize) ![]const u8 {
    const len64 = try readVarint(data, idx);
    const len: usize = @intCast(len64);
    if (idx.* + len > data.len) return error.EndOfStream;
    const slice = data[idx.* .. idx.* + len];
    idx.* += len;
    return slice;
}

pub fn skipField(data: []const u8, idx: *usize, wire: u32) !void {
    switch (wire) {
        0 => {
            _ = try readVarint(data, idx);
        },
        1 => {
            if (idx.* + 8 > data.len) return error.EndOfStream;
            idx.* += 8;
        },
        2 => {
            _ = try readBytes(data, idx);
        },
        5 => {
            if (idx.* + 4 > data.len) return error.EndOfStream;
            idx.* += 4;
        },
        else => return error.InvalidWireType,
    }
}

fn nextTag(data: []const u8, idx: *usize) !struct { field: u32, wire: u32 } {
    const tag = try readVarint(data, idx);
    return .{ .field = @intCast(tag >> 3), .wire = @intCast(tag & 7) };
}

// ---------------------------------------------------------------------------
// HandshakeMessage — waWa6 nested messages (NOT flattened outer fields)
//   ClientHello  field 1 ephemeral
//   HandshakeMessage.clientHello  = 2
//   ServerHello  ephemeral=1 static=2 payload=3
//   HandshakeMessage.serverHello  = 3
//   ClientFinish static=1 payload=2
//   HandshakeMessage.clientFinish = 4
// ---------------------------------------------------------------------------

pub const HandshakeMessage = struct {
    client_hello: ?ClientHello = null,
    server_hello: ?ServerHello = null,
    client_finish: ?ClientFinish = null,

    pub const ClientHello = struct {
        ephemeral: []const u8 = &[_]u8{},

        /// Memory: caller frees with allocator.
        pub fn encode(self: ClientHello, allocator: std.mem.Allocator) ![]u8 {
            var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            errdefer buf.deinit(allocator);
            if (self.ephemeral.len > 0) try writeBytes(&buf, allocator, 1, self.ephemeral);
            return buf.toOwnedSlice(allocator);
        }

        /// Returned slices alias `data`.
        pub fn decode(data: []const u8) !ClientHello {
            var out = ClientHello{};
            var idx: usize = 0;
            while (idx < data.len) {
                const t = try nextTag(data, &idx);
                if (t.field == 1 and t.wire == 2) {
                    out.ephemeral = try readBytes(data, &idx);
                } else {
                    try skipField(data, &idx, t.wire);
                }
            }
            return out;
        }
    };

    pub const ServerHello = struct {
        ephemeral: []const u8 = &[_]u8{},
        static: []const u8 = &[_]u8{},
        payload: []const u8 = &[_]u8{},

        /// Memory: caller frees with allocator.
        pub fn encode(self: ServerHello, allocator: std.mem.Allocator) ![]u8 {
            var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            errdefer buf.deinit(allocator);
            if (self.ephemeral.len > 0) try writeBytes(&buf, allocator, 1, self.ephemeral);
            if (self.static.len > 0) try writeBytes(&buf, allocator, 2, self.static);
            if (self.payload.len > 0) try writeBytes(&buf, allocator, 3, self.payload);
            return buf.toOwnedSlice(allocator);
        }

        /// Returned slices alias `data`.
        pub fn decode(data: []const u8) !ServerHello {
            var out = ServerHello{};
            var idx: usize = 0;
            while (idx < data.len) {
                const t = try nextTag(data, &idx);
                if (t.wire != 2) {
                    try skipField(data, &idx, t.wire);
                    continue;
                }
                const bytes = try readBytes(data, &idx);
                switch (t.field) {
                    1 => out.ephemeral = bytes,
                    2 => out.static = bytes,
                    3 => out.payload = bytes,
                    else => {},
                }
            }
            return out;
        }
    };

    pub const ClientFinish = struct {
        static: []const u8 = &[_]u8{},
        payload: []const u8 = &[_]u8{},

        /// Memory: caller frees with allocator.
        pub fn encode(self: ClientFinish, allocator: std.mem.Allocator) ![]u8 {
            var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            errdefer buf.deinit(allocator);
            if (self.static.len > 0) try writeBytes(&buf, allocator, 1, self.static);
            if (self.payload.len > 0) try writeBytes(&buf, allocator, 2, self.payload);
            return buf.toOwnedSlice(allocator);
        }

        /// Returned slices alias `data`.
        pub fn decode(data: []const u8) !ClientFinish {
            var out = ClientFinish{};
            var idx: usize = 0;
            while (idx < data.len) {
                const t = try nextTag(data, &idx);
                if (t.wire != 2) {
                    try skipField(data, &idx, t.wire);
                    continue;
                }
                const bytes = try readBytes(data, &idx);
                switch (t.field) {
                    1 => out.static = bytes,
                    2 => out.payload = bytes,
                    else => {},
                }
            }
            return out;
        }
    };

    /// Memory: caller frees with allocator. Nested submessages are length-delimited.
    pub fn encode(self: HandshakeMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.client_hello) |ch| {
            const inner = try ch.encode(allocator);
            defer allocator.free(inner);
            try writeBytes(&buf, allocator, 2, inner);
        }
        if (self.server_hello) |sh| {
            const inner = try sh.encode(allocator);
            defer allocator.free(inner);
            try writeBytes(&buf, allocator, 3, inner);
        }
        if (self.client_finish) |cf| {
            const inner = try cf.encode(allocator);
            defer allocator.free(inner);
            try writeBytes(&buf, allocator, 4, inner);
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Returned nested byte slices alias `data`.
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !HandshakeMessage {
        _ = allocator;
        var msg = HandshakeMessage{};
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            if (t.wire != 2) {
                try skipField(data, &idx, t.wire);
                continue;
            }
            const inner = try readBytes(data, &idx);
            switch (t.field) {
                2 => msg.client_hello = try ClientHello.decode(inner),
                3 => msg.server_hello = try ServerHello.decode(inner),
                4 => msg.client_finish = try ClientFinish.decode(inner),
                else => {},
            }
        }
        return msg;
    }
};

// ---------------------------------------------------------------------------
// ClientPayload — waWa6 field numbers (unpaired companion hello)
//   username=1 passive=3 userAgent=5 webInfo=6 sessionID=9
//   connectType=12 connectReason=13 device=18 devicePairingData=19 pull=33
// UserAgent: platform=1 appVersion=2 mcc=3 mnc=4 osVersion=5 manufacturer=6
//   device=7 osBuildNumber=8 releaseChannel=10 localeLanguage=11 localeCountry=12
// AppVersion: primary=1 secondary=2 tertiary=3
// WebInfo: webSubPlatform=4 (WEB_BROWSER=0)
// Platform WEB=14; ConnectType WIFI_UNKNOWN=1; ConnectReason USER_ACTIVATED=1
// ---------------------------------------------------------------------------

pub const AppVersion = struct {
    primary: u32 = 2,
    secondary: u32 = 3000,
    tertiary: u32 = 1043857760,

    /// md5("primary.secondary.tertiary") — DevicePairingRegistrationData.buildHash.
    pub fn buildHash(self: AppVersion) [16]u8 {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ self.primary, self.secondary, self.tertiary }) catch unreachable;
        var out: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(s, &out, .{});
        return out;
    }

    /// Memory: caller frees with allocator.
    pub fn encode(self: AppVersion, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeVarintField(&buf, allocator, 1, self.primary);
        try writeVarintField(&buf, allocator, 2, self.secondary);
        try writeVarintField(&buf, allocator, 3, self.tertiary);
        return buf.toOwnedSlice(allocator);
    }
};

pub const UserAgent = struct {
    platform: u32 = 14, // WEB
    app_version: AppVersion = .{},
    mcc: []const u8 = "000",
    mnc: []const u8 = "000",
    os_version: []const u8 = "0.1",
    manufacturer: []const u8 = "",
    device: []const u8 = "Desktop",
    os_build_number: []const u8 = "0.1",
    release_channel: u32 = 0, // RELEASE
    locale_language: []const u8 = "en",
    locale_country: []const u8 = "US",

    /// Memory: caller frees with allocator.
    pub fn encode(self: UserAgent, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeVarintField(&buf, allocator, 1, self.platform);
        {
            const ver = try self.app_version.encode(allocator);
            defer allocator.free(ver);
            try writeBytes(&buf, allocator, 2, ver);
        }
        try writeBytes(&buf, allocator, 3, self.mcc);
        try writeBytes(&buf, allocator, 4, self.mnc);
        try writeBytes(&buf, allocator, 5, self.os_version);
        try writeBytes(&buf, allocator, 6, self.manufacturer);
        try writeBytes(&buf, allocator, 7, self.device);
        try writeBytes(&buf, allocator, 8, self.os_build_number);
        try writeVarintField(&buf, allocator, 10, self.release_channel);
        try writeBytes(&buf, allocator, 11, self.locale_language);
        try writeBytes(&buf, allocator, 12, self.locale_country);
        return buf.toOwnedSlice(allocator);
    }
};

pub const WebInfo = struct {
    web_sub_platform: u32 = 0, // WEB_BROWSER

    /// Memory: caller frees with allocator.
    pub fn encode(self: WebInfo, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeVarintField(&buf, allocator, 4, self.web_sub_platform);
        return buf.toOwnedSlice(allocator);
    }
};

pub const DevicePairingRegistrationData = struct {
    e_regid: []const u8 = &[_]u8{},
    e_keytype: []const u8 = &[_]u8{},
    e_ident: []const u8 = &[_]u8{},
    e_skey_id: []const u8 = &[_]u8{},
    e_skey_val: []const u8 = &[_]u8{},
    e_skey_sig: []const u8 = &[_]u8{},
    build_hash: []const u8 = &[_]u8{},
    device_props: []const u8 = &[_]u8{},

    /// Memory: caller frees with allocator.
    pub fn encode(self: DevicePairingRegistrationData, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.e_regid.len > 0) try writeBytes(&buf, allocator, 1, self.e_regid);
        if (self.e_keytype.len > 0) try writeBytes(&buf, allocator, 2, self.e_keytype);
        if (self.e_ident.len > 0) try writeBytes(&buf, allocator, 3, self.e_ident);
        if (self.e_skey_id.len > 0) try writeBytes(&buf, allocator, 4, self.e_skey_id);
        if (self.e_skey_val.len > 0) try writeBytes(&buf, allocator, 5, self.e_skey_val);
        if (self.e_skey_sig.len > 0) try writeBytes(&buf, allocator, 6, self.e_skey_sig);
        if (self.build_hash.len > 0) try writeBytes(&buf, allocator, 7, self.build_hash);
        if (self.device_props.len > 0) try writeBytes(&buf, allocator, 8, self.device_props);
        return buf.toOwnedSlice(allocator);
    }
};

pub const ClientPayload = struct {
    username: u64 = 0,
    passive: bool = false,
    user_agent: UserAgent = .{},
    web_info: WebInfo = .{},
    session_id: i32 = 0,
    has_session_id: bool = false,
    connect_type: u32 = 1, // WIFI_UNKNOWN
    connect_reason: u32 = 1, // USER_ACTIVATED
    device: u32 = 0,
    device_pairing_data: ?DevicePairingRegistrationData = null,
    pull: bool = true,

    /// Memory: caller frees with allocator.
    /// Default values are an unpaired chrome-like companion hello:
    /// user_agent WEB + web_info WEB_BROWSER + WIFI + pull.
    pub fn encode(self: ClientPayload, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.username != 0) try writeVarintField(&buf, allocator, 1, self.username);
        try writeBoolField(&buf, allocator, 3, self.passive);
        {
            const ua = try self.user_agent.encode(allocator);
            defer allocator.free(ua);
            try writeBytes(&buf, allocator, 5, ua);
        }
        {
            const wi = try self.web_info.encode(allocator);
            defer allocator.free(wi);
            try writeBytes(&buf, allocator, 6, wi);
        }
        if (self.has_session_id) try writeSfixed32(&buf, allocator, 9, self.session_id);
        try writeVarintField(&buf, allocator, 12, self.connect_type);
        try writeVarintField(&buf, allocator, 13, self.connect_reason);
        if (self.device != 0) try writeVarintField(&buf, allocator, 18, self.device);
        if (self.device_pairing_data) |dpd| {
            const inner = try dpd.encode(allocator);
            defer allocator.free(inner);
            try writeBytes(&buf, allocator, 19, inner);
        }
        try writeBoolField(&buf, allocator, 33, self.pull);
        return buf.toOwnedSlice(allocator);
    }
};

pub const CertChain = struct {
    leaf: []const u8 = &[_]u8{},
    intermediate: []const u8 = &[_]u8{},
    pub fn verify(self: CertChain, pubkey: [32]u8) !void {
        _ = self;
        _ = pubkey;
    }
    pub fn decodeDetails(self: CertChain, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = allocator;
        return error.NotImplemented;
    }
};

/// waCompanionReg.DeviceProps: os=1 version=2 platformType=3 requireFullSync=4.
/// PlatformType: UNKNOWN=0 CHROME=1 FIREFOX=2 ... DESKTOP=7.
pub const DeviceProps = struct {
    os: []const u8 = "Ubuntu",
    version: AppVersion = .{ .primary = 1, .secondary = 0, .tertiary = 0 },
    platform_type: u32 = 1, // CHROME
    require_full_sync: bool = false,

    /// Memory: caller frees with allocator.
    pub fn encode(self: DeviceProps, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 1, self.os);
        {
            const ver = try self.version.encode(allocator);
            defer allocator.free(ver);
            try writeBytes(&buf, allocator, 2, ver);
        }
        try writeVarintField(&buf, allocator, 3, self.platform_type);
        try writeBoolField(&buf, allocator, 4, self.require_full_sync);
        return buf.toOwnedSlice(allocator);
    }
};

test "proto varint" {
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buf.deinit(std.testing.allocator);
    try writeVarint(&buf, std.testing.allocator, 300);
    var idx: usize = 0;
    try std.testing.expectEqual(@as(u64, 300), try readVarint(buf.items, &idx));
}

test "handshake encode" {
    const m = HandshakeMessage{ .client_hello = .{ .ephemeral = &[_]u8{1} ** 32 } };
    const enc = try m.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    try std.testing.expect(enc.len > 0);
    // Nested: outer field 2 wire 2 (0x12), inner len 34 (0x22),
    // inner field 1 wire 2 (0x0A), 32 (0x20) — NOT flattened field-2 ephemeral.
    try std.testing.expectEqual(@as(u8, 0x12), enc[0]);
    try std.testing.expectEqual(@as(u8, 0x22), enc[1]);
    try std.testing.expectEqual(@as(u8, 0x0A), enc[2]);
    try std.testing.expectEqual(@as(u8, 0x20), enc[3]);
    try std.testing.expectEqual(@as(usize, 4 + 32), enc.len);
}

test "handshake nested client hello roundtrip" {
    const eph = [_]u8{0xAB} ** 32;
    const m = HandshakeMessage{ .client_hello = .{ .ephemeral = &eph } };
    const enc = try m.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    const dec = try HandshakeMessage.decode(std.testing.allocator, enc);
    try std.testing.expect(dec.client_hello != null);
    try std.testing.expect(dec.server_hello == null);
    try std.testing.expectEqualSlices(u8, &eph, dec.client_hello.?.ephemeral);
}

test "handshake nested server hello roundtrip" {
    const eph = [_]u8{0x11} ** 32;
    const static_ct = [_]u8{0x22} ** 48;
    const payload_ct = [_]u8{0x33} ** 20;
    const m = HandshakeMessage{ .server_hello = .{
        .ephemeral = &eph,
        .static = &static_ct,
        .payload = &payload_ct,
    } };
    const enc = try m.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqual(@as(u8, 0x1A), enc[0]); // field 3 wire 2
    const dec = try HandshakeMessage.decode(std.testing.allocator, enc);
    try std.testing.expect(dec.server_hello != null);
    try std.testing.expectEqualSlices(u8, &eph, dec.server_hello.?.ephemeral);
    try std.testing.expectEqualSlices(u8, &static_ct, dec.server_hello.?.static);
    try std.testing.expectEqualSlices(u8, &payload_ct, dec.server_hello.?.payload);
}

test "handshake nested client finish roundtrip" {
    const st = [_]u8{0x44} ** 48;
    const pl = [_]u8{0x55} ** 16;
    const m = HandshakeMessage{ .client_finish = .{ .static = &st, .payload = &pl } };
    const enc = try m.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqual(@as(u8, 0x22), enc[0]); // field 4 wire 2
    const dec = try HandshakeMessage.decode(std.testing.allocator, enc);
    try std.testing.expect(dec.client_finish != null);
    try std.testing.expectEqualSlices(u8, &st, dec.client_finish.?.static);
    try std.testing.expectEqualSlices(u8, &pl, dec.client_finish.?.payload);
}

test "client payload unpaired encode" {
    const payload = ClientPayload{};
    const enc = try payload.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    try std.testing.expect(enc.len > 0);
    // passive=false field 3 wire 0 → 0x18 0x00
    try std.testing.expectEqual(@as(u8, 0x18), enc[0]);
    try std.testing.expectEqual(@as(u8, 0x00), enc[1]);
    // user_agent field 5 wire 2 → 0x2A
    try std.testing.expectEqual(@as(u8, 0x2A), enc[2]);
    // platform WEB=14 inside user_agent: field 1 wire 0 → 0x08 0x0E
    const ua_len: usize = enc[3];
    try std.testing.expect(ua_len > 2);
    try std.testing.expectEqual(@as(u8, 0x08), enc[4]);
    try std.testing.expectEqual(@as(u8, 0x0E), enc[5]);
    try std.testing.expect(std.mem.indexOfScalar(u8, enc, 0x60) != null); // connectType field 12
    try std.testing.expect(std.mem.indexOfScalar(u8, enc, 0x68) != null); // connectReason field 13
    // pull=true field 33 wire 0 → 0x88 0x02 0x01
    try std.testing.expect(std.mem.indexOf(u8, enc, &[_]u8{ 0x88, 0x02, 0x01 }) != null);
}

// ---------------------------------------------------------------------------
// waAdv pairing protos (pair-success device-identity)
// ADVSignedDeviceIdentityHMAC: details=1 HMAC=2 accountType=3
// ADVSignedDeviceIdentity: details=1 accountSignatureKey=2 accountSignature=3 deviceSignature=4
// ADVDeviceIdentity: rawID=1 timestamp=2 keyIndex=3 accountType=4 deviceType=5
// ---------------------------------------------------------------------------

pub const ADVSignedDeviceIdentityHMAC = struct {
    details: []const u8 = &[_]u8{},
    hmac: []const u8 = &[_]u8{},
    account_type: u32 = 0, // 0=E2EE, 1=HOSTED

    pub fn decode(data: []const u8) !ADVSignedDeviceIdentityHMAC {
        var out = ADVSignedDeviceIdentityHMAC{};
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            switch (t.field) {
                1 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    out.details = try readBytes(data, &idx);
                },
                2 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    out.hmac = try readBytes(data, &idx);
                },
                3 => {
                    if (t.wire != 0) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    out.account_type = @intCast(try readVarint(data, &idx));
                },
                else => try skipField(data, &idx, t.wire),
            }
        }
        return out;
    }

    /// Memory: caller frees.
    pub fn encode(self: ADVSignedDeviceIdentityHMAC, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.details.len > 0) try writeBytes(&buf, allocator, 1, self.details);
        if (self.hmac.len > 0) try writeBytes(&buf, allocator, 2, self.hmac);
        if (self.account_type != 0) try writeVarintField(&buf, allocator, 3, self.account_type);
        return buf.toOwnedSlice(allocator);
    }
};

pub const ADVSignedDeviceIdentity = struct {
    details: []const u8 = &[_]u8{},
    account_signature_key: []const u8 = &[_]u8{},
    account_signature: []const u8 = &[_]u8{},
    device_signature: []const u8 = &[_]u8{},

    pub fn decode(data: []const u8) !ADVSignedDeviceIdentity {
        var out = ADVSignedDeviceIdentity{};
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            if (t.wire != 2) {
                try skipField(data, &idx, t.wire);
                continue;
            }
            const bytes = try readBytes(data, &idx);
            switch (t.field) {
                1 => out.details = bytes,
                2 => out.account_signature_key = bytes,
                3 => out.account_signature = bytes,
                4 => out.device_signature = bytes,
                else => {},
            }
        }
        return out;
    }

    /// Memory: caller frees. `device_signature` included when set.
    pub fn encode(self: ADVSignedDeviceIdentity, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.details.len > 0) try writeBytes(&buf, allocator, 1, self.details);
        if (self.account_signature_key.len > 0) try writeBytes(&buf, allocator, 2, self.account_signature_key);
        if (self.account_signature.len > 0) try writeBytes(&buf, allocator, 3, self.account_signature);
        if (self.device_signature.len > 0) try writeBytes(&buf, allocator, 4, self.device_signature);
        return buf.toOwnedSlice(allocator);
    }
};

pub const ADVDeviceIdentity = struct {
    raw_id: u32 = 0,
    timestamp: u64 = 0,
    key_index: u32 = 0,
    account_type: u32 = 0,
    device_type: u32 = 0,

    pub fn decode(data: []const u8) !ADVDeviceIdentity {
        var out = ADVDeviceIdentity{};
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            if (t.wire != 0) {
                try skipField(data, &idx, t.wire);
                continue;
            }
            const v = try readVarint(data, &idx);
            switch (t.field) {
                1 => out.raw_id = @intCast(v),
                2 => out.timestamp = v,
                3 => out.key_index = @intCast(v),
                4 => out.account_type = @intCast(v),
                5 => out.device_type = @intCast(v),
                else => {},
            }
        }
        return out;
    }

    /// Memory: caller frees.
    pub fn encode(self: ADVDeviceIdentity, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.raw_id != 0) try writeVarintField(&buf, allocator, 1, self.raw_id);
        if (self.timestamp != 0) try writeVarintField(&buf, allocator, 2, self.timestamp);
        if (self.key_index != 0) try writeVarintField(&buf, allocator, 3, self.key_index);
        if (self.account_type != 0) try writeVarintField(&buf, allocator, 4, self.account_type);
        if (self.device_type != 0) try writeVarintField(&buf, allocator, 5, self.device_type);
        return buf.toOwnedSlice(allocator);
    }
};

test "adv hmac container roundtrip" {
    const details = "details-bytes";
    const mac = [_]u8{0xAA} ** 32;
    const m = ADVSignedDeviceIdentityHMAC{ .details = details, .hmac = &mac, .account_type = 0 };
    const enc = try m.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    const dec = try ADVSignedDeviceIdentityHMAC.decode(enc);
    try std.testing.expectEqualStrings(details, dec.details);
    try std.testing.expectEqualSlices(u8, &mac, dec.hmac);
}

// ---------------------------------------------------------------------------
// waE2E Message (conversation=1) + WhatsApp v2 Signal padding
// pad: 1–15 bytes of value=length (whatsmeow padMessage). Unpad for enc v=2.
// ---------------------------------------------------------------------------

pub const MessageKey = struct {
    remote_jid: []const u8 = "",
    from_me: bool = false,
    id: []const u8 = "",
    participant: []const u8 = "",
};

fn decodeMessageKey(data: []const u8) MessageKey {
    var out = MessageKey{};
    var idx: usize = 0;
    while (idx < data.len) {
        const t = nextTag(data, &idx) catch break;
        switch (t.field) {
            1 => {
                if (t.wire != 2) {
                    skipField(data, &idx, t.wire) catch break;
                    continue;
                }
                out.remote_jid = readBytes(data, &idx) catch break;
            },
            2 => {
                if (t.wire != 0) {
                    skipField(data, &idx, t.wire) catch break;
                    continue;
                }
                out.from_me = (readVarint(data, &idx) catch break) != 0;
            },
            3 => {
                if (t.wire != 2) {
                    skipField(data, &idx, t.wire) catch break;
                    continue;
                }
                out.id = readBytes(data, &idx) catch break;
            },
            4 => {
                if (t.wire != 2) {
                    skipField(data, &idx, t.wire) catch break;
                    continue;
                }
                out.participant = readBytes(data, &idx) catch break;
            },
            else => skipField(data, &idx, t.wire) catch break,
        }
    }
    return out;
}

fn nestedStringField(data: []const u8, field: u32) ?[]const u8 {
    var idx: usize = 0;
    while (idx < data.len) {
        const t = nextTag(data, &idx) catch return null;
        if (t.field == field and t.wire == 2) return readBytes(data, &idx) catch null;
        skipField(data, &idx, t.wire) catch return null;
    }
    return null;
}

fn nestedVarintField(data: []const u8, field: u32) ?u32 {
    var idx: usize = 0;
    while (idx < data.len) {
        const t = nextTag(data, &idx) catch return null;
        if (t.field == field and t.wire == 0) {
            const v = readVarint(data, &idx) catch return null;
            return @intCast(v);
        }
        skipField(data, &idx, t.wire) catch return null;
    }
    return null;
}

pub const Geo = struct { lat: f64, lon: f64 };

/// ContextInfo sits at field 17 on ExtendedText / Image / Video / Audio / Document / Sticker.
/// stanzaId=1, participant=2, quotedMessage=3, mentionedJid=15.
fn collectContextInfo(inner: []const u8, out: *Message) void {
    const ctx = nestedStringField(inner, 17) orelse return;
    var idx: usize = 0;
    while (idx < ctx.len) {
        const tag = nextTag(ctx, &idx) catch break;
        if (tag.field == 1 and tag.wire == 2) {
            out.quoted_stanza_id = readBytes(ctx, &idx) catch break;
        } else if (tag.field == 2 and tag.wire == 2) {
            out.quoted_participant = readBytes(ctx, &idx) catch break;
        } else if (tag.field == 3 and tag.wire == 2) {
            const quoted = readBytes(ctx, &idx) catch break;
            const qm = Message.decode(quoted) catch continue;
            out.quoted_text = qm.text();
        } else if (tag.field == 15 and tag.wire == 2) {
            const jid = readBytes(ctx, &idx) catch break;
            if (out.mentioned_jid_count < out.mentioned_jids.len) {
                out.mentioned_jids[out.mentioned_jid_count] = jid;
                out.mentioned_jid_count += 1;
            }
        } else {
            skipField(ctx, &idx, tag.wire) catch break;
        }
    }
}

fn parseLocation(inner: []const u8) ?Geo {
    var lat: ?f64 = null;
    var lon: ?f64 = null;
    var idx: usize = 0;
    while (idx < inner.len) {
        const tag = nextTag(inner, &idx) catch break;
        if (tag.field == 1 and tag.wire == 1) {
            lat = readDouble(inner, &idx) catch break;
        } else if (tag.field == 2 and tag.wire == 1) {
            lon = readDouble(inner, &idx) catch break;
        } else {
            skipField(inner, &idx, tag.wire) catch break;
        }
    }
    if (lat == null or lon == null) return null;
    return .{ .lat = lat.?, .lon = lon.? };
}

fn parseProtocol(inner: []const u8) struct { typ: ?u32, key: MessageKey, edited: ?[]const u8 } {
    var typ: ?u32 = null;
    var key = MessageKey{};
    var edited: ?[]const u8 = null;
    var idx: usize = 0;
    while (idx < inner.len) {
        const tag = nextTag(inner, &idx) catch break;
        if (tag.field == 1 and tag.wire == 2) {
            const kb = readBytes(inner, &idx) catch break;
            key = decodeMessageKey(kb);
        } else if (tag.field == 2 and tag.wire == 0) {
            typ = @intCast(readVarint(inner, &idx) catch break);
        } else if (tag.field == 16 and tag.wire == 2) {
            // ProtocolMessage.editedMessage (MESSAGE_EDIT = 14)
            edited = readBytes(inner, &idx) catch break;
        } else {
            skipField(inner, &idx, tag.wire) catch break;
        }
    }
    return .{ .typ = typ, .key = key, .edited = edited };
}

fn overlayMessage(dst: *Message, src: Message) void {
    if (dst.conversation == null) dst.conversation = src.conversation;
    if (dst.extended_text == null) dst.extended_text = src.extended_text;
    if (dst.caption == null) dst.caption = src.caption;
    if (dst.media == null) dst.media = src.media;
    if (dst.device_sent == null) dst.device_sent = src.device_sent;
    if (dst.protocol_type == null) dst.protocol_type = src.protocol_type;
    if (dst.protocol_key.id.len == 0 and src.protocol_key.id.len > 0) dst.protocol_key = src.protocol_key;
    if (dst.has_sender_key_distribution) dst.has_sender_key_distribution = src.has_sender_key_distribution;
    if (dst.sender_key_distribution == null) dst.sender_key_distribution = src.sender_key_distribution;
    if (dst.reaction == null) dst.reaction = src.reaction;
    if (dst.mentioned_jid_count == 0 and src.mentioned_jid_count > 0) {
        dst.mentioned_jids = src.mentioned_jids;
        dst.mentioned_jid_count = src.mentioned_jid_count;
    }
    if (dst.quoted_stanza_id == null) dst.quoted_stanza_id = src.quoted_stanza_id;
    if (dst.quoted_participant == null) dst.quoted_participant = src.quoted_participant;
    if (dst.quoted_text == null) dst.quoted_text = src.quoted_text;
    if (dst.location == null) dst.location = src.location;
    if (dst.poll_name == null) dst.poll_name = src.poll_name;
}

/// Per-kind field numbers verified against whatsmeow WAWebProtobufsE2E.proto
/// and WhatsApp web WAProto.proto (both agree):
/// image 3{url=1,mimetype=2,caption=3,fileSha256=4,fileLength=5,height=6,width=7,
/// mediaKey=8,fileEncSha256=9,directPath=11}; video 9{url=1,mimetype=2,fileSha256=3,
/// fileLength=4,seconds=5,mediaKey=6,caption=7,height=9,width=10,fileEncSha256=11,
/// directPath=13}; audio 8{url=1,mimetype=2,fileSha256=3,fileLength=4,seconds=5,ptt=6,
/// mediaKey=7,fileEncSha256=8,directPath=9}; document 7{url=1,mimetype=2,title=3,
/// fileSha256=4,fileLength=5,pageCount=6,mediaKey=7,fileName=8,fileEncSha256=9,
/// directPath=10}; sticker 26{url=1,fileSha256=2,fileEncSha256=3,mediaKey=4,
/// mimetype=5,height=6,width=7,directPath=8,fileLength=9,mediaKeyTimestamp=10}.
pub const Media = struct {
    pub const Kind = enum { image, video, audio, document, sticker };
    kind: Kind,
    url: ?[]const u8 = null,
    mimetype: ?[]const u8 = null,
    media_key: ?[]const u8 = null,
    file_sha256: ?[]const u8 = null,
    file_enc_sha256: ?[]const u8 = null,
    direct_path: ?[]const u8 = null,
    file_len: u64 = 0,
    seconds: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    ptt: bool = false,
    title: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
};

/// Message{senderKeyDistributionMessage=2{groupId=1, axolotlSenderKeyDistributionMessage=2}}.
pub const SenderKeyDistribution = struct {
    group_id: []const u8,
    axolotl: []const u8,
};

fn varintU32(data: []const u8, idx: *usize) u32 {
    const v = readVarint(data, idx) catch return 0;
    return std.math.cast(u32, v) orelse 0;
}

fn parseMediaInner(kind: Media.Kind, inner: []const u8) Media {
    var m = Media{ .kind = kind };
    var idx: usize = 0;
    while (idx < inner.len) {
        const t = nextTag(inner, &idx) catch break;
        switch (kind) {
            .image => switch (t.field) {
                1 => if (t.wire == 2) {
                    m.url = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                2 => if (t.wire == 2) {
                    m.mimetype = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                4 => if (t.wire == 2) {
                    m.file_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                5 => if (t.wire == 0) {
                    m.file_len = readVarint(inner, &idx) catch 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                6 => if (t.wire == 0) {
                    m.height = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                7 => if (t.wire == 0) {
                    m.width = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                8 => if (t.wire == 2) {
                    m.media_key = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                9 => if (t.wire == 2) {
                    m.file_enc_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                11 => if (t.wire == 2) {
                    m.direct_path = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                else => skipField(inner, &idx, t.wire) catch break,
            },
            .video => switch (t.field) {
                1 => if (t.wire == 2) {
                    m.url = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                2 => if (t.wire == 2) {
                    m.mimetype = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                3 => if (t.wire == 2) {
                    m.file_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                4 => if (t.wire == 0) {
                    m.file_len = readVarint(inner, &idx) catch 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                5 => if (t.wire == 0) {
                    m.seconds = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                6 => if (t.wire == 2) {
                    m.media_key = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                9 => if (t.wire == 0) {
                    m.height = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                10 => if (t.wire == 0) {
                    m.width = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                11 => if (t.wire == 2) {
                    m.file_enc_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                13 => if (t.wire == 2) {
                    m.direct_path = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                else => skipField(inner, &idx, t.wire) catch break,
            },
            .audio => switch (t.field) {
                1 => if (t.wire == 2) {
                    m.url = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                2 => if (t.wire == 2) {
                    m.mimetype = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                3 => if (t.wire == 2) {
                    m.file_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                4 => if (t.wire == 0) {
                    m.file_len = readVarint(inner, &idx) catch 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                5 => if (t.wire == 0) {
                    m.seconds = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                6 => if (t.wire == 0) {
                    m.ptt = (readVarint(inner, &idx) catch 0) != 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                7 => if (t.wire == 2) {
                    m.media_key = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                8 => if (t.wire == 2) {
                    m.file_enc_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                9 => if (t.wire == 2) {
                    m.direct_path = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                else => skipField(inner, &idx, t.wire) catch break,
            },
            .document => switch (t.field) {
                1 => if (t.wire == 2) {
                    m.url = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                2 => if (t.wire == 2) {
                    m.mimetype = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                3 => if (t.wire == 2) {
                    m.title = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                4 => if (t.wire == 2) {
                    m.file_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                5 => if (t.wire == 0) {
                    m.file_len = readVarint(inner, &idx) catch 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                7 => if (t.wire == 2) {
                    m.media_key = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                8 => if (t.wire == 2) {
                    m.file_name = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                9 => if (t.wire == 2) {
                    m.file_enc_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                10 => if (t.wire == 2) {
                    m.direct_path = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                else => skipField(inner, &idx, t.wire) catch break,
            },
            .sticker => switch (t.field) {
                1 => if (t.wire == 2) {
                    m.url = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                2 => if (t.wire == 2) {
                    m.file_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                3 => if (t.wire == 2) {
                    m.file_enc_sha256 = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                4 => if (t.wire == 2) {
                    m.media_key = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                5 => if (t.wire == 2) {
                    m.mimetype = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                6 => if (t.wire == 0) {
                    m.height = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                7 => if (t.wire == 0) {
                    m.width = varintU32(inner, &idx);
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                8 => if (t.wire == 2) {
                    m.direct_path = readBytes(inner, &idx) catch break;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                9 => if (t.wire == 0) {
                    m.file_len = readVarint(inner, &idx) catch 0;
                } else {
                    skipField(inner, &idx, t.wire) catch break;
                },
                else => skipField(inner, &idx, t.wire) catch break,
            },
        }
    }
    return m;
}
pub const Message = struct {
    conversation: ?[]const u8 = null,
    extended_text: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    media: ?Media = null,
    device_sent: ?struct { destination_jid: []const u8, message: []const u8 } = null,
    protocol_type: ?u32 = null,
    protocol_key: MessageKey = .{},
    has_sender_key_distribution: bool = false,
    sender_key_distribution: ?SenderKeyDistribution = null,
    reaction: ?struct { key: MessageKey, text: []const u8 } = null,
    mentioned_jids: [16][]const u8 = [_][]const u8{&[_]u8{}} ** 16,
    mentioned_jid_count: u8 = 0,
    quoted_stanza_id: ?[]const u8 = null,
    quoted_participant: ?[]const u8 = null,
    quoted_text: ?[]const u8 = null,
    location: ?Geo = null,
    poll_name: ?[]const u8 = null,

    fn decodeFields(data: []const u8, unwrap: bool) !Message {
        var out = Message{};
        var wrapper: ?[]const u8 = null;
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            switch (t.field) {
                1 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    out.conversation = try readBytes(data, &idx);
                },
                2 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.has_sender_key_distribution = true;
                    out.sender_key_distribution = .{
                        .group_id = nestedStringField(inner, 1) orelse "",
                        .axolotl = nestedStringField(inner, 2) orelse "",
                    };
                },
                3 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.media = parseMediaInner(.image, inner);
                    if (nestedStringField(inner, 3)) |c| out.caption = c;
                    collectContextInfo(inner, &out);
                },
                5 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.location = parseLocation(inner);
                    collectContextInfo(inner, &out);
                },
                6 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.extended_text = nestedStringField(inner, 1);
                    collectContextInfo(inner, &out);
                },
                7 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.media = parseMediaInner(.document, inner);
                    if (nestedStringField(inner, 20)) |c| out.caption = c;
                    collectContextInfo(inner, &out);
                },
                8 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.media = parseMediaInner(.audio, inner);
                    collectContextInfo(inner, &out);
                },
                9 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.media = parseMediaInner(.video, inner);
                    if (nestedStringField(inner, 7)) |c| out.caption = c;
                    collectContextInfo(inner, &out);
                },
                12 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    const proto_info = parseProtocol(inner);
                    out.protocol_type = proto_info.typ;
                    out.protocol_key = proto_info.key;
                    if (proto_info.edited) |eb| {
                        const edited_msg = decodeFields(eb, true) catch Message{};
                        overlayMessage(&out, edited_msg);
                    }
                },
                26 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.media = parseMediaInner(.sticker, inner);
                    collectContextInfo(inner, &out);
                },
                31 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.device_sent = .{
                        .destination_jid = nestedStringField(inner, 1) orelse "",
                        .message = nestedStringField(inner, 2) orelse "",
                    };
                },
                37, 40, 53, 55, 58 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    if (wrapper == null) wrapper = inner;
                },
                46 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    var key = MessageKey{};
                    var rxn_text: []const u8 = "";
                    var j: usize = 0;
                    while (j < inner.len) {
                        const rt = nextTag(inner, &j) catch break;
                        if (rt.field == 1 and rt.wire == 2) {
                            const kb = readBytes(inner, &j) catch break;
                            key = decodeMessageKey(kb);
                        } else if (rt.field == 2 and rt.wire == 2) {
                            rxn_text = readBytes(inner, &j) catch break;
                        } else {
                            skipField(inner, &j, rt.wire) catch break;
                        }
                    }
                    out.reaction = .{ .key = key, .text = rxn_text };
                },
                49, 51 => {
                    if (t.wire != 2) {
                        try skipField(data, &idx, t.wire);
                        continue;
                    }
                    const inner = try readBytes(data, &idx);
                    out.poll_name = nestedStringField(inner, 2);
                    collectContextInfo(inner, &out);
                },
                else => try skipField(data, &idx, t.wire),
            }
        }
        if (unwrap) {
            if (wrapper) |w| {
                if (nestedStringField(w, 1)) |inner_bytes| {
                    const inner = decodeFields(inner_bytes, false) catch Message{};
                    overlayMessage(&out, inner);
                }
            }
        }
        return out;
    }

    /// Slices alias `data`. Unwraps ephemeral/viewOnce/viewOnceV2/edited/documentWithCaption one level.
    pub fn decode(data: []const u8) !Message {
        if (data.len == 0) return Message{};
        return decodeFields(data, true);
    }

    pub fn text(self: Message) ?[]const u8 {
        return self.conversation orelse self.extended_text orelse self.caption orelse self.poll_name;
    }

    /// Memory: caller frees. Message{conversation=1}.
    pub fn encodeText(allocator: std.mem.Allocator, text_val: []const u8) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 1, text_val);
        return buf.toOwnedSlice(allocator);
    }

    pub const TextOpts = struct {
        mentions: []const []const u8 = &.{},
        quoted_stanza_id: ?[]const u8 = null,
        quoted_participant: ?[]const u8 = null,
        quoted_text: ?[]const u8 = null,
    };

    /// conversation=1 when there is no context; otherwise extendedTextMessage=6
    /// with ContextInfo (stanzaId=1, participant=2, quotedMessage=3, mentionedJid=15).
    /// Memory: caller frees.
    pub fn encodeTextWith(allocator: std.mem.Allocator, text_val: []const u8, opts: TextOpts) ![]u8 {
        const has_quote = if (opts.quoted_stanza_id) |id| id.len > 0 else false;
        if (opts.mentions.len == 0 and !has_quote) return encodeText(allocator, text_val);

        var ctx = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer ctx.deinit(allocator);
        if (has_quote) {
            try writeBytes(&ctx, allocator, 1, opts.quoted_stanza_id.?);
            if (opts.quoted_participant) |part| if (part.len > 0) try writeBytes(&ctx, allocator, 2, part);
            if (opts.quoted_text) |qt| if (qt.len > 0) {
                var qmsg = try std.ArrayList(u8).initCapacity(allocator, 0);
                defer qmsg.deinit(allocator);
                try writeBytes(&qmsg, allocator, 1, qt);
                try writeBytes(&ctx, allocator, 3, qmsg.items);
            };
        }
        for (opts.mentions) |mjid| {
            if (mjid.len > 0) try writeBytes(&ctx, allocator, 15, mjid);
        }

        var inner = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer inner.deinit(allocator);
        try writeBytes(&inner, allocator, 1, text_val);
        if (ctx.items.len > 0) try writeBytes(&inner, allocator, 17, ctx.items);

        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 6, inner.items);
        return buf.toOwnedSlice(allocator);
    }

    /// Memory: caller frees. Message{locationMessage=5{degreesLatitude=1, degreesLongitude=2}}.
    pub fn encodeLocation(allocator: std.mem.Allocator, lat: f64, lon: f64) ![]u8 {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer inner.deinit(allocator);
        try writeDouble(&inner, allocator, 1, lat);
        try writeDouble(&inner, allocator, 2, lon);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 5, inner.items);
        return buf.toOwnedSlice(allocator);
    }

    /// Memory: caller frees. Message{deviceSentMessage=31{destinationJid=1, message=2}}.
    pub fn encodeDeviceSent(allocator: std.mem.Allocator, destination_jid: []const u8, inner: []const u8) ![]u8 {
        var dsm = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer dsm.deinit(allocator);
        try writeBytes(&dsm, allocator, 1, destination_jid);
        try writeBytes(&dsm, allocator, 2, inner);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 31, dsm.items);
        const owned = try buf.toOwnedSlice(allocator);
        dsm.deinit(allocator);
        return owned;
    }

    /// Memory: caller frees. Message{senderKeyDistributionMessage=2{groupId=1, axolotl=2}}.
    pub fn encodeSenderKeyDistribution(allocator: std.mem.Allocator, group_id: []const u8, axolotl: []const u8) ![]u8 {
        var skdm = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer skdm.deinit(allocator);
        try writeBytes(&skdm, allocator, 1, group_id);
        try writeBytes(&skdm, allocator, 2, axolotl);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeTag(&buf, allocator, 2, 2);
        try writeVarint(&buf, allocator, skdm.items.len);
        try buf.appendSlice(allocator, skdm.items);
        skdm.deinit(allocator);
        return buf.toOwnedSlice(allocator);
    }

    /// Memory: caller frees. Message{reactionMessage=46{key=1, text=2}}.
    pub fn encodeReaction(
        allocator: std.mem.Allocator,
        remote_jid: []const u8,
        from_me: bool,
        id: []const u8,
        participant: ?[]const u8,
        emoji: []const u8,
    ) ![]u8 {
        var key = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer key.deinit(allocator);
        try writeBytes(&key, allocator, 1, remote_jid);
        try writeBoolField(&key, allocator, 2, from_me);
        try writeBytes(&key, allocator, 3, id);
        if (participant) |p| if (p.len > 0) try writeBytes(&key, allocator, 4, p);
        var rxn = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer rxn.deinit(allocator);
        try writeBytes(&rxn, allocator, 1, key.items);
        try writeBytes(&rxn, allocator, 2, emoji);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 46, rxn.items);
        const owned = try buf.toOwnedSlice(allocator);
        rxn.deinit(allocator);
        key.deinit(allocator);
        return owned;
    }

    pub const MediaEncode = struct {
        kind: Media.Kind,
        url: []const u8 = "",
        direct_path: []const u8,
        mimetype: []const u8,
        caption: ?[]const u8 = null,
        media_key: []const u8,
        file_sha256: []const u8,
        file_enc_sha256: []const u8,
        file_len: u64,
        media_key_timestamp: i64,
        file_name: ?[]const u8 = null,
        ptt: bool = false,
    };

    /// Memory: caller frees. Image/video/audio/document/sticker Message.
    pub fn encodeMedia(allocator: std.mem.Allocator, m: MediaEncode) ![]u8 {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer inner.deinit(allocator);
        const url = if (m.url.len > 0) m.url else m.direct_path;
        switch (m.kind) {
            .image => {
                try writeBytes(&inner, allocator, 1, url);
                try writeBytes(&inner, allocator, 2, m.mimetype);
                if (m.caption) |c| if (c.len > 0) try writeBytes(&inner, allocator, 3, c);
                try writeBytes(&inner, allocator, 4, m.file_sha256);
                try writeVarintField(&inner, allocator, 5, m.file_len);
                try writeBytes(&inner, allocator, 8, m.media_key);
                try writeBytes(&inner, allocator, 9, m.file_enc_sha256);
                try writeBytes(&inner, allocator, 11, m.direct_path);
                try writeVarintField(&inner, allocator, 12, @bitCast(m.media_key_timestamp));
            },
            .video => {
                try writeBytes(&inner, allocator, 1, url);
                try writeBytes(&inner, allocator, 2, m.mimetype);
                try writeBytes(&inner, allocator, 3, m.file_sha256);
                try writeVarintField(&inner, allocator, 4, m.file_len);
                try writeBytes(&inner, allocator, 6, m.media_key);
                if (m.caption) |c| if (c.len > 0) try writeBytes(&inner, allocator, 7, c);
                try writeBytes(&inner, allocator, 11, m.file_enc_sha256);
                try writeBytes(&inner, allocator, 13, m.direct_path);
                try writeVarintField(&inner, allocator, 14, @bitCast(m.media_key_timestamp));
            },
            .audio => {
                try writeBytes(&inner, allocator, 1, url);
                try writeBytes(&inner, allocator, 2, m.mimetype);
                try writeBytes(&inner, allocator, 3, m.file_sha256);
                try writeVarintField(&inner, allocator, 4, m.file_len);
                if (m.ptt) try writeBoolField(&inner, allocator, 6, true);
                try writeBytes(&inner, allocator, 7, m.media_key);
                try writeBytes(&inner, allocator, 8, m.file_enc_sha256);
                try writeBytes(&inner, allocator, 9, m.direct_path);
                try writeVarintField(&inner, allocator, 10, @bitCast(m.media_key_timestamp));
            },
            .document => {
                try writeBytes(&inner, allocator, 1, url);
                try writeBytes(&inner, allocator, 2, m.mimetype);
                try writeBytes(&inner, allocator, 4, m.file_sha256);
                try writeVarintField(&inner, allocator, 5, m.file_len);
                try writeBytes(&inner, allocator, 7, m.media_key);
                if (m.file_name) |n| try writeBytes(&inner, allocator, 8, n);
                try writeBytes(&inner, allocator, 9, m.file_enc_sha256);
                try writeBytes(&inner, allocator, 10, m.direct_path);
                try writeVarintField(&inner, allocator, 11, @bitCast(m.media_key_timestamp));
                if (m.caption) |c| if (c.len > 0) try writeBytes(&inner, allocator, 20, c);
            },
            .sticker => {
                try writeBytes(&inner, allocator, 1, url);
                try writeBytes(&inner, allocator, 2, m.file_sha256);
                try writeBytes(&inner, allocator, 3, m.file_enc_sha256);
                try writeBytes(&inner, allocator, 4, m.media_key);
                try writeBytes(&inner, allocator, 5, m.mimetype);
                try writeBytes(&inner, allocator, 8, m.direct_path);
                try writeVarintField(&inner, allocator, 9, m.file_len);
                try writeVarintField(&inner, allocator, 10, @bitCast(m.media_key_timestamp));
            },
        }
        const field: u32 = switch (m.kind) {
            .image => 3,
            .video => 9,
            .audio => 8,
            .document => 7,
            .sticker => 26,
        };
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, field, inner.items);
        const owned = try buf.toOwnedSlice(allocator);
        inner.deinit(allocator);
        return owned;
    }

    /// Memory: caller frees. Message{pollCreationMessage=49{encKey=1, name=2, options=3, selectable=4}}.
    /// Field 49 is WAProto pollCreationMessage; 51 is pollCreationMessageV3 / keepInChat (decode both).
    pub fn encodePoll(
        allocator: std.mem.Allocator,
        name: []const u8,
        options: []const []const u8,
        selectable: u32,
        enc_key: []const u8,
    ) ![]u8 {
        var inner = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer inner.deinit(allocator);
        try writeBytes(&inner, allocator, 1, enc_key);
        try writeBytes(&inner, allocator, 2, name);
        for (options) |opt| {
            var opt_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
            defer opt_buf.deinit(allocator);
            try writeBytes(&opt_buf, allocator, 1, opt);
            try writeBytes(&inner, allocator, 3, opt_buf.items);
        }
        try writeVarintField(&inner, allocator, 4, selectable);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        try writeBytes(&buf, allocator, 49, inner.items);
        const owned = try buf.toOwnedSlice(allocator);
        inner.deinit(allocator);
        return owned;
    }
};

pub const ConversationMessage = struct {
    conversation: []const u8 = &[_]u8{},

    /// Memory: caller frees.
    pub fn encode(self: ConversationMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.conversation.len > 0) try writeBytes(&buf, allocator, 1, self.conversation);
        return buf.toOwnedSlice(allocator);
    }

    /// `conversation` aliases `data`.
    pub fn decode(data: []const u8) !ConversationMessage {
        var out = ConversationMessage{};
        var idx: usize = 0;
        while (idx < data.len) {
            const t = try nextTag(data, &idx);
            if (t.field == 1 and t.wire == 2) {
                out.conversation = try readBytes(data, &idx);
            } else {
                try skipField(data, &idx, t.wire);
            }
        }
        return out;
    }
};

/// Memory: caller frees. `pad_len` must be 1..=15.
pub fn padMessage(allocator: std.mem.Allocator, plaintext: []const u8, pad_len: u8) ![]u8 {
    if (pad_len == 0 or pad_len > 15) return error.InvalidPadding;
    const out = try allocator.alloc(u8, plaintext.len + pad_len);
    @memcpy(out[0..plaintext.len], plaintext);
    @memset(out[plaintext.len..], pad_len);
    return out;
}

pub fn padMessageRandom(allocator: std.mem.Allocator, plaintext: []const u8, io: std.Io) ![]u8 {
    var b: [1]u8 = undefined;
    io.random(&b);
    var n: u8 = b[0] & 0x0f;
    if (n == 0) n = 0x0f;
    return padMessage(allocator, plaintext, n);
}

/// Alias into `plaintext` (no alloc). Version 3 is unpadded.
pub fn unpadMessage(plaintext: []const u8, version: u32) ![]const u8 {
    if (version == 3) return plaintext;
    if (plaintext.len == 0) return error.InvalidPadding;
    const n = plaintext[plaintext.len - 1];
    if (n == 0 or n > 15 or n > plaintext.len) return error.InvalidPadding;
    var i: usize = plaintext.len - n;
    while (i < plaintext.len) : (i += 1) {
        if (plaintext[i] != n) return error.InvalidPadding;
    }
    return plaintext[0 .. plaintext.len - n];
}

test "conversation message roundtrip" {
    const msg = ConversationMessage{ .conversation = "hi barvis" };
    const enc = try msg.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    const dec = try ConversationMessage.decode(enc);
    try std.testing.expectEqualStrings("hi barvis", dec.conversation);
}

test "whatsapp v2 pad/unpad" {
    const pt = "hello";
    const padded = try padMessage(std.testing.allocator, pt, 7);
    defer std.testing.allocator.free(padded);
    try std.testing.expectEqual(@as(usize, 12), padded.len);
    const up = try unpadMessage(padded, 2);
    try std.testing.expectEqualStrings(pt, up);
}

test "Message decode conversation" {
    const alloc = std.testing.allocator;
    const enc = try Message.encodeText(alloc, "hi barvis");
    defer alloc.free(enc);
    const msg = try Message.decode(enc);
    try std.testing.expectEqualStrings("hi barvis", msg.conversation.?);
    try std.testing.expectEqualStrings("hi barvis", msg.text().?);
}

test "Message decode extendedText" {
    const alloc = std.testing.allocator;
    var inner = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer inner.deinit(alloc);
    try writeBytes(&inner, alloc, 1, "hello");
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 6, inner.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("hello", msg.extended_text.?);
    try std.testing.expectEqualStrings("hello", msg.text().?);
}

test "Message decode extendedText mentionedJid" {
    const alloc = std.testing.allocator;
    var ctx = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer ctx.deinit(alloc);
    try writeBytes(&ctx, alloc, 15, "216638251077681@lid");
    try writeBytes(&ctx, alloc, 15, "917019895010@s.whatsapp.net");
    var inner = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer inner.deinit(alloc);
    try writeBytes(&inner, alloc, 1, "@barvis yo?");
    try writeBytes(&inner, alloc, 17, ctx.items);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 6, inner.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("@barvis yo?", msg.extended_text.?);
    try std.testing.expectEqual(@as(u8, 2), msg.mentioned_jid_count);
    try std.testing.expectEqualStrings("216638251077681@lid", msg.mentioned_jids[0]);
    try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", msg.mentioned_jids[1]);
}

test "Message encodeTextWith mentions and quote roundtrip" {
    const alloc = std.testing.allocator;
    const mentions = [_][]const u8{ "216638251077681@lid", "917019895010@s.whatsapp.net" };
    const blob = try Message.encodeTextWith(alloc, "@barvis yo?", .{
        .mentions = &mentions,
        .quoted_stanza_id = "MSGID",
        .quoted_participant = "p@lid",
        .quoted_text = "hello",
    });
    defer alloc.free(blob);
    const msg = try Message.decode(blob);
    try std.testing.expectEqualStrings("@barvis yo?", msg.extended_text.?);
    try std.testing.expectEqual(@as(u8, 2), msg.mentioned_jid_count);
    try std.testing.expectEqualStrings("216638251077681@lid", msg.mentioned_jids[0]);
    try std.testing.expectEqualStrings("MSGID", msg.quoted_stanza_id.?);
    try std.testing.expectEqualStrings("p@lid", msg.quoted_participant.?);
    try std.testing.expectEqualStrings("hello", msg.quoted_text.?);
}

test "Message decode location" {
    const alloc = std.testing.allocator;
    var inner = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer inner.deinit(alloc);
    try writeDouble(&inner, alloc, 1, 12.5);
    try writeDouble(&inner, alloc, 2, 77.25);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 5, inner.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expect(msg.location != null);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), msg.location.?.lat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 77.25), msg.location.?.lon, 1e-9);
}

test "Message encodeLocation roundtrip" {
    const alloc = std.testing.allocator;
    const enc = try Message.encodeLocation(alloc, 12.5, 77.25);
    defer alloc.free(enc);
    const msg = try Message.decode(enc);
    try std.testing.expect(msg.location != null);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), msg.location.?.lat, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 77.25), msg.location.?.lon, 1e-9);
}

test "Message encodePoll uses field 49 and roundtrips name" {
    const alloc = std.testing.allocator;
    const enc_key = [_]u8{0x11} ** 32;
    const options = [_][]const u8{ "yes", "no" };
    const blob = try Message.encodePoll(alloc, "lunch?", &options, 1, &enc_key);
    defer alloc.free(blob);
    var idx: usize = 0;
    const tag = try readVarint(blob, &idx);
    try std.testing.expectEqual(@as(u64, (49 << 3) | 2), tag);
    const msg = try Message.decode(blob);
    try std.testing.expectEqualStrings("lunch?", msg.poll_name.?);
}

test "Message decode poll field 51 legacy keepInChat" {
    const alloc = std.testing.allocator;
    var inner = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer inner.deinit(alloc);
    try writeBytes(&inner, alloc, 2, "legacy-poll");
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 51, inner.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("legacy-poll", msg.poll_name.?);
}

test "Message encodeReaction roundtrip" {
    const alloc = std.testing.allocator;
    const enc = try Message.encodeReaction(alloc, "120363@g.us", false, "MSGID", "p@lid", "👍");
    defer alloc.free(enc);
    const msg = try Message.decode(enc);
    try std.testing.expectEqualStrings("👍", msg.reaction.?.text);
    try std.testing.expectEqualStrings("MSGID", msg.reaction.?.key.id);
    try std.testing.expectEqualStrings("120363@g.us", msg.reaction.?.key.remote_jid);
    try std.testing.expect(!msg.reaction.?.key.from_me);
    try std.testing.expectEqualStrings("p@lid", msg.reaction.?.key.participant);
}

test "Message encodeMedia image roundtrip" {
    const alloc = std.testing.allocator;
    const key = [_]u8{0x11} ** 32;
    const sha = [_]u8{0x22} ** 32;
    const enc_sha = [_]u8{0x33} ** 32;
    const blob = try Message.encodeMedia(alloc, .{
        .kind = .image,
        .direct_path = "/v/t62/x",
        .mimetype = "image/jpeg",
        .caption = "hi",
        .media_key = &key,
        .file_sha256 = &sha,
        .file_enc_sha256 = &enc_sha,
        .file_len = 99,
        .media_key_timestamp = 1700000000,
    });
    defer alloc.free(blob);
    const msg = try Message.decode(blob);
    try std.testing.expectEqualStrings("hi", msg.caption.?);
    try std.testing.expect(msg.media != null);
    try std.testing.expectEqual(Media.Kind.image, msg.media.?.kind);
    try std.testing.expectEqualStrings("/v/t62/x", msg.media.?.direct_path.?);
    try std.testing.expectEqual(@as(u64, 99), msg.media.?.file_len);
}

test "Message decode deviceSent nested inner decodes to text" {
    const alloc = std.testing.allocator;
    const inner = try Message.encodeText(alloc, "inner-text");
    defer alloc.free(inner);
    const outer = try Message.encodeDeviceSent(alloc, "1555@s.whatsapp.net", inner);
    defer alloc.free(outer);
    const msg = try Message.decode(outer);
    try std.testing.expect(msg.device_sent != null);
    try std.testing.expectEqualStrings("1555@s.whatsapp.net", msg.device_sent.?.destination_jid);
    const nested = try Message.decode(msg.device_sent.?.message);
    try std.testing.expectEqualStrings("inner-text", nested.text().?);
}

test "Message decode ephemeral-wrapped text" {
    const alloc = std.testing.allocator;
    const inner = try Message.encodeText(alloc, "secret");
    defer alloc.free(inner);
    var fp = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer fp.deinit(alloc);
    try writeBytes(&fp, alloc, 1, inner);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 40, fp.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("secret", msg.text().?);
}

test "Message decode reaction" {
    const alloc = std.testing.allocator;
    var key = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer key.deinit(alloc);
    try writeBytes(&key, alloc, 1, "chat@s.whatsapp.net");
    try writeBoolField(&key, alloc, 2, true);
    try writeBytes(&key, alloc, 3, "MSGID");
    try writeBytes(&key, alloc, 4, "p@s.whatsapp.net");
    var rxn = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer rxn.deinit(alloc);
    try writeBytes(&rxn, alloc, 1, key.items);
    try writeBytes(&rxn, alloc, 2, "thumbs");
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 46, rxn.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("thumbs", msg.reaction.?.text);
    try std.testing.expectEqualStrings("MSGID", msg.reaction.?.key.id);
    try std.testing.expectEqualStrings("chat@s.whatsapp.net", msg.reaction.?.key.remote_jid);
    try std.testing.expect(msg.reaction.?.key.from_me);
    try std.testing.expectEqualStrings("p@s.whatsapp.net", msg.reaction.?.key.participant);
}

test "Message decode protocol" {
    const alloc = std.testing.allocator;
    var proto_msg = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer proto_msg.deinit(alloc);
    try writeVarintField(&proto_msg, alloc, 2, 5);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 12, proto_msg.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqual(@as(u32, 5), msg.protocol_type.?);
}

test "Message decode protocol revoke key" {
    const alloc = std.testing.allocator;
    var key = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer key.deinit(alloc);
    try writeBytes(&key, alloc, 1, "120363425058847361@g.us");
    try writeBytes(&key, alloc, 3, "DEADMSG");
    try writeBytes(&key, alloc, 4, "p@lid");
    var proto_msg = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer proto_msg.deinit(alloc);
    try writeBytes(&proto_msg, alloc, 1, key.items);
    try writeVarintField(&proto_msg, alloc, 2, 0);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 12, proto_msg.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqual(@as(u32, 0), msg.protocol_type.?);
    try std.testing.expectEqualStrings("DEADMSG", msg.protocol_key.id);
    try std.testing.expectEqualStrings("p@lid", msg.protocol_key.participant);
}

test "Message decode protocol edit overlays new text" {
    const alloc = std.testing.allocator;
    const inner_text = try Message.encodeText(alloc, "edited body");
    defer alloc.free(inner_text);
    var key = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer key.deinit(alloc);
    try writeBytes(&key, alloc, 3, "ORIGID");
    var proto_msg = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer proto_msg.deinit(alloc);
    try writeBytes(&proto_msg, alloc, 1, key.items);
    try writeVarintField(&proto_msg, alloc, 2, 14);
    try writeBytes(&proto_msg, alloc, 16, inner_text);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 12, proto_msg.items);
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqual(@as(u32, 14), msg.protocol_type.?);
    try std.testing.expectEqualStrings("ORIGID", msg.protocol_key.id);
    try std.testing.expectEqualStrings("edited body", msg.text().?);
}

test "Message decode empty and unknown fields" {
    const empty = try Message.decode(&[_]u8{});
    try std.testing.expect(empty.conversation == null);
    try std.testing.expect(empty.text() == null);
    const alloc = std.testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeBytes(&buf, alloc, 99, "xxx");
    try writeBytes(&buf, alloc, 1, "kept");
    const msg = try Message.decode(buf.items);
    try std.testing.expectEqualStrings("kept", msg.conversation.?);
    try std.testing.expect(!msg.has_sender_key_distribution);
}

test "Message SKDM roundtrip" {
    const alloc = std.testing.allocator;
    const ax = [_]u8{ 0x33, 0x08, 0x01 } ++ [_]u8{0xAB} ** 10;
    const enc = try Message.encodeSenderKeyDistribution(alloc, "120363421845733873@g.us", &ax);
    defer alloc.free(enc);
    const msg = try Message.decode(enc);
    try std.testing.expect(msg.sender_key_distribution != null);
    try std.testing.expectEqualStrings("120363421845733873@g.us", msg.sender_key_distribution.?.group_id);
    try std.testing.expectEqualSlices(u8, &ax, msg.sender_key_distribution.?.axolotl);
}

test "Message image media fields decode" {
    const alloc = std.testing.allocator;
    var img = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer img.deinit(alloc);
    try writeBytes(&img, alloc, 1, "https://mmg/abc.jpg");
    try writeBytes(&img, alloc, 2, "image/jpeg");
    try writeBytes(&img, alloc, 3, "a caption");
    try writeBytes(&img, alloc, 4, &[_]u8{0x11} ** 32);
    try writeTag(&img, alloc, 5, 0);
    try writeVarint(&img, alloc, 12345);
    try writeTag(&img, alloc, 6, 0);
    try writeVarint(&img, alloc, 100);
    try writeTag(&img, alloc, 7, 0);
    try writeVarint(&img, alloc, 200);
    try writeBytes(&img, alloc, 8, &[_]u8{0x22} ** 32);
    try writeBytes(&img, alloc, 9, &[_]u8{0x33} ** 32);
    try writeBytes(&img, alloc, 11, "/v/t62/abc");
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeTag(&buf, alloc, 3, 2);
    try writeVarint(&buf, alloc, img.items.len);
    try buf.appendSlice(alloc, img.items);
    const msg = try Message.decode(buf.items);
    const m = msg.media orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Media.Kind.image, m.kind);
    try std.testing.expectEqualStrings("https://mmg/abc.jpg", m.url.?);
    try std.testing.expectEqualStrings("image/jpeg", m.mimetype.?);
    try std.testing.expectEqualStrings("a caption", msg.caption.?);
    try std.testing.expectEqual(@as(u64, 12345), m.file_len);
    try std.testing.expectEqual(@as(u32, 100), m.height);
    try std.testing.expectEqual(@as(u32, 200), m.width);
    try std.testing.expectEqual(@as(usize, 32), m.media_key.?.len);
    try std.testing.expectEqualStrings("/v/t62/abc", m.direct_path.?);
}

test "Message sticker media fields decode" {
    const alloc = std.testing.allocator;
    var inner = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer inner.deinit(alloc);
    try writeBytes(&inner, alloc, 1, "https://mmg/sticker.webp");
    try writeBytes(&inner, alloc, 2, &[_]u8{0x11} ** 32);
    try writeBytes(&inner, alloc, 3, &[_]u8{0x22} ** 32);
    try writeBytes(&inner, alloc, 4, &[_]u8{0x33} ** 32);
    try writeBytes(&inner, alloc, 5, "image/webp");
    try writeTag(&inner, alloc, 6, 0);
    try writeVarint(&inner, alloc, 512);
    try writeTag(&inner, alloc, 7, 0);
    try writeVarint(&inner, alloc, 512);
    try writeBytes(&inner, alloc, 8, "/v/t62/sticker");
    try writeTag(&inner, alloc, 9, 0);
    try writeVarint(&inner, alloc, 1024);
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer buf.deinit(alloc);
    try writeTag(&buf, alloc, 26, 2);
    try writeVarint(&buf, alloc, inner.items.len);
    try buf.appendSlice(alloc, inner.items);
    const msg = try Message.decode(buf.items);
    const m = msg.media orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Media.Kind.sticker, m.kind);
    try std.testing.expectEqualStrings("https://mmg/sticker.webp", m.url.?);
    try std.testing.expectEqualStrings("image/webp", m.mimetype.?);
    try std.testing.expectEqual(@as(usize, 32), m.media_key.?.len);
    try std.testing.expectEqual(@as(usize, 32), m.file_sha256.?.len);
    try std.testing.expectEqual(@as(usize, 32), m.file_enc_sha256.?.len);
    try std.testing.expectEqualStrings("/v/t62/sticker", m.direct_path.?);
    try std.testing.expectEqual(@as(u64, 1024), m.file_len);
    try std.testing.expectEqual(@as(u32, 512), m.height);
    try std.testing.expectEqual(@as(u32, 512), m.width);
}
