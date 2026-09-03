const std = @import("std");
const binary = @import("binary.zig");
const proto = @import("proto.zig");
const nc = @import("noise_crypto.zig");
const curve_sigs = @import("curve_sigs.zig");

/// Port of whatsmeow/{pair,qrchan,pair-code}.go — QR + pair-device IQ + pair-success HMAC.
/// QR + pair-device IQ used by the native WhatsApp client.
pub const server_jid: []const u8 = "s.whatsapp.net";

pub const PairClientType = enum {
    unknown,
    chrome,
    edge,
    firefox,
    ie,
    opera,
    safari,
    electron,
    uwp,
    other_web,
    macos,
    android,

    pub fn code(self: PairClientType) []const u8 {
        return switch (self) {
            .unknown => "0",
            .chrome => "1",
            .edge => "2",
            .firefox => "3",
            .ie => "4",
            .opera => "5",
            .safari => "6",
            .electron => "7",
            .uwp => "8",
            .other_web => "9",
            .macos => "c",
            .android => "e",
        };
    }
};

/// Matches DeviceProps.platform_type=CHROME (WhatsApp web ubuntu/Chrome companion).
pub const default_client_type: PairClientType = .chrome;

pub const adv_account_sig_prefix: []const u8 = &[_]u8{ 6, 0 };
pub const adv_device_sig_prefix: []const u8 = &[_]u8{ 6, 1 };
pub const adv_hosted_account_sig_prefix: []const u8 = &[_]u8{ 6, 5 };
pub const adv_hosted_device_sig_prefix: []const u8 = &[_]u8{ 6, 6 };

const b64 = std.base64.standard.Encoder;

fn b64Std(out: []u8, data: []const u8) []const u8 {
    return b64.encode(out, data);
}

/// WhatsApp Linked Devices camera comma-splits the QR payload, same as
/// WhatsApp web 6.7 / web.whatsapp.com: `ref,noiseB64,identityB64,advB64`.
/// A `wa.me` URL prefix makes the first field an invalid ref and the phone
/// shows "couldn't link device". `client_type` is kept for API compatibility
/// (whatsmeow's 5th field) but is not encoded — the in-app scanner ignores it.
/// Memory: caller frees.
pub fn makeQRData(
    allocator: std.mem.Allocator,
    ref: []const u8,
    noise_pub: [32]u8,
    identity_pub: [32]u8,
    adv_key: [32]u8,
    client_type: PairClientType,
) ![]u8 {
    _ = client_type;
    var noise_b: [44]u8 = undefined;
    var ident_b: [44]u8 = undefined;
    var adv_b: [44]u8 = undefined;
    const noise_s = b64Std(&noise_b, &noise_pub);
    const ident_s = b64Std(&ident_b, &identity_pub);
    const adv_s = b64Std(&adv_b, &adv_key);
    return std.fmt.allocPrint(allocator, "{s},{s},{s},{s}", .{ ref, noise_s, ident_s, adv_s });
}

/// Memory: caller frees each code and the slice.
pub fn qrCodesFromPairDevice(
    allocator: std.mem.Allocator,
    pair_device: binary.Node,
    noise_pub: [32]u8,
    identity_pub: [32]u8,
    adv_key: [32]u8,
    client_type: PairClientType,
) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }
    for (pair_device.children()) |child| {
        if (!std.mem.eql(u8, child.tag, "ref")) continue;
        const ref = child.contentBytes() orelse continue;
        const code = try makeQRData(allocator, ref, noise_pub, identity_pub, adv_key, client_type);
        try list.append(allocator, code);
    }
    return list.toOwnedSlice(allocator);
}

/// Empty IQ result acknowledging pair-device. Memory: caller frees.
pub fn encodeIqResult(allocator: std.mem.Allocator, to: []const u8, id: []const u8) ![]u8 {
    var node = binary.Node.init(allocator, "iq");
    defer node.deinit();
    try node.attrs.put("to", to);
    try node.attrs.put("id", id);
    try node.attrs.put("type", "result");
    return binary.marshal(allocator, node);
}

/// IQ error for failed pair-success. Memory: caller frees.
pub fn encodePairError(allocator: std.mem.Allocator, id: []const u8, code: u32, text: []const u8) ![]u8 {
    var err_node = binary.Node.init(allocator, "error");
    defer err_node.deinit();
    var code_buf: [10]u8 = undefined;
    const code_s = try std.fmt.bufPrint(&code_buf, "{d}", .{code});
    try err_node.attrs.put("code", code_s);
    try err_node.attrs.put("text", text);

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("type", "error");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&err_node)[0..1] };
    return binary.marshal(allocator, iq);
}

/// pair-device-sign confirmation. Memory: caller frees.
pub fn encodePairDeviceSign(
    allocator: std.mem.Allocator,
    id: []const u8,
    key_index: u32,
    device_identity: []const u8,
) ![]u8 {
    var key_buf: [10]u8 = undefined;
    const key_s = try std.fmt.bufPrint(&key_buf, "{d}", .{key_index});

    var ident = binary.Node.init(allocator, "device-identity");
    defer ident.deinit();
    try ident.attrs.put("key-index", key_s);
    ident.content = .{ .bytes = device_identity };

    var sign = binary.Node.init(allocator, "pair-device-sign");
    defer sign.deinit();
    sign.content = .{ .nodes = (&ident)[0..1] };

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("type", "result");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&sign)[0..1] };
    return binary.marshal(allocator, iq);
}

pub fn hmacPairDetails(adv_key: [32]u8, details: []const u8, hosted: bool) [32]u8 {
    if (!hosted) return nc.hmacSha256(&adv_key, details);
    var tmp: [8192]u8 = undefined;
    std.debug.assert(details.len + 2 <= tmp.len);
    @memcpy(tmp[0..2], adv_hosted_account_sig_prefix);
    @memcpy(tmp[2 .. 2 + details.len], details);
    return nc.hmacSha256(&adv_key, tmp[0 .. 2 + details.len]);
}

pub fn hmacMatches(adv_key: [32]u8, container: proto.ADVSignedDeviceIdentityHMAC) bool {
    const hosted = container.account_type == 1;
    const got = hmacPairDetails(adv_key, container.details, hosted);
    if (container.hmac.len != 32) return false;
    var mac: [32]u8 = undefined;
    @memcpy(&mac, container.hmac[0..32]);
    return std.crypto.timing_safe.eql([32]u8, got, mac);
}

pub fn verifyAccountSignature(
    identity: proto.ADVSignedDeviceIdentity,
    identity_pub: [32]u8,
    hosted: bool,
) bool {
    if (identity.account_signature_key.len != 32 or identity.account_signature.len != 64) return false;
    const prefix = if (hosted) adv_hosted_account_sig_prefix else adv_account_sig_prefix;
    var msg_buf: [8192]u8 = undefined;
    if (prefix.len + identity.details.len + identity_pub.len > msg_buf.len) return false;
    var n: usize = 0;
    @memcpy(msg_buf[n .. n + prefix.len], prefix);
    n += prefix.len;
    @memcpy(msg_buf[n .. n + identity.details.len], identity.details);
    n += identity.details.len;
    @memcpy(msg_buf[n .. n + identity_pub.len], &identity_pub);
    n += identity_pub.len;
    var acct_pub: [32]u8 = undefined;
    @memcpy(&acct_pub, identity.account_signature_key[0..32]);
    var sig: [64]u8 = undefined;
    @memcpy(&sig, identity.account_signature[0..64]);
    curve_sigs.verify(acct_pub, msg_buf[0..n], sig) catch return false;
    return true;
}

/// Device signature over (prefix || details || identity.Pub || accountSignatureKey).
pub fn generateDeviceSignature(
    identity: proto.ADVSignedDeviceIdentity,
    identity_priv: [32]u8,
    identity_pub: [32]u8,
    hosted: bool,
    random: [64]u8,
) ![64]u8 {
    const prefix = if (hosted) adv_hosted_device_sig_prefix else adv_device_sig_prefix;
    var msg_buf: [8192]u8 = undefined;
    var n: usize = 0;
    @memcpy(msg_buf[n .. n + prefix.len], prefix);
    n += prefix.len;
    @memcpy(msg_buf[n .. n + identity.details.len], identity.details);
    n += identity.details.len;
    @memcpy(msg_buf[n .. n + 32], &identity_pub);
    n += 32;
    if (identity.account_signature_key.len != 32) return error.InvalidAccountSignatureKey;
    @memcpy(msg_buf[n .. n + 32], identity.account_signature_key[0..32]);
    n += 32;
    return curve_sigs.sign(identity_priv, msg_buf[0..n], random);
}

pub const PairDeviceEvent = struct {
    id: []const u8,
    from: []const u8,
    codes: [][]u8,
    ack: []u8,

    pub fn deinit(self: PairDeviceEvent, allocator: std.mem.Allocator) void {
        for (self.codes) |c| allocator.free(c);
        allocator.free(self.codes);
        allocator.free(self.ack);
    }
};

/// Parse a pair-device IQ, ACK it, and build QR strings.
pub fn handlePairDevice(
    allocator: std.mem.Allocator,
    iq: binary.Node,
    noise_pub: [32]u8,
    identity_pub: [32]u8,
    adv_key: [32]u8,
    client_type: PairClientType,
) !PairDeviceEvent {
    const id = iq.getAttr("id") orelse return error.MissingIqId;
    const from = iq.getAttr("from") orelse server_jid;
    const pd = iq.getChildByTag("pair-device") orelse return error.MissingPairDevice;
    const codes = try qrCodesFromPairDevice(allocator, pd.*, noise_pub, identity_pub, adv_key, client_type);
    errdefer {
        for (codes) |c| allocator.free(c);
        allocator.free(codes);
    }
    const ack = try encodeIqResult(allocator, from, id);
    return .{ .id = id, .from = from, .codes = codes, .ack = ack };
}

pub const PairSuccessParts = struct {
    id: []const u8,
    device_identity: []const u8,
    jid: []const u8,
    lid: []const u8,
    business_name: []const u8,
    platform: []const u8,
};

pub fn parsePairSuccess(iq: binary.Node) !PairSuccessParts {
    const id = iq.getAttr("id") orelse return error.MissingIqId;
    const ps = iq.getChildByTag("pair-success") orelse return error.MissingPairSuccess;
    const ident_n = ps.getChildByTag("device-identity") orelse return error.MissingDeviceIdentity;
    const ident = ident_n.contentBytes() orelse return error.MissingDeviceIdentity;
    var jid: []const u8 = "";
    var lid: []const u8 = "";
    if (ps.getChildByTag("device")) |dev| {
        jid = dev.getAttr("jid") orelse "";
        lid = dev.getAttr("lid") orelse "";
    }
    var business_name: []const u8 = "";
    if (ps.getChildByTag("biz")) |biz| {
        business_name = biz.getAttr("name") orelse "";
    }
    var platform: []const u8 = "";
    if (ps.getChildByTag("platform")) |p| {
        platform = p.getAttr("name") orelse "";
    }
    return .{
        .id = id,
        .device_identity = ident,
        .jid = jid,
        .lid = lid,
        .business_name = business_name,
        .platform = platform,
    };
}

test "makeQRData chrome-like web client" {
    const ref = "REFTOKEN";
    const noise = [_]u8{0x11} ** 32;
    const ident = [_]u8{0x22} ** 32;
    const adv = [_]u8{0x33} ** 32;
    const qr = try makeQRData(std.testing.allocator, ref, noise, ident, adv, .chrome);
    defer std.testing.allocator.free(qr);
    try std.testing.expect(std.mem.startsWith(u8, qr, "REFTOKEN,"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, qr, ","));
    try std.testing.expect(std.mem.indexOf(u8, qr, "https://") == null);
}

test "hmac pair details match" {
    const key = [_]u8{0xAB} ** 32;
    const details = "signed-device-identity-bytes";
    const mac = hmacPairDetails(key, details, false);
    const container = proto.ADVSignedDeviceIdentityHMAC{ .details = details, .hmac = &mac, .account_type = 0 };
    try std.testing.expect(hmacMatches(key, container));
    var bad = mac;
    bad[0] ^= 1;
    const bad_c = proto.ADVSignedDeviceIdentityHMAC{ .details = details, .hmac = &bad, .account_type = 0 };
    try std.testing.expect(!hmacMatches(key, bad_c));
}

test "pair-device IQ ack + QR codes roundtrip" {
    const alloc = std.testing.allocator;
    var ref1 = binary.Node.init(alloc, "ref");
    defer ref1.deinit();
    ref1.content = .{ .bytes = "aaa" };
    var ref2 = binary.Node.init(alloc, "ref");
    defer ref2.deinit();
    ref2.content = .{ .bytes = "bbb" };
    var kids = [_]binary.Node{ ref1, ref2 };

    var pd = binary.Node.init(alloc, "pair-device");
    defer pd.deinit();
    pd.content = .{ .nodes = &kids };

    var iq = binary.Node.init(alloc, "iq");
    defer iq.deinit();
    try iq.attrs.put("from", server_jid);
    try iq.attrs.put("id", "iq-1");
    try iq.attrs.put("type", "set");
    iq.content = .{ .nodes = (&pd)[0..1] };

    const ev = try handlePairDevice(alloc, iq, [_]u8{1} ** 32, [_]u8{2} ** 32, [_]u8{3} ** 32, .other_web);
    defer ev.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), ev.codes.len);
    try std.testing.expect(std.mem.indexOf(u8, ev.codes[0], "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.codes[1], "bbb") != null);

    var ack = try binary.decodeNode(alloc, ev.ack);
    defer ack.deinit();
    try std.testing.expectEqualStrings("iq", ack.tag);
    try std.testing.expectEqualStrings("result", ack.getAttr("type").?);
    try std.testing.expectEqualStrings("iq-1", ack.getAttr("id").?);
}

test "pair-success parse + device-sign encode" {
    const alloc = std.testing.allocator;
    var ident = binary.Node.init(alloc, "device-identity");
    defer ident.deinit();
    ident.content = .{ .bytes = "hmac-blob" };
    var device = binary.Node.init(alloc, "device");
    defer device.deinit();
    try device.attrs.put("jid", "917019895010:55@s.whatsapp.net");
    try device.attrs.put("lid", "216638251077681:55@lid");
    var kids = [_]binary.Node{ ident, device };
    var ps = binary.Node.init(alloc, "pair-success");
    defer ps.deinit();
    ps.content = .{ .nodes = &kids };
    var iq = binary.Node.init(alloc, "iq");
    defer iq.deinit();
    try iq.attrs.put("id", "ok-1");
    iq.content = .{ .nodes = (&ps)[0..1] };

    const parts = try parsePairSuccess(iq);
    try std.testing.expectEqualStrings("ok-1", parts.id);
    try std.testing.expectEqualStrings("hmac-blob", parts.device_identity);
    try std.testing.expectEqualStrings("917019895010:55@s.whatsapp.net", parts.jid);

    const signed = try encodePairDeviceSign(alloc, parts.id, 1, "self-signed");
    defer alloc.free(signed);
    var out = try binary.decodeNode(alloc, signed);
    defer out.deinit();
    try std.testing.expectEqualStrings("result", out.getAttr("type").?);
    const sign = out.getChildByTag("pair-device-sign") orelse return error.TestUnexpectedResult;
    const di = sign.getChildByTag("device-identity") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", di.getAttr("key-index").?);
}

test "device signature roundtrip" {
    var priv: [32]u8 = [_]u8{0x07} ** 32;
    std.crypto.ecc.Edwards25519.scalar.clamp(&priv);
    const pub_key = std.crypto.dh.X25519.recoverPublicKey(priv) catch unreachable;
    const details = "adv-device-identity-details";
    const acct = [_]u8{0x09} ** 32;
    const ident = proto.ADVSignedDeviceIdentity{
        .details = details,
        .account_signature_key = &acct,
    };
    const sig = try generateDeviceSignature(ident, priv, pub_key, false, [_]u8{0} ** 64);
    var msg_buf: [256]u8 = undefined;
    var n: usize = 0;
    @memcpy(msg_buf[n .. n + 2], adv_device_sig_prefix);
    n += 2;
    @memcpy(msg_buf[n .. n + details.len], details);
    n += details.len;
    @memcpy(msg_buf[n .. n + 32], &pub_key);
    n += 32;
    @memcpy(msg_buf[n .. n + 32], &acct);
    n += 32;
    try curve_sigs.verify(pub_key, msg_buf[0..n], sig);
}
