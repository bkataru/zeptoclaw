const std = @import("std");

/// JID helpers — LID vs PN addressing for Signal session lookup.
/// whatsmeow session `their_id` is `user.device` (device omitted when 0).

pub fn atIndex(jid: []const u8) ?usize {
    return std.mem.indexOfScalar(u8, jid, '@');
}

pub fn server(jid: []const u8) []const u8 {
    const at = atIndex(jid) orelse return "";
    return jid[at + 1 ..];
}

pub fn userDevice(jid: []const u8) []const u8 {
    const at = atIndex(jid) orelse return jid;
    return jid[0..at];
}

pub fn user(jid: []const u8) []const u8 {
    const left = userDevice(jid);
    if (std.mem.indexOfScalar(u8, left, ':')) |c| return left[0..c];
    return left;
}

pub fn device(jid: []const u8) u32 {
    const left = userDevice(jid);
    const c = std.mem.indexOfScalar(u8, left, ':') orelse return 0;
    return std.fmt.parseInt(u32, left[c + 1 ..], 10) catch 0;
}

pub fn isLid(jid: []const u8) bool {
    const srv = server(jid);
    return std.mem.eql(u8, srv, "lid") or std.mem.eql(u8, srv, "hosted.lid");
}

pub fn isPn(jid: []const u8) bool {
    const srv = server(jid);
    return std.mem.eql(u8, srv, "s.whatsapp.net") or std.mem.eql(u8, srv, "c.us");
}

/// Signal protocol address string (`user.device`, or just `user` when device is 0).
/// Memory: caller frees.
pub fn signalId(allocator: std.mem.Allocator, jid: []const u8) ![]u8 {
    const u = user(jid);
    const d = device(jid);
    if (d == 0) return allocator.dupe(u8, u);
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ u, d });
}

/// Memory: caller frees. Device 0 omits `:0`.
pub fn format(allocator: std.mem.Allocator, user_s: []const u8, dev: u32, srv: []const u8) ![]u8 {
    if (dev == 0) return std.fmt.allocPrint(allocator, "{s}@{s}", .{ user_s, srv });
    return std.fmt.allocPrint(allocator, "{s}:{d}@{s}", .{ user_s, dev, srv });
}

pub fn pnJid(allocator: std.mem.Allocator, user_s: []const u8, dev: u32) ![]u8 {
    return format(allocator, user_s, dev, "s.whatsapp.net");
}

pub fn lidJid(allocator: std.mem.Allocator, user_s: []const u8, dev: u32) ![]u8 {
    return format(allocator, user_s, dev, "lid");
}

test "jid parse pn and lid" {
    try std.testing.expectEqualStrings("917019895010", user("917019895010:55@s.whatsapp.net"));
    try std.testing.expectEqual(@as(u32, 55), device("917019895010:55@s.whatsapp.net"));
    try std.testing.expect(isPn("917019895010:55@s.whatsapp.net"));
    try std.testing.expect(!isLid("917019895010:55@s.whatsapp.net"));
    try std.testing.expectEqualStrings("216638251077681", user("216638251077681:55@lid"));
    try std.testing.expect(isLid("216638251077681@lid"));
    const sid = try signalId(std.testing.allocator, "216638251077681:55@lid");
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("216638251077681.55", sid);
    const sid0 = try signalId(std.testing.allocator, "15551212@s.whatsapp.net");
    defer std.testing.allocator.free(sid0);
    try std.testing.expectEqualStrings("15551212", sid0);
    const pn = try pnJid(std.testing.allocator, "15551212", 0);
    defer std.testing.allocator.free(pn);
    try std.testing.expectEqualStrings("15551212@s.whatsapp.net", pn);
    const lid_d = try lidJid(std.testing.allocator, "2166", 55);
    defer std.testing.allocator.free(lid_d);
    try std.testing.expectEqualStrings("2166:55@lid", lid_d);
}
