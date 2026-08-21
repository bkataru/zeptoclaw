const std = @import("std");

// Proto2 varint/length-delimited helpers for whatsmeow hot protos
pub fn writeVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var val = v;
    while (val >= 0x80) { try buf.append(allocator, @intCast((val & 0x7F) | 0x80)); val >>= 7; }
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

// Hot proto stubs matching whatsmeow expectations
pub const HandshakeMessage = struct {
    client_hello: ?ClientHello = null,
    server_hello: ?ServerHello = null,
    client_finish: ?ClientFinish = null,
    pub const ClientHello = struct { ephemeral: []const u8 = &[_]u8{} };
    pub const ServerHello = struct { ephemeral: []const u8 = &[_]u8{}, static: []const u8 = &[_]u8{}, payload: []const u8 = &[_]u8{} };
    pub const ClientFinish = struct { static: []const u8 = &[_]u8{}, payload: []const u8 = &[_]u8{} };
    // encode uses proto2 tag+length-delimited for each field
    pub fn encode(self: HandshakeMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer buf.deinit(allocator);
        if (self.client_hello) |ch| try writeBytes(&buf, allocator, 2, ch.ephemeral);
        if (self.server_hello) |sh| {
            try writeBytes(&buf, allocator, 3, sh.ephemeral);
            try writeBytes(&buf, allocator, 4, sh.static);
            try writeBytes(&buf, allocator, 5, sh.payload);
        }
        if (self.client_finish) |cf| {
            try writeBytes(&buf, allocator, 3, cf.static);
            try writeBytes(&buf, allocator, 4, cf.payload);
        }
        return try buf.toOwnedSlice(allocator);
    }
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !HandshakeMessage {
        _ = allocator; _ = data;
        return .{};
    }
};

pub const ClientPayload = struct {
    // minimal: device_pairing + user_agent
    username: u64 = 0,
    passive: bool = false,
    user_agent: []const u8 = &[_]u8{},
    web_sub_platform: u32 = 0,
    pub fn encode(self: ClientPayload, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return try allocator.dupe(u8, &[_]u8{});
    }
};

pub const CertChain = struct {
    leaf: []const u8 = &[_]u8{},
    intermediate: []const u8 = &[_]u8{},
    pub fn verify(self: CertChain, pubkey: [32]u8) !void { _ = self; _ = pubkey; }
    pub fn decodeDetails(self: CertChain, allocator: std.mem.Allocator) ![]u8 { _ = self; _ = allocator; return error.NotImplemented; }
};

pub const DeviceProps = struct {
    os: []const u8 = "ZeptoClaw",
    version: []const u8 = "1.0.0",
    platform_type: u32 = 14, // 14 = Chrome per waCompanionReg
    pub fn encode(self: DeviceProps, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return try allocator.dupe(u8, &[_]u8{});
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
}
