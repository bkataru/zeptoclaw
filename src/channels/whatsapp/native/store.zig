const std = @import("std");
const sqlite = @import("store/sqlite.zig");

// Port of whatsmeow store: Device + SQL container. `open()` creates a SQLite
// handle (including ":memory:") and applies schema.pragmatic_pragmas + latest_schema.
// Parent must add vendor/sqlite amalgamation to the zeptoclaw module — see sqlite.zig header.

pub const sqlite_store = sqlite;
pub const Device = sqlite.Device;
pub const Container = sqlite.Container;
pub const PreKeyRecord = sqlite.PreKeyRecord;

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    db: ?*anyopaque = null,
    inner: ?sqlite.Container = null,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path };
    }

    pub fn open(self: *Store) !void {
        if (self.inner != null) return;
        self.inner = try sqlite.Container.open(self.allocator, self.path);
        self.db = @ptrCast(self.inner.?.db);
    }

    pub fn deinit(self: *Store) void {
        if (self.inner) |*inner| inner.deinit();
        self.inner = null;
        self.db = null;
    }

    pub fn checkpoint(self: *Store) void {
        if (self.inner) |*inner| inner.checkpoint();
    }

    fn require(self: *Store) !*sqlite.Container {
        return if (self.inner) |*inner| inner else error.NotOpen;
    }

    pub fn getDevice(self: *Store, jid: []const u8) !?Device {
        return (try self.require()).getDevice(jid);
    }

    pub fn getAnyDevice(self: *Store) !?Device {
        return (try self.require()).getAnyDevice();
    }

    pub fn putDevice(self: *Store, dev: Device) !void {
        try (try self.require()).putDevice(dev);
        self.checkpoint();
    }

    pub fn putIdentity(self: *Store, our_jid: []const u8, their_id: []const u8, identity: [32]u8) !void {
        return (try self.require()).putIdentity(our_jid, their_id, identity);
    }

    pub fn getIdentity(self: *Store, our_jid: []const u8, their_id: []const u8) !?[32]u8 {
        return (try self.require()).getIdentity(our_jid, their_id);
    }

    pub fn putSession(self: *Store, our_jid: []const u8, their_id: []const u8, session: []const u8) !void {
        return (try self.require()).putSession(our_jid, their_id, session);
    }

    /// Memory: caller frees the returned slice.
    pub fn getSession(self: *Store, our_jid: []const u8, their_id: []const u8) !?[]u8 {
        return (try self.require()).getSession(our_jid, their_id);
    }

    pub fn deleteSession(self: *Store, our_jid: []const u8, their_id: []const u8) !void {
        return (try self.require()).deleteSession(our_jid, their_id);
    }

    pub fn deleteDevice(self: *Store, jid: []const u8) !void {
        return (try self.require()).deleteDevice(jid);
    }

    pub fn putSenderKey(self: *Store, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8, record: []const u8) !void {
        return (try self.require()).putSenderKey(our_jid, chat_id, sender_id, record);
    }

    /// Memory: caller frees the returned slice.
    pub fn getSenderKey(self: *Store, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8) !?[]u8 {
        return (try self.require()).getSenderKey(our_jid, chat_id, sender_id);
    }

    pub fn deleteSenderKey(self: *Store, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8) !void {
        return (try self.require()).deleteSenderKey(our_jid, chat_id, sender_id);
    }

    pub fn putLidMap(self: *Store, lid: []const u8, pn: []const u8) !void {
        return (try self.require()).putLidMap(lid, pn);
    }

    /// Memory: caller frees the returned slice.
    pub fn getPnForLid(self: *Store, lid: []const u8) !?[]u8 {
        return (try self.require()).getPnForLid(lid);
    }

    /// Memory: caller frees the returned slice.
    pub fn getLidForPn(self: *Store, pn: []const u8) !?[]u8 {
        return (try self.require()).getLidForPn(pn);
    }

    pub fn putPreKeys(self: *Store, our_jid: []const u8, recs: []const PreKeyRecord) !void {
        return (try self.require()).putPreKeys(our_jid, recs);
    }

    pub fn getPreKey(self: *Store, our_jid: []const u8, id: u32) !?PreKeyRecord {
        return (try self.require()).getPreKey(our_jid, id);
    }

    pub fn removePreKey(self: *Store, our_jid: []const u8, id: u32) !void {
        return (try self.require()).removePreKey(our_jid, id);
    }

    /// Memory: caller frees the returned slice.
    pub fn getUnuploadedPreKeys(self: *Store, allocator: std.mem.Allocator, our_jid: []const u8, limit: usize) ![]PreKeyRecord {
        return (try self.require()).getUnuploadedPreKeys(allocator, our_jid, limit);
    }

    pub fn markPreKeysUploaded(self: *Store, our_jid: []const u8, up_to_id: u32) !void {
        return (try self.require()).markPreKeysUploaded(our_jid, up_to_id);
    }

    pub fn countPreKeys(self: *Store, our_jid: []const u8) !u32 {
        return (try self.require()).countPreKeys(our_jid);
    }

    pub fn nextPreKeyId(self: *Store, our_jid: []const u8) !u32 {
        return (try self.require()).nextPreKeyId(our_jid);
    }
};

test "store open hooks sqlite container" {
    _ = Store;
    _ = sqlite.Container;
}

test "store open memory put/get device" {
    const alloc = std.testing.allocator;
    var s = Store.init(alloc, ":memory:");
    try s.open();
    defer s.deinit();
    try s.open(); // idempotent

    const put = Device{
        .allocator = alloc,
        .jid = "me:0@s.whatsapp.net",
        .registration_id = 7,
        .noise_key = [_]u8{0xAB} ** 32,
        .identity_key = [_]u8{0xCD} ** 32,
        .signed_pre_key = [_]u8{0xEF} ** 32,
        .signed_pre_key_sig = [_]u8{0x11} ** 64,
        .adv_key = [_]u8{0x22} ** 32,
    };
    try s.putDevice(put);
    var got = (try s.getDevice(put.jid)) orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expectEqual(@as(u32, 7), got.registration_id);
    try std.testing.expectEqual(@as(usize, 32), got.noise_key.len);
    try std.testing.expectEqualSlices(u8, &put.noise_key, &got.noise_key);
    try std.testing.expectEqualSlices(u8, &put.identity_key, &got.identity_key);
}

test "store prekeys put count unuploaded mark get remove next" {
    const alloc = std.testing.allocator;
    var s = Store.init(alloc, ":memory:");
    try s.open();
    defer s.deinit();
    const jid = "me@s.whatsapp.net";
    try s.putDevice(.{
        .allocator = alloc,
        .jid = jid,
        .registration_id = 1,
        .noise_key = [_]u8{1} ** 32,
        .identity_key = [_]u8{2} ** 32,
        .signed_pre_key = [_]u8{3} ** 32,
        .signed_pre_key_sig = [_]u8{4} ** 64,
        .adv_key = [_]u8{5} ** 32,
    });

    var recs: [30]PreKeyRecord = undefined;
    for (&recs, 0..) |*rec, i| {
        rec.* = .{
            .id = @intCast(i + 1),
            .priv_key = [_]u8{@as(u8, @intCast(i + 1))} ** 32,
            .pub_key = [_]u8{@as(u8, @intCast(i + 50))} ** 32,
            .uploaded = false,
        };
    }
    try s.putPreKeys(jid, &recs);
    try std.testing.expectEqual(@as(u32, 30), try s.countPreKeys(jid));

    const unup = try s.getUnuploadedPreKeys(alloc, jid, 100);
    defer alloc.free(unup);
    try std.testing.expectEqual(@as(usize, 30), unup.len);

    try s.markPreKeysUploaded(jid, 30);
    const unup2 = try s.getUnuploadedPreKeys(alloc, jid, 100);
    defer alloc.free(unup2);
    try std.testing.expectEqual(@as(usize, 0), unup2.len);

    const got = (try s.getPreKey(jid, 7)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), got.id);
    try std.testing.expectEqualSlices(u8, &recs[6].priv_key, &got.priv_key);
    try std.testing.expectEqualSlices(u8, &recs[6].pub_key, &got.pub_key);

    try s.removePreKey(jid, 7);
    try std.testing.expect((try s.getPreKey(jid, 7)) == null);
    try std.testing.expectEqual(@as(u32, 31), try s.nextPreKeyId(jid));
}

test "store session blob roundtrip owned copy" {
    const alloc = std.testing.allocator;
    var s = Store.init(alloc, ":memory:");
    try s.open();
    defer s.deinit();
    const our = "me@s.whatsapp.net";
    try s.putDevice(.{
        .allocator = alloc,
        .jid = our,
        .registration_id = 1,
        .noise_key = [_]u8{1} ** 32,
        .identity_key = [_]u8{2} ** 32,
        .signed_pre_key = [_]u8{3} ** 32,
        .signed_pre_key_sig = [_]u8{4} ** 64,
        .adv_key = [_]u8{5} ** 32,
    });
    const blob = "\x01serialized-session-blob\x00\xff";
    try s.putSession(our, "them.0", blob);
    const got = (try s.getSession(our, "them.0")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, blob, got);
    const got2 = (try s.getSession(our, "them.0")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got2);
    got[0] = 0;
    try std.testing.expectEqual(blob[0], got2[0]);
}

test "store sender keys roundtrip" {
    const alloc = std.testing.allocator;
    var s = Store.init(alloc, ":memory:");
    try s.open();
    defer s.deinit();
    const our = "me@s.whatsapp.net";
    try s.putDevice(.{
        .allocator = alloc,
        .jid = our,
        .registration_id = 1,
        .noise_key = [_]u8{1} ** 32,
        .identity_key = [_]u8{2} ** 32,
        .signed_pre_key = [_]u8{3} ** 32,
        .signed_pre_key_sig = [_]u8{4} ** 64,
        .adv_key = [_]u8{5} ** 32,
    });
    const record = "\x33sender-key-record\x00\xff";
    try s.putSenderKey(our, "120363@g.us", "111:0@s.whatsapp.net", record);
    try s.putSenderKey(our, "120363@g.us", "111:0@s.whatsapp.net", record);
    const got = (try s.getSenderKey(our, "120363@g.us", "111:0@s.whatsapp.net")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, record, got);
    try s.deleteSenderKey(our, "120363@g.us", "111:0@s.whatsapp.net");
    try std.testing.expect((try s.getSenderKey(our, "120363@g.us", "111:0@s.whatsapp.net")) == null);
}
