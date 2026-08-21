const std = @import("std");

// Minimal proto2 for WhatsApp handshake — HandshakeMessage, ClientPayload, CertChain
pub const HandshakeMessage = struct {
    client_hello: ?ClientHello = null,
    server_hello: ?ServerHello = null,
    client_finish: ?ClientFinish = null,
    pub const ClientHello = struct { ephemeral: []const u8 = &[_]u8{} };
    pub const ServerHello = struct { ephemeral: []const u8 = &[_]u8{}, static: []const u8 = &[_]u8{}, payload: []const u8 = &[_]u8{} };
    pub const ClientFinish = struct { static: []const u8 = &[_]u8{}, payload: []const u8 = &[_]u8{} };
    pub fn encode(self: HandshakeMessage, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return try allocator.dupe(u8, &[_]u8{});
    }
    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !HandshakeMessage {
        _ = allocator; _ = data;
        return .{};
    }
};

pub const CertChain = struct {
    leaf: []const u8 = &[_]u8{},
    intermediate: []const u8 = &[_]u8{},
    pub fn verify(self: CertChain, pubkey: [32]u8) !void { _ = self; _ = pubkey; }
};

test "proto stub" { const m = HandshakeMessage{}; _ = try m.encode(std.testing.allocator); }
