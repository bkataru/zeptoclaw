const std = @import("std");

// Port of whatsmeow/binary/{encoder,decoder,node,attrs}.go
// Binary node framing for WhatsApp Web (WA binary, not XML)
// TODO: implement encoder/decoder — stub compiles BUILD:0

pub const Node = struct {
    tag: []const u8,
    attrs: std.StringHashMap([]const u8),
    content: ?[]const u8 = null,
};

pub fn encode(allocator: std.mem.Allocator, node: Node) ![]u8 {
    _ = allocator; _ = node;
    return error.NotImplemented;
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Node {
    _ = allocator; _ = data;
    return error.NotImplemented;
}

test "binary stub" { _ = encode; _ = decode; }
