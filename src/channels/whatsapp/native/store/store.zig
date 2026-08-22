const std = @import("std");
const compat = @import("../../../../compat.zig");

// Port of whatsmeow/store/store.go — Device + trait definitions
// BUILD:0 skeleton: vtable shapes + Device struct match Go source; real SQL in sqlite.zig

pub const StoreError = error{
    NotImplemented,
    DeviceNotFound,
    DeviceIdMustBeSet,
    InvalidLength,
    NotLoggedIn,
    AlreadyConnected,
    ClientIsNil,
    StoreIsNil,
};

// whatsapp_channel uses string JIDs; store Device mirrors whatsmeow/store.Device
pub const JID = struct {
    user: []const u8 = "",
    server: []const u8 = "s.whatsapp.net",
    device: u8 = 0,
    pub fn isEmpty(self: JID) bool { return self.user.len == 0; }
    pub fn format(self: JID, allocator: std.mem.Allocator) ![]u8 {
        if (self.device == 0) return std.fmt.allocPrint(allocator, "{s}@{s}", .{ self.user, self.server });
        return std.fmt.allocPrint(allocator, "{s}:{d}@{s}", .{ self.user, self.device, self.server });
    }
};

pub const KeyPair = struct {
    priv: [32]u8 = [_]u8{0} ** 32,
    pub_bytes: [32]u8 = [_]u8{0} ** 32,
    pub fn generate() KeyPair {
        var kp: KeyPair = .{};
        compat.fillRandom(&kp.priv);
        // Derive pub via X25519 basepoint (stub: use priv as pub for BUILD:0 until noise wired)
        kp.pub_bytes = kp.priv;
        return kp;
    }
};

pub const PreKey = struct {
    key_id: u32 = 0,
    priv: [32]u8 = [_]u8{0} ** 32,
    pub_bytes: [32]u8 = [_]u8{0} ** 32,
    signature: [64]u8 = [_]u8{0} ** 64,
};

/// Device mirrors whatsmeow/store.Device (subset for BUILD:0)
pub const Device = struct {
    allocator: std.mem.Allocator,
    id: ?JID = null,
    lid: JID = .{},
    noise_key: KeyPair = .{},
    identity_key: KeyPair = .{},
    signed_pre_key: PreKey = .{},
    registration_id: u32 = 0,
    adv_secret_key: [32]u8 = [_]u8{0} ** 32,
    platform: []const u8 = "",
    business_name: []const u8 = "",
    push_name: []const u8 = "",
    lid_migration_ts: i64 = 0,
    companion_meta_nonce: []const u8 = "",
    facebook_uuid: []const u8 = "",

    // Store handles — set by Container.initializeDevice
    container: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Device {
        var d = Device{ .allocator = allocator };
        d.noise_key = KeyPair.generate();
        d.identity_key = KeyPair.generate();
        compat.fillRandom(&d.adv_secret_key);
        d.registration_id = compat.randomInt(u32);
        d.signed_pre_key = PreKey{ .key_id = 1, .priv = d.identity_key.priv, .pub_bytes = d.identity_key.pub_bytes };
        return d;
    }
    pub fn deinit(self: *Device) void {
        if (self.platform.len > 0) self.allocator.free(self.platform);
        if (self.business_name.len > 0) self.allocator.free(self.business_name);
        if (self.push_name.len > 0) self.allocator.free(self.push_name);
        if (self.companion_meta_nonce.len > 0) self.allocator.free(self.companion_meta_nonce);
        if (self.facebook_uuid.len > 0) self.allocator.free(self.facebook_uuid);
    }
    pub fn isLoggedIn(self: *const Device) bool { return self.id != null and !self.id.?.isEmpty(); }
};

/// Trait vtables (Go interfaces → Zig vtables). Each trait is a struct of fn ptrs.
pub const IdentityStoreVTable = struct {
    putIdentity: *const fn (ctx: *anyopaque, address: []const u8, key: [32]u8) anyerror!void,
    deleteAll: *const fn (ctx: *anyopaque, phone: []const u8) anyerror!void,
    deleteOne: *const fn (ctx: *anyopaque, address: []const u8) anyerror!void,
    isTrusted: *const fn (ctx: *anyopaque, address: []const u8, key: [32]u8) anyerror!bool,
};
pub const SessionStoreVTable = struct {
    getSession: *const fn (ctx: *anyopaque, address: []const u8, out: *[]u8) anyerror!void,
    hasSession: *const fn (ctx: *anyopaque, address: []const u8) anyerror!bool,
    putSession: *const fn (ctx: *anyopaque, address: []const u8, session: []const u8) anyerror!void,
    deleteSession: *const fn (ctx: *anyopaque, address: []const u8) anyerror!void,
};

test "store Device init" {
    var d = Device.init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expect(!d.isLoggedIn());
    try std.testing.expect(d.registration_id != 0);
}
