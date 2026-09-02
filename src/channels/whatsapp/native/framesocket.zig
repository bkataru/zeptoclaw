const std = @import("std");
const ws = @import("ws_client.zig");

// FrameSocket — WA length-prefixed frames over a websocket binary message.
// Port of whatsmeow/socket/framesocket.go SendFrame / processData (no dial).
// First send prefixes WA\x06\x03; later sends are 3-byte BE length + payload.
// Incoming websocket payloads are 3-byte length + payload (no WA header).

pub const FrameSocket = struct {
    allocator: std.mem.Allocator,
    header: [4]u8 = [_]u8{ 'W', 'A', 6, 3 },
    header_sent: bool = false,
    deframer: ws.Deframer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .deframer = ws.Deframer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.deframer.deinit();
    }

    /// Pack one outbound WA frame. Caller frees the returned slice.
    pub fn sendFrame(self: *Self, data: []const u8) ![]u8 {
        const hdr: ?[]const u8 = if (self.header_sent) null else &self.header;
        return ws.encodeFrame(self.allocator, hdr, data, &self.header_sent);
    }

    /// Feed one inbound websocket binary payload. Returns completed WA payloads
    /// (caller frees each slice and the ArrayList).
    pub fn recvFrames(self: *Self, ws_msg: []const u8) !std.ArrayList([]u8) {
        return self.deframer.feed(ws_msg);
    }

    /// Convenience: feed a complete single-frame websocket message.
    pub fn recvFrame(self: *Self, buf: []const u8) ![]u8 {
        var frames = try self.recvFrames(buf);
        defer {
            // If we return the first item, do not free it; free extras.
            var i: usize = 1;
            while (i < frames.items.len) : (i += 1) self.allocator.free(frames.items[i]);
            frames.deinit(self.allocator);
        }
        if (frames.items.len == 0) return error.NeedMoreData;
        return frames.items[0];
    }
};

test "framesocket first send includes WA header once" {
    const alloc = std.testing.allocator;
    var fs = FrameSocket.init(alloc);
    defer fs.deinit();
    const f1 = try fs.sendFrame("hello");
    defer alloc.free(f1);
    try std.testing.expectEqualStrings("WA\x06\x03", f1[0..4]);
    try std.testing.expectEqual(@as(usize, 4 + 3 + 5), f1.len);
    try std.testing.expectEqualStrings("hello", f1[7..]);
    const f2 = try fs.sendFrame("hi");
    defer alloc.free(f2);
    try std.testing.expectEqual(@as(usize, 3 + 2), f2.len);
    try std.testing.expectEqualStrings("hi", f2[3..]);
}

test "framesocket recv roundtrip without header" {
    const alloc = std.testing.allocator;
    var fs = FrameSocket.init(alloc);
    defer fs.deinit();
    fs.header_sent = true;
    const frame = try fs.sendFrame("payload");
    defer alloc.free(frame);
    var fs2 = FrameSocket.init(alloc);
    defer fs2.deinit();
    const got = try fs2.recvFrame(frame);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("payload", got);
}

test "framesocket recv split across two websocket messages" {
    const alloc = std.testing.allocator;
    var tx = FrameSocket.init(alloc);
    defer tx.deinit();
    tx.header_sent = true;
    const frame = try tx.sendFrame("abcdef");
    defer alloc.free(frame);
    var rx = FrameSocket.init(alloc);
    defer rx.deinit();
    var part1 = try rx.recvFrames(frame[0..2]);
    defer {
        for (part1.items) |b| alloc.free(b);
        part1.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), part1.items.len);
    const got = try rx.recvFrame(frame[2..]);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("abcdef", got);
}
