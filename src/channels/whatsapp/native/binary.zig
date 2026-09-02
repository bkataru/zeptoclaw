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
    /// When true, tag / attr keys+values / content were allocator-duped.
    owned: bool = false,
    pub fn init(allocator: std.mem.Allocator, tag: []const u8) Node {
        return .{ .tag = tag, .attrs = std.StringHashMap([]const u8).init(allocator) };
    }
    /// Memory: if `owned`, frees tag, attr keys/values, and content (recursive). Always deinits the attr map.
    pub fn deinit(self: *Node) void {
        if (self.owned) {
            const a = self.attrs.allocator;
            a.free(self.tag);
            var it = self.attrs.iterator();
            while (it.next()) |e| {
                a.free(e.key_ptr.*);
                a.free(e.value_ptr.*);
            }
            switch (self.content) {
                .empty => {},
                .bytes => |b| a.free(b),
                .nodes => |nodes| {
                    for (nodes) |*n| n.deinit();
                    a.free(nodes);
                },
            }
        }
        self.attrs.deinit();
    }

    pub fn getAttr(self: Node, key: []const u8) ?[]const u8 {
        return self.attrs.get(key);
    }

    pub fn children(self: Node) []Node {
        return switch (self.content) {
            .nodes => |ns| ns,
            else => &.{},
        };
    }

    pub fn getChildByTag(self: Node, tag: []const u8) ?*Node {
        for (self.children()) |*n| {
            if (std.mem.eql(u8, n.tag, tag)) return n;
        }
        return null;
    }

    pub fn contentBytes(self: Node) ?[]const u8 {
        return switch (self.content) {
            .bytes => |b| b,
            else => null,
        };
    }
};

/// Memory: caller frees. Uncompressed WA binary (leading 0x00).
pub fn marshal(allocator: std.mem.Allocator, node: Node) ![]u8 {
    var enc = try Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeNode(node);
    return allocator.dupe(u8, enc.bytes());
}

pub const BinaryError = error{ InvalidToken, InvalidNode, InvalidJIDType, OutOfMemory, EndOfStream };

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
            try self.writeAttrValue(e.value_ptr.*);
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
    /// whatsmeow encoder.go writeAttributes: JID-typed attribute values are marshaled as
    /// JIDPair/ADJID binary tags, not plain strings. Our attrs are untyped `[]const u8`, so
    /// detect JID-shaped values (`user[:device]@knownServer`) by their server suffix.
    fn writeAttrValue(self: *Encoder, s: []const u8) !void {
        if (isJidLike(s)) return self.writeJidValue(s);
        try self.writeString(s);
    }
    /// whatsmeow encoder.go writeJID.
    fn writeJidValue(self: *Encoder, s: []const u8) !void {
        const at = std.mem.indexOfScalar(u8, s, '@').?;
        const left = s[0..at];
        const srv = s[at + 1 ..];
        const colon = std.mem.indexOfScalar(u8, left, ':');
        const usr = if (colon) |c| left[0..c] else left;
        const dev: u32 = if (colon) |c| (std.fmt.parseInt(u32, left[c + 1 ..], 10) catch 0) else 0;
        const is_default_or_hidden = std.mem.eql(u8, srv, "s.whatsapp.net") or std.mem.eql(u8, srv, "lid");
        const is_hosted = std.mem.eql(u8, srv, "hosted") or std.mem.eql(u8, srv, "hosted.lid");
        if ((is_default_or_hidden and dev > 0) or is_hosted) {
            const agent: u8 = if (std.mem.eql(u8, srv, "lid")) 1 else if (std.mem.eql(u8, srv, "hosted")) 128 else if (std.mem.eql(u8, srv, "hosted.lid")) 129 else 0;
            try self.pushByte(@intFromEnum(Tag.ADJID));
            try self.pushByte(agent);
            try self.pushByte(@truncate(dev));
            try self.writeString(usr);
        } else {
            try self.pushByte(@intFromEnum(Tag.JIDPair));
            if (usr.len == 0) { try self.pushByte(@intFromEnum(Tag.ListEmpty)); } else { try self.writeString(usr); }
            try self.writeString(srv);
        }
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

/// Known WhatsApp JID server suffixes; distinguishes JID-shaped attribute values
/// (e.g. `917019895010@s.whatsapp.net`, `216638251077681@lid`) from plain strings.
fn isJidLike(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    const srv = s[at + 1 ..];
    const known = [_][]const u8{
        "s.whatsapp.net", "lid", "g.us", "broadcast", "c.us",
        "hosted",         "hosted.lid", "newsletter", "call", "status",
    };
    for (known) |k| if (std.mem.eql(u8, srv, k)) return true;
    return false;
}

fn isNibble(s: []const u8) bool { for (s) |c| if (!((c >= '0' and c <= '9') or c == '-' or c == '.')) return false; return s.len > 0; }
fn isHex(s: []const u8) bool { for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F'))) return false; return s.len > 0; }
fn packNibble(c: u8) u8 { return switch (c) { '-' => 10, '.' => 11, 0 => 15, else => if (c >= '0' and c <= '9') c - '0' else 15 }; }
fn packHex(c: u8) u8 { return if (c >= '0' and c <= '9') c - '0' else if (c >= 'A' and c <= 'F') 10 + c - 'A' else 15; }
fn packPair(packer: fn (u8) u8, a: u8, b: u8) u8 { return (packer(a) << 4) | packer(b); }

const ReadValue = union(enum) {
    none,
    text: []u8,
    bytes: []u8,
    nodes: []Node,
};

fn deinitOwnedAttrs(attrs: *std.StringHashMap([]const u8)) void {
    const a = attrs.allocator;
    var it = attrs.iterator();
    while (it.next()) |e| {
        a.free(e.key_ptr.*);
        a.free(e.value_ptr.*);
    }
    attrs.deinit();
}

fn unpackNibble(value: u8) !u8 {
    return switch (value) {
        0...9 => '0' + value,
        10 => '-',
        11 => '.',
        15 => 0,
        else => error.InvalidToken,
    };
}

fn unpackHex(value: u8) !u8 {
    return switch (value) {
        0...9 => '0' + value,
        10...15 => 'A' + (value - 10),
        else => error.InvalidToken,
    };
}

fn unpackByte(tag: u8, value: u8) !u8 {
    return switch (tag) {
        @intFromEnum(Tag.Nibble8) => unpackNibble(value),
        @intFromEnum(Tag.Hex8) => unpackHex(value),
        else => error.InvalidToken,
    };
}

fn formatADJID(allocator: std.mem.Allocator, user: []const u8, agent: u8, device: u8) ![]u8 {
    // whatsmeow types.NewADJID + JID.String
    const mapped: struct { server: []const u8, raw_agent: u8 } = switch (agent) {
        1 => .{ .server = "lid", .raw_agent = 0 },
        128 => .{ .server = "hosted", .raw_agent = 0 },
        129 => .{ .server = "hosted.lid", .raw_agent = 0 },
        else => .{ .server = "s.whatsapp.net", .raw_agent = agent },
    };
    if (mapped.raw_agent > 0) {
        return std.fmt.allocPrint(allocator, "{s}.{d}:{d}@{s}", .{ user, mapped.raw_agent, device, mapped.server });
    } else if (device != 0) {
        return std.fmt.allocPrint(allocator, "{s}:{d}@{s}", .{ user, device, mapped.server });
    } else if (user.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, mapped.server });
    } else {
        return allocator.dupe(u8, mapped.server);
    }
}

fn formatDeviceJID(allocator: std.mem.Allocator, user: []const u8, device: usize, server: []const u8) ![]u8 {
    if (device != 0) {
        return std.fmt.allocPrint(allocator, "{s}:{d}@{s}", .{ user, device, server });
    } else if (user.len > 0) {
        return std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, server });
    } else {
        return allocator.dupe(u8, server);
    }
}

// Decoder — port of whatsmeow binary/decoder.go (DictVersion 3)
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Decoder {
        return .{ .allocator = allocator, .data = data };
    }

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
            @intFromEnum(Tag.ListEmpty) => 0,
            @intFromEnum(Tag.List8) => self.readIntN(1, false),
            @intFromEnum(Tag.List16) => self.readIntN(2, false),
            else => error.InvalidToken,
        };
    }

    pub fn readRaw(self: *Decoder, len: usize) ![]const u8 {
        try self.checkEOS(len);
        defer self.idx += len;
        return self.data[self.idx .. self.idx + len];
    }

    fn deinitValue(self: *Decoder, v: ReadValue) void {
        switch (v) {
            .none => {},
            .text => |t| self.allocator.free(t),
            .bytes => |b| self.allocator.free(b),
            .nodes => |ns| {
                for (ns) |*n| n.deinit();
                self.allocator.free(ns);
            },
        }
    }

    fn requireText(self: *Decoder, v: ReadValue) BinaryError![]u8 {
        switch (v) {
            .text => |t| return t,
            .bytes => |b| return b,
            .none => return error.InvalidToken,
            .nodes => |ns| {
                for (ns) |*n| n.deinit();
                self.allocator.free(ns);
                return error.InvalidToken;
            },
        }
    }

    fn valueToText(self: *Decoder, v: ReadValue) BinaryError![]u8 {
        switch (v) {
            .none => return try self.allocator.dupe(u8, ""),
            .text => |t| return t,
            .bytes => |b| return b,
            .nodes => |ns| {
                for (ns) |*n| n.deinit();
                self.allocator.free(ns);
                return error.InvalidToken;
            },
        }
    }

    fn readBytesOrString(self: *Decoder, length: usize, as_string: bool) BinaryError!ReadValue {
        const raw = try self.readRaw(length);
        const duped = try self.allocator.dupe(u8, raw);
        return if (as_string) .{ .text = duped } else .{ .bytes = duped };
    }

    fn read(self: *Decoder, as_string: bool) BinaryError!ReadValue {
        const tag = try self.readByte();
        switch (tag) {
            @intFromEnum(Tag.ListEmpty) => return .none,
            @intFromEnum(Tag.List8), @intFromEnum(Tag.List16) => {
                return .{ .nodes = try self.readList(tag, self.allocator) };
            },
            @intFromEnum(Tag.Binary8) => {
                const size = try self.readIntN(1, false);
                return try self.readBytesOrString(size, as_string);
            },
            @intFromEnum(Tag.Binary20) => {
                const size = try self.readInt20();
                return try self.readBytesOrString(size, as_string);
            },
            @intFromEnum(Tag.Binary32) => {
                const size = try self.readIntN(4, false);
                return try self.readBytesOrString(size, as_string);
            },
            @intFromEnum(Tag.Dictionary0),
            @intFromEnum(Tag.Dictionary1),
            @intFromEnum(Tag.Dictionary2),
            @intFromEnum(Tag.Dictionary3) => {
                const i = try self.readIntN(1, false);
                const s = try tokens.getDoubleToken(@as(usize, tag) - @intFromEnum(Tag.Dictionary0), i);
                return .{ .text = try self.allocator.dupe(u8, s) };
            },
            @intFromEnum(Tag.FBJID) => return .{ .text = try self.readFBJID() },
            @intFromEnum(Tag.InteropJID) => return .{ .text = try self.readInteropJID() },
            @intFromEnum(Tag.JIDPair) => return .{ .text = try self.readJIDPair() },
            @intFromEnum(Tag.ADJID) => return .{ .text = try self.readADJID() },
            @intFromEnum(Tag.Nibble8), @intFromEnum(Tag.Hex8) => {
                return .{ .text = try self.readPacked(tag) };
            },
            else => {
                const s = try tokens.getSingleToken(tag);
                return .{ .text = try self.allocator.dupe(u8, s) };
            },
        }
    }

    /// Memory: caller owns the returned `user@server` string.
    pub fn readJIDPair(self: *Decoder) BinaryError![]u8 {
        const user_v = try self.read(true);
        errdefer self.deinitValue(user_v);
        const server_v = try self.read(true);
        errdefer self.deinitValue(server_v);
        const server: []const u8 = switch (server_v) {
            .text => |t| t,
            .bytes => |b| b,
            else => return error.InvalidJIDType,
        };
        const user: []const u8 = switch (user_v) {
            .none => "",
            .text => |t| t,
            .bytes => |b| b,
            .nodes => return error.InvalidJIDType,
        };
        const out = try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ user, server });
        self.deinitValue(user_v);
        self.deinitValue(server_v);
        return out;
    }

    /// Memory: caller owns the returned JID string (`user:device@lid` when device!=0 else `user@lid` for LID agent).
    pub fn readADJID(self: *Decoder) BinaryError![]u8 {
        const agent = try self.readByte();
        const device = try self.readByte();
        const user_v = try self.read(true);
        errdefer self.deinitValue(user_v);
        const user: []const u8 = switch (user_v) {
            .text => |t| t,
            .bytes => |b| b,
            .none => "",
            .nodes => return error.InvalidJIDType,
        };
        const out = try formatADJID(self.allocator, user, agent, device);
        self.deinitValue(user_v);
        return out;
    }

    /// Memory: caller owns the returned `user[:device]@interop` string.
    pub fn readInteropJID(self: *Decoder) BinaryError![]u8 {
        const user_v = try self.read(true);
        errdefer self.deinitValue(user_v);
        const device = try self.readIntN(2, false);
        const integrator = try self.readIntN(2, false);
        _ = integrator;
        const server_v = try self.read(true);
        errdefer self.deinitValue(server_v);
        const server: []const u8 = switch (server_v) {
            .text => |t| t,
            .bytes => |b| b,
            else => return error.InvalidJIDType,
        };
        if (!std.mem.eql(u8, server, "interop")) return error.InvalidJIDType;
        const user: []const u8 = switch (user_v) {
            .none => "",
            .text => |t| t,
            .bytes => |b| b,
            .nodes => return error.InvalidJIDType,
        };
        const out = try formatDeviceJID(self.allocator, user, device, server);
        self.deinitValue(user_v);
        self.deinitValue(server_v);
        return out;
    }

    /// Memory: caller owns the returned `user[:device]@msgr` string.
    pub fn readFBJID(self: *Decoder) BinaryError![]u8 {
        const user_v = try self.read(true);
        errdefer self.deinitValue(user_v);
        const device = try self.readIntN(2, false);
        const server_v = try self.read(true);
        errdefer self.deinitValue(server_v);
        const server: []const u8 = switch (server_v) {
            .text => |t| t,
            .bytes => |b| b,
            else => return error.InvalidJIDType,
        };
        if (!std.mem.eql(u8, server, "msgr")) return error.InvalidJIDType;
        const user: []const u8 = switch (user_v) {
            .none => "",
            .text => |t| t,
            .bytes => |b| b,
            .nodes => return error.InvalidJIDType,
        };
        const out = try formatDeviceJID(self.allocator, user, device, server);
        self.deinitValue(user_v);
        self.deinitValue(server_v);
        return out;
    }

    /// Memory: caller owns the unpacked nibble/hex string.
    pub fn readPacked(self: *Decoder, tag: u8) BinaryError![]u8 {
        const start = try self.readByte();
        const n_pairs: usize = start & 127;
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, n_pairs * 2);
        errdefer buf.deinit(self.allocator);
        var i: usize = 0;
        while (i < n_pairs) : (i += 1) {
            const curr = try self.readByte();
            try buf.append(self.allocator, try unpackByte(tag, curr >> 4));
            try buf.append(self.allocator, try unpackByte(tag, curr & 0x0F));
        }
        if (start >> 7 != 0) {
            if (buf.items.len == 0) return error.InvalidToken;
            buf.items.len -= 1;
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    /// Memory: returned map owns duped keys and values; free via Node.deinit or deinitOwnedAttrs.
    pub fn readAttributes(self: *Decoder, n: usize, allocator: std.mem.Allocator) BinaryError!std.StringHashMap([]const u8) {
        var attrs = std.StringHashMap([]const u8).init(allocator);
        errdefer deinitOwnedAttrs(&attrs);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key_v = try self.read(true);
            const key = try self.requireText(key_v);
            const val_v = self.read(true) catch |err| {
                allocator.free(key);
                return err;
            };
            const val = self.valueToText(val_v) catch |err| {
                allocator.free(key);
                return err;
            };
            attrs.put(key, val) catch |err| {
                allocator.free(key);
                allocator.free(val);
                return err;
            };
        }
        return attrs;
    }

    /// Memory: caller owns the node slice and each child Node.
    pub fn readList(self: *Decoder, tag: u8, allocator: std.mem.Allocator) BinaryError![]Node {
        const size = try self.readListSize(tag);
        var list = try std.ArrayList(Node).initCapacity(allocator, size);
        errdefer {
            for (list.items) |*n| n.deinit();
            list.deinit(allocator);
        }
        var i: usize = 0;
        while (i < size) : (i += 1) {
            try list.append(allocator, try self.readNode());
        }
        return try list.toOwnedSlice(allocator);
    }

    /// Memory: returned Node owns tag, attr keys/values, and content; call deinit.
    pub fn readNode(self: *Decoder) BinaryError!Node {
        const size_tag = try self.readByte();
        const list_size = try self.readListSize(size_tag);
        const tag_v = try self.read(true);
        const tag = self.requireText(tag_v) catch return error.InvalidNode;
        errdefer self.allocator.free(tag);
        if (list_size == 0 or tag.len == 0) return error.InvalidNode;

        var attrs = try self.readAttributes((list_size - 1) >> 1, self.allocator);
        errdefer deinitOwnedAttrs(&attrs);

        var content: Content = .empty;
        if (list_size % 2 == 0) {
            const cv = try self.read(false);
            content = switch (cv) {
                .none => .empty,
                .text => |t| .{ .bytes = t },
                .bytes => |b| .{ .bytes = b },
                .nodes => |ns| .{ .nodes = ns },
            };
        }
        return .{
            .tag = tag,
            .attrs = attrs,
            .content = content,
            .owned = true,
        };
    }
};

/// Memory: caller owns returned buffer (zlib-decoded or prefix-stripped copy).
pub fn unpack(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return try allocator.dupe(u8, "");
    if (data[0] & 2 != 0) {
        // zlib 0x02 flag — decompress data[1..] via flate (.zlib header+adler)
        var in = std.Io.Reader.fixed(data[1..]);
        var out_writer = std.Io.Writer.Allocating.initCapacity(allocator, 0) catch return error.OutOfMemory;
        defer out_writer.deinit();
        var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        _ = decomp.reader.streamRemaining(&out_writer.writer) catch return error.InvalidToken;
        return try out_writer.toOwnedSlice();
    }
    return try allocator.dupe(u8, data[1..]);
}

/// Memory: unpacks (0x00 / 0x02 prefix) then readNode. Caller owns Node; call deinit.
pub fn decodeNode(allocator: std.mem.Allocator, packed_or_unpacked: []const u8) BinaryError!Node {
    const unpacked = try unpack(allocator, packed_or_unpacked);
    defer allocator.free(unpacked);
    var dec = Decoder.init(allocator, unpacked);
    return dec.readNode();
}

test "binary tokens" {
    try std.testing.expectEqual(@as(usize, 236), tokens.single_byte_tokens.len);
    try std.testing.expectEqual(@as(usize, 4), tokens.double_byte_tokens.len);
    try std.testing.expectEqual(@as(u8, 3), tokens.dict_version);
}

test "binary node roundtrip" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, "message");
    defer node.deinit();
    try node.attrs.put("from", "917019895010");
    try node.attrs.put("to", "15551212");
    try node.attrs.put("id", "ABCDEF");
    try node.attrs.put("type", "false");
    node.content = .{ .bytes = "hello" };

    var enc = try Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeNode(node);

    var decoded = try decodeNode(allocator, enc.bytes());
    defer decoded.deinit();
    try std.testing.expectEqualStrings("message", decoded.tag);
    try std.testing.expectEqualStrings("917019895010", decoded.attrs.get("from").?);
    try std.testing.expectEqualStrings("15551212", decoded.attrs.get("to").?);
    try std.testing.expectEqualStrings("ABCDEF", decoded.attrs.get("id").?);
    try std.testing.expectEqualStrings("false", decoded.attrs.get("type").?);
    switch (decoded.content) {
        .bytes => |b| try std.testing.expectEqualStrings("hello", b),
        else => return error.TestUnexpectedResult,
    }
}

test "binary packed nibble string" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, "iq");
    defer node.deinit();
    try node.attrs.put("from", "15551234567");

    var enc = try Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeNode(node);
    try std.testing.expect(std.mem.indexOfScalar(u8, enc.bytes(), @intFromEnum(Tag.Nibble8)) != null);

    var decoded = try decodeNode(allocator, enc.bytes());
    defer decoded.deinit();
    try std.testing.expectEqualStrings("iq", decoded.tag);
    try std.testing.expectEqualStrings("15551234567", decoded.attrs.get("from").?);
}

test "binary encoder writes jid-shaped attrs as JIDPair/ADJID and round-trips" {
    const allocator = std.testing.allocator;

    // Bare user@server (device 0, e.g. usync <user jid="..."/>) -> JIDPair, round-trips exactly.
    {
        var node = Node.init(allocator, "user");
        defer node.deinit();
        try node.attrs.put("jid", "917019895010@s.whatsapp.net");

        var enc = try Encoder.init(allocator);
        defer enc.deinit();
        try enc.writeNode(node);
        try std.testing.expect(std.mem.indexOfScalar(u8, enc.bytes(), @intFromEnum(Tag.JIDPair)) != null);

        var decoded = try decodeNode(allocator, enc.bytes());
        defer decoded.deinit();
        try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", decoded.attrs.get("jid").?);
    }

    // user:device@lid -> ADJID, round-trips exactly (self-chat LID case).
    {
        var node = Node.init(allocator, "user");
        defer node.deinit();
        try node.attrs.put("jid", "216638251077681:55@lid");

        var enc = try Encoder.init(allocator);
        defer enc.deinit();
        try enc.writeNode(node);
        try std.testing.expect(std.mem.indexOfScalar(u8, enc.bytes(), @intFromEnum(Tag.ADJID)) != null);

        var decoded = try decodeNode(allocator, enc.bytes());
        defer decoded.deinit();
        try std.testing.expectEqualStrings("216638251077681:55@lid", decoded.attrs.get("jid").?);
    }

    // Non-JID-shaped attr values (no "@") are unaffected.
    {
        var node = Node.init(allocator, "iq");
        defer node.deinit();
        try node.attrs.put("to", "s.whatsapp.net");

        var enc = try Encoder.init(allocator);
        defer enc.deinit();
        try enc.writeNode(node);
        try std.testing.expect(std.mem.indexOfScalar(u8, enc.bytes(), @intFromEnum(Tag.JIDPair)) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, enc.bytes(), @intFromEnum(Tag.ADJID)) == null);

        var decoded = try decodeNode(allocator, enc.bytes());
        defer decoded.deinit();
        try std.testing.expectEqualStrings("s.whatsapp.net", decoded.attrs.get("to").?);
    }
}

test "binary jid pair and adjid" {
    const allocator = std.testing.allocator;
    // uncompressed prefix + List8, size 3, tag message, attr from=JIDPair user=123 server=s.whatsapp.net
    const jidpair = [_]u8{ 0, 248, 3, 19, 6, 250, 255, 130, 0x12, 0x3F, 3 };
    var n1 = try decodeNode(allocator, &jidpair);
    defer n1.deinit();
    try std.testing.expectEqualStrings("message", n1.tag);
    try std.testing.expectEqualStrings("123@s.whatsapp.net", n1.attrs.get("from").?);

    // ADJID agent=LID(1) device=2 user=99 → 99:2@lid
    const adjid = [_]u8{ 0, 248, 3, 19, 6, 247, 1, 2, 255, 1, 0x99 };
    var n2 = try decodeNode(allocator, &adjid);
    defer n2.deinit();
    try std.testing.expectEqualStrings("99:2@lid", n2.attrs.get("from").?);

    // JIDPair empty user
    const empty_user = [_]u8{ 0, 248, 3, 19, 6, 250, 0, 3 };
    var n3 = try decodeNode(allocator, &empty_user);
    defer n3.deinit();
    try std.testing.expectEqualStrings("@s.whatsapp.net", n3.attrs.get("from").?);

    // FBJID user=u device=5 server=msgr
    const fbjid = [_]u8{ 0, 248, 3, 19, 6, 246, 252, 1, 'u', 0, 5, 204 };
    var n4 = try decodeNode(allocator, &fbjid);
    defer n4.deinit();
    try std.testing.expectEqualStrings("u:5@msgr", n4.attrs.get("from").?);

    // InteropJID user=bob device=1 integrator=2 server=interop
    const interop = [_]u8{ 0, 248, 3, 19, 6, 245, 252, 3, 'b', 'o', 'b', 0, 1, 0, 2, 252, 7, 'i', 'n', 't', 'e', 'r', 'o', 'p' };
    var n5 = try decodeNode(allocator, &interop);
    defer n5.deinit();
    try std.testing.expectEqualStrings("bob:1@interop", n5.attrs.get("from").?);
}

test "binary nested nodes" {
    const allocator = std.testing.allocator;
    var child = Node.init(allocator, "enc");
    defer child.deinit();
    try child.attrs.put("v", "2");
    child.content = .{ .bytes = "abc" };

    var parent = Node.init(allocator, "message");
    defer parent.deinit();
    parent.content = .{ .nodes = (&child)[0..1] };

    var enc = try Encoder.init(allocator);
    defer enc.deinit();
    try enc.writeNode(parent);

    var decoded = try decodeNode(allocator, enc.bytes());
    defer decoded.deinit();
    try std.testing.expectEqualStrings("message", decoded.tag);
    switch (decoded.content) {
        .nodes => |ns| {
            try std.testing.expectEqual(@as(usize, 1), ns.len);
            try std.testing.expectEqualStrings("enc", ns[0].tag);
            try std.testing.expectEqualStrings("2", ns[0].attrs.get("v").?);
            switch (ns[0].content) {
                .bytes => |b| try std.testing.expectEqualStrings("abc", b),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}
