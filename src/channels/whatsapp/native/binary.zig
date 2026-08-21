const std = @import("std");
const tokens = @import("tokens.zig");

// Binary TLV layer — port of whatsmeow/binary/{encoder,decoder,node,attrs,token}
// DictVersion 3, WA binary framing (not XML on wire). 0x00 uncompressed / 0x02 zlib.

pub const DictVersion: u8 = tokens.dict_version;

// Token tag types (token.go)
pub const Tag = enum(u8) {
    ListEmpty = 0,
    // 1..235 single, 236..239 Dictionary0..3, 245 InteropJID, 246 FBJID, 247 ADJID, 248 List8, 249 List16, 250 JIDPair, 251 Hex8, 252 Binary8, 253 Binary20, 254 Binary32, 255 Nibble8
    Dictionary0 = 236,
    Dictionary1 = 237,
    Dictionary2 = 238,
    Dictionary3 = 239,
    InteropJID = 245,
    FBJID = 246,
    ADJID = 247,
    List8 = 248,
    List16 = 249,
    JIDPair = 250,
    Hex8 = 251,
    Binary8 = 252,
    Binary20 = 253,
    Binary32 = 254,
    Nibble8 = 255,
};

// Node — WhatsApp binary node (XMPP-like stanza)
pub const Content = union(enum) {
    empty,
    nodes: []Node,
    bytes: []const u8,
};
pub const Node = struct {
    tag: []const u8,
    attrs: std.StringHashMap([]const u8),
    content: Content = .empty,
    pub fn init(allocator: std.mem.Allocator, tag: []const u8) Node {
        return .{ .tag = tag, .attrs = std.StringHashMap([]const u8).init(allocator) };
    }
    pub fn deinit(self: *Node) void { self.attrs.deinit(); }
};

pub const BinaryError = error{ InvalidToken, InvalidNode, OutOfMemory, EndOfStream };

// Encoder — binaryEncoder{data []u8} with [0] uncompressed prefix
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Encoder {
        var e = Encoder{ .allocator = allocator, .buf = try std.ArrayList(u8).initCapacity(allocator, 0) };
        try e.buf.append(allocator, 0); // uncompressed flag
        return e;
    }
    pub fn deinit(self: *Encoder) void { self.buf.deinit(self.allocator); }
    pub fn bytes(self: *Encoder) []const u8 { return self.buf.items; }

    pub fn writeNode(self: *Encoder, node: Node) !void {
        if (std.mem.eql(u8, node.tag, "0")) {
            try self.writeListStart(2);
            try self.pushByte(@intFromEnum(Tag.ListEmpty));
            return;
        }
        const attr_count = node.attrs.count();
        const has_content: usize = if (node.content == .empty) 0 else 1;
        const list_size = 2 * attr_count + 1 + has_content;
        try self.writeListStart(list_size);
        try self.writeString(node.tag);
        var it = node.attrs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.len == 0) continue;
            try self.writeString(e.key_ptr.*);
            try self.writeString(e.value_ptr.*);
        }
        switch (node.content) {
            .empty => {},
            .bytes => |b| try self.writeBytes(b),
            .nodes => |nodes| {
                try self.writeListStart(nodes.len);
                for (nodes) |n| try self.writeNode(n);
            },
        }
    }

    fn writeListStart(self: *Encoder, size: usize) !void {
        if (size == 0) try self.pushByte(@intFromEnum(Tag.ListEmpty))
        else if (size < 256) { try self.pushByte(@intFromEnum(Tag.List8)); try self.pushByte(@intCast(size)); }
        else { try self.pushByte(@intFromEnum(Tag.List16)); try self.pushIntN(2, false, @intCast(size)); }
    }
    fn writeBytes(self: *Encoder, b: []const u8) !void {
        if (b.len < 256) { try self.pushByte(@intFromEnum(Tag.Binary8)); try self.pushByte(@intCast(b.len)); }
        else if (b.len < 1 << 20) { try self.pushByte(@intFromEnum(Tag.Binary20)); try self.pushInt20(@intCast(b.len)); }
        else { try self.pushByte(@intFromEnum(Tag.Binary32)); try self.pushIntN(4, false, @intCast(b.len)); }
        try self.buf.appendSlice(self.allocator, b);
    }
    fn writeString(self: *Encoder, s: []const u8) !void {
        if (tokens.singleIndexOf(s)) |idx| { try self.pushByte(idx); return; }
        if (tokens.doubleIndexOf(s)) |di| { try self.pushByte(236 + di.d); try self.pushByte(di.i); return; }
        if (s.len <= 127 and isNibble(s)) { try self.writePacked(s, @intFromEnum(Tag.Nibble8), packNibble); return; }
        if (s.len <= 127 and isHex(s)) { try self.writePacked(s, @intFromEnum(Tag.Hex8), packHex); return; }
        try self.writeBytes(s);
    }
    fn writePacked(self: *Encoder, s: []const u8, tag: u8, packer: fn (u8) u8) !void {
        try self.pushByte(tag);
        const rounded: u8 = @intCast((s.len + 1) / 2 | @as(usize, if (s.len % 2 == 1) 128 else 0));
        try self.pushByte(rounded);
        var i: usize = 0;
        while (i + 1 < s.len) : (i += 2) try self.pushByte(packPair(packer, s[i], s[i + 1]));
        if (s.len % 2 == 1) try self.pushByte(packPair(packer, s[s.len - 1], 0));
    }
    fn pushByte(self: *Encoder, b: u8) !void { try self.buf.append(self.allocator, b); }
    fn pushIntN(self: *Encoder, n: usize, le: bool, v: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const shift: u6 = @intCast(if (le) i * 8 else (n - i - 1) * 8);
            try self.pushByte(@intCast((v >> shift) & 0xFF));
        }
    }
    fn pushInt20(self: *Encoder, v: usize) !void {
        try self.pushByte(@intCast((v >> 16) & 0x0F));
        try self.pushByte(@intCast((v >> 8) & 0xFF));
        try self.pushByte(@intCast(v & 0xFF));
    }
};

fn isNibble(s: []const u8) bool { for (s) |c| if (!((c >= '0' and c <= '9') or c == '-' or c == '.')) return false; return s.len > 0; }
fn isHex(s: []const u8) bool { for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F'))) return false; return s.len > 0; }
fn packNibble(c: u8) u8 { return switch (c) { '-' => 10, '.' => 11, 0 => 15, else => if (c >= '0' and c <= '9') c - '0' else 15 }; }
fn packHex(c: u8) u8 { return if (c >= '0' and c <= '9') c - '0' else if (c >= 'A' and c <= 'F') 10 + c - 'A' else 15; }
fn packPair(packer: fn (u8) u8, a: u8, b: u8) u8 { return (packer(a) << 4) | packer(b); }

// Decoder stub — keep BUILD:0
pub const Decoder = struct {
    data: []const u8,
    idx: usize = 0,
    pub fn init(data: []const u8) Decoder { return .{ .data = data }; }
    pub fn readByte(self: *Decoder) !u8 {
        if (self.idx >= self.data.len) return error.EndOfStream;
        defer self.idx += 1;
        return self.data[self.idx];
    }
    pub fn checkEOS(self: *Decoder, n: usize) !void {
        if (self.idx + n > self.data.len) return error.EndOfStream;
    }
    pub fn readIntN(self: *Decoder, n: usize, le: bool) !usize {
        try self.checkEOS(n);
        var ret: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const shift: u6 = @intCast(if (le) i * 8 else (n - i - 1) * 8);
            ret |= @as(usize, self.data[self.idx + i]) << shift;
        }
        self.idx += n;
        return ret;
    }
    pub fn readInt20(self: *Decoder) !usize {
        try self.checkEOS(3);
        const ret = ((@as(usize, self.data[self.idx]) & 15) << 16) | (@as(usize, self.data[self.idx + 1]) << 8) | @as(usize, self.data[self.idx + 2]);
        self.idx += 3;
        return ret;
    }
    pub fn readListSize(self: *Decoder, tag: u8) !usize {
        return switch (tag) {
            @intFromEnum(Tag.List8) => self.readIntN(1, false),
            @intFromEnum(Tag.List16) => self.readIntN(2, false),
            else => error.InvalidToken,
        };
    }
    // Unpack helpers mirror whatsmeow unpack.go
    pub fn readJIDPair(self: *Decoder) ![]const u8 { _ = self; return error.NotImplemented; }
    pub fn readNode(self: *Decoder) !Node { _ = self; return error.NotImplemented; }
};

pub fn unpack(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return try allocator.dupe(u8, "");
    if (data[0] & 2 != 0) {
        // zlib-compressed payload would go through std.compress.flate.Decompress (.zlib) here
        return error.NotImplemented;
    }
    return try allocator.dupe(u8, data[1..]);
}

test "binary tokens" {
    try std.testing.expectEqual(@as(usize, 236), tokens.single_byte_tokens.len);
    try std.testing.expectEqual(@as(usize, 4), tokens.double_byte_tokens.len);
    try std.testing.expectEqual(@as(u8, 3), tokens.dict_version);
}
