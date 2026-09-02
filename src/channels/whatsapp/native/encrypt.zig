const std = @import("std");
const binary = @import("binary.zig");
const signal = @import("signal.zig");

/// WhatsApp `xmlns=encrypt` prekey IQ (whatsmeow FetchKeys).
/// GET: `<iq xmlns=encrypt type=get><key><user jid=…/></key></iq>`
/// RESULT: `<iq><list><user jid=…><registration/><identity/><skey>…</skey></user></list></iq>`

pub const server_jid: []const u8 = "s.whatsapp.net";

pub fn beUint(bytes: []const u8) u32 {
    var v: u32 = 0;
    for (bytes) |b| v = (v << 8) | @as(u32, b);
    return v;
}

pub fn writeBe(out: []u8, v: u32) void {
    var x = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast(x & 0xff);
        x >>= 8;
    }
}

fn parseDjb32(bytes: []const u8) ![32]u8 {
    return signal.parseDjb(bytes);
}

pub const ParsedUser = struct {
    jid: []const u8,
    bundle: signal.PreKeyBundle,
};

/// Parse one `<user>` from an encrypt IQ result. Slices alias the node.
pub fn parseUser(user: binary.Node) !ParsedUser {
    if (!std.mem.eql(u8, user.tag, "user")) return error.NotUser;
    const their_jid = user.getAttr("jid") orelse return error.MissingJid;
    const reg_n = user.getChildByTag("registration") orelse return error.MissingRegistration;
    const ident_n = user.getChildByTag("identity") orelse return error.MissingIdentity;
    const skey = user.getChildByTag("skey") orelse return error.MissingSignedPreKey;
    const skey_id_n = skey.getChildByTag("id") orelse return error.MissingSignedPreKeyId;
    const skey_val_n = skey.getChildByTag("value") orelse return error.MissingSignedPreKeyValue;
    const skey_sig_n = skey.getChildByTag("signature") orelse return error.MissingSignedPreKeySig;

    const reg_b = reg_n.contentBytes() orelse return error.MissingRegistration;
    const ident_b = ident_n.contentBytes() orelse return error.MissingIdentity;
    const skey_id_b = skey_id_n.contentBytes() orelse return error.MissingSignedPreKeyId;
    const skey_val_b = skey_val_n.contentBytes() orelse return error.MissingSignedPreKeyValue;
    const skey_sig_b = skey_sig_n.contentBytes() orelse return error.MissingSignedPreKeySig;
    if (skey_sig_b.len != 64) return error.InvalidSignedPreKeySig;

    var bundle = signal.PreKeyBundle{
        .registration_id = beUint(reg_b),
        .signed_prekey_id = beUint(skey_id_b),
        .signed_prekey_pub = try parseDjb32(skey_val_b),
        .signed_prekey_sig = undefined,
        .identity_pub = try parseDjb32(ident_b),
    };
    @memcpy(&bundle.signed_prekey_sig, skey_sig_b[0..64]);

    if (user.getChildByTag("key")) |ot| {
        if (ot.getChildByTag("id")) |id_n| {
            if (id_n.contentBytes()) |id_b| bundle.prekey_id = beUint(id_b);
        }
        if (ot.getChildByTag("value")) |val_n| {
            if (val_n.contentBytes()) |val_b| bundle.prekey_pub = try parseDjb32(val_b);
        }
    }
    return .{ .jid = their_jid, .bundle = bundle };
}

/// Memory: caller frees.
pub fn encodeEncryptGet(allocator: std.mem.Allocator, id: []const u8, users: []const []const u8) ![]u8 {
    if (users.len == 0 or users.len > 32) return error.InvalidUserList;
    var user_nodes: [32]binary.Node = undefined;
    var i: usize = 0;
    while (i < users.len) : (i += 1) {
        user_nodes[i] = binary.Node.init(allocator, "user");
        try user_nodes[i].attrs.put("jid", users[i]);
    }
    defer {
        var j: usize = 0;
        while (j < users.len) : (j += 1) user_nodes[j].deinit();
    }

    var key = binary.Node.init(allocator, "key");
    defer key.deinit();
    key.content = .{ .nodes = user_nodes[0..users.len] };

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("xmlns", "encrypt");
    try iq.attrs.put("type", "get");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&key)[0..1] };
    return binary.marshal(allocator, iq);
}

/// Fake server result for tests. Memory: caller frees.
pub fn encodeEncryptResult(
    allocator: std.mem.Allocator,
    id: []const u8,
    their_jid: []const u8,
    bundle: signal.PreKeyBundle,
) ![]u8 {
    var reg: [4]u8 = undefined;
    writeBe(&reg, bundle.registration_id);
    var spk_id: [3]u8 = undefined;
    writeBe(&spk_id, bundle.signed_prekey_id);

    var registration = binary.Node.init(allocator, "registration");
    defer registration.deinit();
    registration.content = .{ .bytes = &reg };

    var identity = binary.Node.init(allocator, "identity");
    defer identity.deinit();
    identity.content = .{ .bytes = &bundle.identity_pub };

    var sid = binary.Node.init(allocator, "id");
    defer sid.deinit();
    sid.content = .{ .bytes = &spk_id };
    var sval = binary.Node.init(allocator, "value");
    defer sval.deinit();
    sval.content = .{ .bytes = &bundle.signed_prekey_pub };
    var ssig = binary.Node.init(allocator, "signature");
    defer ssig.deinit();
    ssig.content = .{ .bytes = &bundle.signed_prekey_sig };
    var skey_kids = [_]binary.Node{ sid, sval, ssig };
    var skey = binary.Node.init(allocator, "skey");
    defer skey.deinit();
    skey.content = .{ .nodes = &skey_kids };

    var user_kids_buf: [5]binary.Node = undefined;
    var n: usize = 0;
    user_kids_buf[n] = registration;
    n += 1;
    user_kids_buf[n] = identity;
    n += 1;
    user_kids_buf[n] = skey;
    n += 1;

    var ot_id: binary.Node = undefined;
    var ot_val: binary.Node = undefined;
    var ot: binary.Node = undefined;
    var ot_kids: [2]binary.Node = undefined;
    var otk_id: [3]u8 = undefined;
    var opk_copy: [32]u8 = undefined;
    if (bundle.prekey_pub) |opk| {
        writeBe(&otk_id, bundle.prekey_id);
        opk_copy = opk;
        ot_id = binary.Node.init(allocator, "id");
        ot_id.content = .{ .bytes = &otk_id };
        ot_val = binary.Node.init(allocator, "value");
        ot_val.content = .{ .bytes = &opk_copy };
        ot_kids = .{ ot_id, ot_val };
        ot = binary.Node.init(allocator, "key");
        ot.content = .{ .nodes = &ot_kids };
        user_kids_buf[n] = ot;
        n += 1;
    }
    defer if (bundle.prekey_pub != null) {
        ot.deinit();
        ot_id.deinit();
        ot_val.deinit();
    };

    var user = binary.Node.init(allocator, "user");
    defer user.deinit();
    try user.attrs.put("jid", their_jid);
    user.content = .{ .nodes = user_kids_buf[0..n] };

    var list = binary.Node.init(allocator, "list");
    defer list.deinit();
    list.content = .{ .nodes = (&user)[0..1] };

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("xmlns", "encrypt");
    try iq.attrs.put("type", "result");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&list)[0..1] };
    return binary.marshal(allocator, iq);
}

pub fn isEncryptResult(iq: binary.Node) bool {
    if (!std.mem.eql(u8, iq.tag, "iq")) return false;
    if (iq.getAttr("xmlns")) |ns| {
        if (std.mem.eql(u8, ns, "encrypt")) return iq.getChildByTag("list") != null;
    }
    const list = iq.getChildByTag("list") orelse return false;
    const user = list.getChildByTag("user") orelse return false;
    return user.getChildByTag("skey") != null;
}

test "encrypt get/result roundtrip" {
    const alloc = std.testing.allocator;
    const get = try encodeEncryptGet(alloc, "iq-k", &.{ "bob:0@s.whatsapp.net", "carol@lid" });
    defer alloc.free(get);
    var get_n = try binary.decodeNode(alloc, get);
    defer get_n.deinit();
    try std.testing.expectEqualStrings("encrypt", get_n.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("get", get_n.getAttr("type").?);
    const key = get_n.getChildByTag("key") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), key.children().len);

    var spk: [32]u8 = [_]u8{0x11} ** 32;
    var ident: [32]u8 = [_]u8{0x22} ** 32;
    var sig: [64]u8 = [_]u8{0x33} ** 64;
    const bundle = signal.PreKeyBundle{
        .registration_id = 42,
        .signed_prekey_id = 7,
        .signed_prekey_pub = spk,
        .signed_prekey_sig = sig,
        .identity_pub = ident,
        .prekey_id = 9,
        .prekey_pub = [_]u8{0x44} ** 32,
    };
    const result = try encodeEncryptResult(alloc, "iq-k", "bob:0@s.whatsapp.net", bundle);
    defer alloc.free(result);
    var res_n = try binary.decodeNode(alloc, result);
    defer res_n.deinit();
    try std.testing.expect(isEncryptResult(res_n));
    const user = res_n.getChildByTag("list").?.getChildByTag("user").?;
    const parsed = try parseUser(user.*);
    try std.testing.expectEqualStrings("bob@s.whatsapp.net", parsed.jid);
    try std.testing.expectEqual(@as(u32, 42), parsed.bundle.registration_id);
    try std.testing.expectEqual(@as(u32, 7), parsed.bundle.signed_prekey_id);
    try std.testing.expectEqual(@as(u32, 9), parsed.bundle.prekey_id);
    try std.testing.expectEqualSlices(u8, &spk, &parsed.bundle.signed_prekey_pub);
    try std.testing.expectEqualSlices(u8, &ident, &parsed.bundle.identity_pub);
    try std.testing.expectEqualSlices(u8, &sig, &parsed.bundle.signed_prekey_sig);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x44} ** 32), &parsed.bundle.prekey_pub.?);
}
