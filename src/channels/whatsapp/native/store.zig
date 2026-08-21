const std = @import("std");

// Port of whatsmeow store: Device + 18 tables — stub with sqlite WAL PRAGMA
pub const Device = struct {
    jid: []const u8,
    lid: ?[]const u8 = null,
    registration_id: u32 = 0,
    noise_key: [32]u8 = [_]u8{0} ** 32,
    identity_key: [32]u8 = [_]u8{0} ** 32,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    db: ?*anyopaque = null, // sqlite3* via C import later

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path };
    }
    pub fn open(self: *Store) !void {
        _ = self;
        return error.NotImplemented;
    }
    pub fn getDevice(self: *Store, jid: []const u8) !?Device {
        _ = self; _ = jid;
        return null;
    }
    pub fn putDevice(self: *Store, dev: Device) !void {
        _ = self; _ = dev;
        return error.NotImplemented;
    }
};

test "store stub" { _ = Store; }
