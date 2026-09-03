const std = @import("std");
const binary = @import("binary.zig");
const jid = @import("jid.zig");

/// Binary stanza builders for chat messages (whatsmeow send.go / receipt.go / prekeys.go / user.go).
/// Ciphertext is Signal-layer; this only wraps it in `<message><enc/></message>`.

pub const server_jid: []const u8 = "s.whatsapp.net";

pub const EncType = enum {
    msg,
    pkmsg,
    skmsg,

    pub fn attr(self: EncType) []const u8 {
        return switch (self) {
            .msg => "msg",
            .pkmsg => "pkmsg",
            .skmsg => "skmsg",
        };
    }
};

/// Memory: caller frees. Uncompressed WA binary node.
pub fn encodeEncryptedMessage(
    allocator: std.mem.Allocator,
    to: []const u8,
    id: []const u8,
    enc_type: EncType,
    ciphertext: []const u8,
    from: ?[]const u8,
) ![]u8 {
    var enc = binary.Node.init(allocator, "enc");
    defer enc.deinit();
    try enc.attrs.put("v", "2");
    try enc.attrs.put("type", enc_type.attr());
    enc.content = .{ .bytes = ciphertext };

    var msg = binary.Node.init(allocator, "message");
    defer msg.deinit();
    try msg.attrs.put("to", to);
    try msg.attrs.put("id", id);
    try msg.attrs.put("type", "text");
    if (from) |f| try msg.attrs.put("from", f);
    msg.content = .{ .nodes = (&enc)[0..1] };
    return binary.marshal(allocator, msg);
}

pub fn receiptType(node: binary.Node) ?[]const u8 {
    if (!std.mem.eql(u8, node.tag, "receipt")) return null;
    return node.getAttr("type");
}

pub const EncPayload = struct {
    from: []const u8,
    to: []const u8,
    id: []const u8,
    enc_type: EncType,
    version: u32,
    ciphertext: []const u8,
};

fn parseEncChild(parent: binary.Node, enc: binary.Node) !EncPayload {
    const type_s = enc.getAttr("type") orelse return error.MissingEncType;
    const enc_type: EncType = if (std.mem.eql(u8, type_s, "pkmsg"))
        .pkmsg
    else if (std.mem.eql(u8, type_s, "skmsg"))
        .skmsg
    else
        .msg;
    const v_s = enc.getAttr("v") orelse "2";
    const version = std.fmt.parseInt(u32, v_s, 10) catch 2;
    const ct = enc.contentBytes() orelse return error.MissingCiphertext;
    return .{
        .from = parent.getAttr("from") orelse "",
        .to = parent.getAttr("to") orelse "",
        .id = parent.getAttr("id") orelse "",
        .enc_type = enc_type,
        .version = version,
        .ciphertext = ct,
    };
}

pub fn parseEnc(node: binary.Node) !EncPayload {
    if (!std.mem.eql(u8, node.tag, "message")) return error.NotMessage;
    const enc = node.getChildByTag("enc") orelse return error.MissingEnc;
    return parseEncChild(node, enc.*);
}

fn putAttr(node: *binary.Node, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try node.attrs.put(key, value);
}

fn writeU24BE(buf: *[3]u8, v: u32) void {
    buf.*[0] = @intCast((v >> 16) & 0xff);
    buf.*[1] = @intCast((v >> 8) & 0xff);
    buf.*[2] = @intCast(v & 0xff);
}

fn userMatchesOwn(sender: []const u8, own_jid: ?[]const u8, own_lid: ?[]const u8) bool {
    const su = jid.user(sender);
    if (su.len == 0) return false;
    if (own_jid) |o| {
        if (std.mem.eql(u8, su, jid.user(o))) return true;
    }
    if (own_lid) |o| {
        if (std.mem.eql(u8, su, jid.user(o))) return true;
    }
    return false;
}

/// Memory: caller frees. whatsmeow sendAck: class=tag, to=from, optional participant/recipient/type.
pub fn encodeAck(allocator: std.mem.Allocator, inbound: binary.Node) ![]u8 {
    var ack = binary.Node.init(allocator, "ack");
    defer ack.deinit();
    try ack.attrs.put("class", inbound.tag);
    try putAttr(&ack, "id", inbound.getAttr("id") orelse "");
    try putAttr(&ack, "to", inbound.getAttr("from") orelse "");
    if (inbound.getAttr("participant")) |p| try ack.attrs.put("participant", p);
    if (inbound.getAttr("recipient")) |r| try ack.attrs.put("recipient", r);
    if (!std.mem.eql(u8, inbound.tag, "message")) {
        if (inbound.getAttr("type")) |t| try ack.attrs.put("type", t);
    }
    return binary.marshal(allocator, ack);
}

/// Memory: caller frees. `<receipt to id [type] [t] [participant]/>`.
/// `t` is Unix seconds, required on explicit read/read-self receipts.
pub fn encodeReceipt(
    allocator: std.mem.Allocator,
    to: []const u8,
    id: []const u8,
    receipt_type: ?[]const u8,
    participant: ?[]const u8,
    t: ?i64,
) ![]u8 {
    var rec = binary.Node.init(allocator, "receipt");
    defer rec.deinit();
    try rec.attrs.put("to", to);
    try rec.attrs.put("id", id);
    if (receipt_type) |tt| try rec.attrs.put("type", tt);
    if (t) |ts| {
        var ts_buf: [24]u8 = undefined;
        const ts_s = std.fmt.bufPrint(&ts_buf, "{d}", .{ts}) catch return error.OutOfMemory;
        try rec.attrs.put("t", ts_s);
    }
    if (participant) |p| try rec.attrs.put("participant", p);
    return binary.marshal(allocator, rec);
}

/// Memory: caller frees. Keepalive: `<iq to=s.whatsapp.net type=get xmlns=w:p id><ping/></iq>`.
pub fn encodePingIq(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var ping = binary.Node.init(allocator, "ping");
    defer ping.deinit();
    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("type", "get");
    try iq.attrs.put("xmlns", "w:p");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&ping)[0..1] };
    return binary.marshal(allocator, iq);
}

/// Memory: caller frees. `<iq type=result to id/>`.
pub fn encodeIqResult(allocator: std.mem.Allocator, id: []const u8, to: []const u8) ![]u8 {
    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("type", "result");
    try iq.attrs.put("to", to);
    try iq.attrs.put("id", id);
    return binary.marshal(allocator, iq);
}

/// Memory: caller frees. whatsmeow SetPassive: `<iq xmlns=passive type=set to=s.whatsapp.net id><active/>|<passive/></iq>`.
pub fn encodePassiveIq(allocator: std.mem.Allocator, id: []const u8, active: bool) ![]u8 {
    var child = binary.Node.init(allocator, if (active) "active" else "passive");
    defer child.deinit();
    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("xmlns", "passive");
    try iq.attrs.put("type", "set");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&child)[0..1] };
    return binary.marshal(allocator, iq);
}

/// Memory: caller frees. `<iq xmlns=w:m type=set to=s.whatsapp.net id><media_conn/></iq>`.
pub fn encodeMediaConnIq(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var child = binary.Node.init(allocator, "media_conn");
    defer child.deinit();
    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("xmlns", "w:m");
    try iq.attrs.put("type", "set");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&child)[0..1] };
    return binary.marshal(allocator, iq);
}

pub const MediaConn = struct {
    auth: []const u8,
    hostname: []const u8,
    ttl: u32,
};

/// Slices alias `node` attrs. Looks for `<media_conn auth ttl>` with a `<host hostname>`.
pub fn parseMediaConn(node: binary.Node) !MediaConn {
    const mc = node.getChildByTag("media_conn") orelse {
        if (std.mem.eql(u8, node.tag, "media_conn")) return parseMediaConnNode(node);
        return error.NoMediaConn;
    };
    return parseMediaConnNode(mc.*);
}

fn parseMediaConnNode(mc: binary.Node) !MediaConn {
    const auth = mc.getAttr("auth") orelse return error.NoMediaAuth;
    var ttl: u32 = 600;
    if (mc.getAttr("ttl")) |ts| ttl = std.fmt.parseInt(u32, ts, 10) catch 600;
    var hostname: []const u8 = "mmg.whatsapp.net";
    if (mc.getChildByTag("host")) |h| {
        if (h.getAttr("hostname")) |hn| hostname = hn;
    }
    return .{ .auth = auth, .hostname = hostname, .ttl = ttl };
}

/// Memory: caller frees. `<presence type=… [name]/>`.
pub fn encodePresence(allocator: std.mem.Allocator, presence_type: []const u8, name: ?[]const u8) ![]u8 {
    var p = binary.Node.init(allocator, "presence");
    defer p.deinit();
    try p.attrs.put("type", presence_type);
    if (name) |n| try p.attrs.put("name", n);
    return binary.marshal(allocator, p);
}

pub const PreKeyPub = struct { id: u32, pub_key: [32]u8 };

/// Memory: caller frees. whatsmeow uploadPreKeys: registration 4B BE, type 0x05, identity 32B raw, list of key, skey.
pub fn encodePreKeyUpload(
    allocator: std.mem.Allocator,
    id: []const u8,
    registration_id: u32,
    identity_pub: [32]u8,
    signed_id: u32,
    signed_pub: [32]u8,
    signed_sig: [64]u8,
    one_time: []const PreKeyPub,
) ![]u8 {
    var registration: [4]u8 = undefined;
    std.mem.writeInt(u32, &registration, registration_id, .big);
    const type_byte = [_]u8{0x05};
    var signed_id_be: [3]u8 = undefined;
    writeU24BE(&signed_id_be, signed_id);

    const ot_ids = try allocator.alloc([3]u8, one_time.len);
    defer allocator.free(ot_ids);
    const key_nodes = try allocator.alloc(binary.Node, one_time.len);
    defer {
        for (key_nodes) |*n| n.deinit();
        allocator.free(key_nodes);
    }
    const key_kids = try allocator.alloc([2]binary.Node, one_time.len);
    defer {
        for (key_kids) |*pair| {
            pair[0].deinit();
            pair[1].deinit();
        }
        allocator.free(key_kids);
    }
    for (one_time, 0..) |pk, i| {
        writeU24BE(&ot_ids[i], pk.id);
        key_kids[i][0] = binary.Node.init(allocator, "id");
        key_kids[i][0].content = .{ .bytes = &ot_ids[i] };
        key_kids[i][1] = binary.Node.init(allocator, "value");
        key_kids[i][1].content = .{ .bytes = &one_time[i].pub_key };
        key_nodes[i] = binary.Node.init(allocator, "key");
        key_nodes[i].content = .{ .nodes = &key_kids[i] };
    }

    var iq_kids: [5]binary.Node = .{
        binary.Node.init(allocator, "registration"),
        binary.Node.init(allocator, "type"),
        binary.Node.init(allocator, "identity"),
        binary.Node.init(allocator, "list"),
        binary.Node.init(allocator, "skey"),
    };
    defer for (&iq_kids) |*n| n.deinit();
    iq_kids[0].content = .{ .bytes = &registration };
    iq_kids[1].content = .{ .bytes = &type_byte };
    iq_kids[2].content = .{ .bytes = &identity_pub };
    if (one_time.len > 0) iq_kids[3].content = .{ .nodes = key_nodes };

    var skey_kids: [3]binary.Node = .{
        binary.Node.init(allocator, "id"),
        binary.Node.init(allocator, "value"),
        binary.Node.init(allocator, "signature"),
    };
    defer for (&skey_kids) |*n| n.deinit();
    skey_kids[0].content = .{ .bytes = &signed_id_be };
    skey_kids[1].content = .{ .bytes = &signed_pub };
    skey_kids[2].content = .{ .bytes = &signed_sig };
    iq_kids[4].content = .{ .nodes = &skey_kids };

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("xmlns", "encrypt");
    try iq.attrs.put("type", "set");
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = &iq_kids };
    return binary.marshal(allocator, iq);
}

/// Memory: caller frees. `<iq xmlns=encrypt type=get to=s.whatsapp.net id><count/></iq>`.
pub fn encodePreKeyCountIq(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var count = binary.Node.init(allocator, "count");
    defer count.deinit();
    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("xmlns", "encrypt");
    try iq.attrs.put("type", "get");
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&count)[0..1] };
    return binary.marshal(allocator, iq);
}

pub fn parsePreKeyCount(node: binary.Node) !u32 {
    const count = node.getChildByTag("count") orelse return error.MissingCount;
    const v = count.getAttr("value") orelse return error.MissingCountValue;
    return std.fmt.parseInt(u32, v, 10) catch error.InvalidCount;
}

/// Memory: caller frees. whatsmeow GetUserDevices usync query.
pub fn encodeUsyncDevices(allocator: std.mem.Allocator, id: []const u8, sid: []const u8, jids: []const []const u8) ![]u8 {
    const users = try allocator.alloc(binary.Node, jids.len);
    defer {
        for (users) |*n| n.deinit();
        allocator.free(users);
    }
    for (jids, 0..) |j, i| {
        users[i] = binary.Node.init(allocator, "user");
        try users[i].attrs.put("jid", j);
    }

    var devices = binary.Node.init(allocator, "devices");
    defer devices.deinit();
    try devices.attrs.put("version", "2");

    var usync_kids: [2]binary.Node = .{
        binary.Node.init(allocator, "query"),
        binary.Node.init(allocator, "list"),
    };
    defer for (&usync_kids) |*n| n.deinit();
    usync_kids[0].content = .{ .nodes = (&devices)[0..1] };
    if (jids.len > 0) usync_kids[1].content = .{ .nodes = users };

    var usync = binary.Node.init(allocator, "usync");
    defer usync.deinit();
    try usync.attrs.put("sid", sid);
    try usync.attrs.put("context", "message");
    try usync.attrs.put("mode", "query");
    try usync.attrs.put("last", "true");
    try usync.attrs.put("index", "0");
    usync.content = .{ .nodes = &usync_kids };

    var iq = binary.Node.init(allocator, "iq");
    defer iq.deinit();
    try iq.attrs.put("to", server_jid);
    try iq.attrs.put("type", "get");
    try iq.attrs.put("xmlns", "usync");
    try iq.attrs.put("id", id);
    iq.content = .{ .nodes = (&usync)[0..1] };
    return binary.marshal(allocator, iq);
}

/// Slices alias the parsed node. Memory: caller frees the returned slice.
pub const DeviceEntry = struct { user_jid: []const u8, device: u32, key_index: u32 };

fn usyncList(node: binary.Node) ?*binary.Node {
    if (std.mem.eql(u8, node.tag, "list")) {
        // Can't return pointer to by-value param; walk from children of a wrapper instead.
        return null;
    }
    if (std.mem.eql(u8, node.tag, "usync")) return node.getChildByTag("list");
    if (std.mem.eql(u8, node.tag, "iq")) {
        if (node.getChildByTag("usync")) |u| {
            if (u.getChildByTag("list")) |l| return l;
        }
        return node.getChildByTag("list");
    }
    return null;
}

/// Memory: caller frees the slice; DeviceEntry strings alias `node`.
pub fn parseUsyncDevices(allocator: std.mem.Allocator, node: binary.Node) ![]DeviceEntry {
    const list_node: binary.Node = blk: {
        if (std.mem.eql(u8, node.tag, "list")) break :blk node;
        if (usyncList(node)) |l| break :blk l.*;
        return allocator.alloc(DeviceEntry, 0);
    };

    var out: std.ArrayList(DeviceEntry) = .empty;
    errdefer out.deinit(allocator);

    for (list_node.children()) |user| {
        if (!std.mem.eql(u8, user.tag, "user")) continue;
        const user_jid = user.getAttr("jid") orelse continue;
        const devices = user.getChildByTag("devices") orelse continue;
        const device_list = devices.getChildByTag("device-list") orelse continue;
        for (device_list.children()) |dev| {
            if (!std.mem.eql(u8, dev.tag, "device")) continue;
            const id_s = dev.getAttr("id") orelse continue;
            const device = std.fmt.parseInt(u32, id_s, 10) catch continue;
            const key_index = if (dev.getAttr("key-index")) |k|
                std.fmt.parseInt(u32, k, 10) catch 0
            else
                0;
            try out.append(allocator, .{
                .user_jid = user_jid,
                .device = device,
                .key_index = key_index,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const Participant = struct { jid: []const u8, enc_type: EncType, ciphertext: []const u8 };

/// Memory: caller frees. `<message to id type=text [peer_recipient_pn]><participants>…</participants>[device-identity]</message>`.
/// `peer_recipient_pn` is the recipient's phone JID; required for LID-addressed 1:1 DMs
/// (whatsmeow SendMessage rewrites PN destinations to LID and sets this attr).
pub fn encodeMessageMulti(
    allocator: std.mem.Allocator,
    to: []const u8,
    id: []const u8,
    participants: []const Participant,
    device_identity: ?[]const u8,
    peer_recipient_pn: ?[]const u8,
) ![]u8 {
    const enc_nodes = try allocator.alloc(binary.Node, participants.len);
    defer {
        for (enc_nodes) |*n| n.deinit();
        allocator.free(enc_nodes);
    }
    const to_nodes = try allocator.alloc(binary.Node, participants.len);
    defer {
        for (to_nodes) |*n| n.deinit();
        allocator.free(to_nodes);
    }
    for (participants, 0..) |p, i| {
        enc_nodes[i] = binary.Node.init(allocator, "enc");
        try enc_nodes[i].attrs.put("v", "2");
        try enc_nodes[i].attrs.put("type", p.enc_type.attr());
        enc_nodes[i].content = .{ .bytes = p.ciphertext };
        to_nodes[i] = binary.Node.init(allocator, "to");
        try to_nodes[i].attrs.put("jid", p.jid);
        to_nodes[i].content = .{ .nodes = enc_nodes[i .. i + 1] };
    }

    const n_kids: usize = if (device_identity != null) 2 else 1;
    const kids = try allocator.alloc(binary.Node, n_kids);
    defer {
        for (kids) |*n| n.deinit();
        allocator.free(kids);
    }
    kids[0] = binary.Node.init(allocator, "participants");
    if (participants.len > 0) kids[0].content = .{ .nodes = to_nodes };
    if (device_identity) |di| {
        kids[1] = binary.Node.init(allocator, "device-identity");
        kids[1].content = .{ .bytes = di };
    }

    var msg = binary.Node.init(allocator, "message");
    defer msg.deinit();
    try msg.attrs.put("to", to);
    try msg.attrs.put("id", id);
    try msg.attrs.put("type", "text");
    if (peer_recipient_pn) |pn| try msg.attrs.put("peer_recipient_pn", pn);
    msg.content = .{ .nodes = kids };
    return binary.marshal(allocator, msg);
}

/// Memory: caller frees. Single-device resend of a message that got a
/// `<receipt type=retry>`: bare `<enc>` (no `<participants>` wrapper),
/// addressed directly at the retrying device with `device_fanout=false`
/// (whatsmeow handleRetryReceipt — targeted resend, not a fresh fanout).
pub fn encodeRetryResend(
    allocator: std.mem.Allocator,
    to_device: []const u8,
    id: []const u8,
    enc_type: EncType,
    ciphertext: []const u8,
    device_identity: ?[]const u8,
) ![]u8 {
    var enc = binary.Node.init(allocator, "enc");
    defer enc.deinit();
    try enc.attrs.put("v", "2");
    try enc.attrs.put("type", enc_type.attr());
    enc.content = .{ .bytes = ciphertext };

    var di = binary.Node.init(allocator, "device-identity");
    defer di.deinit();
    if (device_identity) |d| di.content = .{ .bytes = d };

    var kids: [2]binary.Node = .{ enc, di };
    const n_kids: usize = if (device_identity != null) 2 else 1;

    var msg = binary.Node.init(allocator, "message");
    defer msg.deinit();
    try msg.attrs.put("to", to_device);
    try msg.attrs.put("id", id);
    try msg.attrs.put("type", "text");
    try msg.attrs.put("device_fanout", "false");
    msg.content = .{ .nodes = kids[0..n_kids] };
    return binary.marshal(allocator, msg);
}

/// Strings alias `node`. Memory: caller frees `encs`.
pub const MessageInfo = struct {
    id: []const u8,
    chat: []const u8,
    sender: []const u8,
    sender_alt: ?[]const u8,
    participant: ?[]const u8,
    from_me: bool,
    timestamp: i64,
    is_group: bool,
    push_name: ?[]const u8,
    encs: []EncPayload,
};

/// whatsmeow parseMessageSource + parseMessageInfo. Memory: caller frees `encs`.
pub fn parseMessageInfo(allocator: std.mem.Allocator, node: binary.Node, own_jid: ?[]const u8, own_lid: ?[]const u8) !MessageInfo {
    const from = node.getAttr("from") orelse "";
    const participant = node.getAttr("participant");
    const recipient = node.getAttr("recipient");
    const is_group = std.mem.eql(u8, jid.server(from), "g.us");

    var chat: []const u8 = from;
    var sender: []const u8 = from;
    var sender_alt: ?[]const u8 = null;

    if (is_group) {
        sender = participant orelse "";
        sender_alt = node.getAttr("participant_pn") orelse node.getAttr("participant_lid");
    } else {
        sender_alt = node.getAttr("sender_pn") orelse node.getAttr("sender_lid") orelse node.getAttr("participant_pn");
    }

    const from_me = userMatchesOwn(sender, own_jid, own_lid);
    if (!is_group and from_me) {
        if (recipient) |r| chat = r;
    }

    const t_s = node.getAttr("t") orelse "0";
    const timestamp = std.fmt.parseInt(i64, t_s, 10) catch 0;

    var n_enc: usize = 0;
    for (node.children()) |ch| {
        if (std.mem.eql(u8, ch.tag, "enc")) n_enc += 1;
    }
    const encs = try allocator.alloc(EncPayload, n_enc);
    errdefer allocator.free(encs);
    var i: usize = 0;
    for (node.children()) |ch| {
        if (!std.mem.eql(u8, ch.tag, "enc")) continue;
        encs[i] = try parseEncChild(node, ch);
        i += 1;
    }

    return .{
        .id = node.getAttr("id") orelse "",
        .chat = chat,
        .sender = sender,
        .sender_alt = sender_alt,
        .participant = participant,
        .from_me = from_me,
        .timestamp = timestamp,
        .is_group = is_group,
        .push_name = node.getAttr("notify"),
        .encs = encs,
    };
}

pub fn parseStreamErrorCode(node: binary.Node) u32 {
    if (node.getAttr("code")) |c| {
        return std.fmt.parseInt(u32, c, 10) catch 0;
    }
    return 0;
}

pub fn isServerPing(node: binary.Node) bool {
    if (!std.mem.eql(u8, node.tag, "iq")) return false;
    const typ = node.getAttr("type") orelse return false;
    const xmlns = node.getAttr("xmlns") orelse return false;
    return std.mem.eql(u8, typ, "get") and std.mem.eql(u8, xmlns, "urn:xmpp:ping");
}

pub fn parseOfflineCount(node: binary.Node) ?u32 {
    const offline = if (std.mem.eql(u8, node.tag, "offline"))
        node
    else if (node.getChildByTag("offline")) |c|
        c.*
    else
        return null;
    const v = offline.getAttr("count") orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

pub fn parseNotificationType(node: binary.Node) ?[]const u8 {
    if (!std.mem.eql(u8, node.tag, "notification")) return null;
    return node.getAttr("type");
}

pub const RetryKeys = struct {
    identity_pub: [32]u8,
    one_time: PreKeyPub,
    signed_id: u32,
    signed_pub: [32]u8,
    signed_sig: [64]u8,
    device_identity: []const u8,
};

/// Memory: caller frees. whatsmeow sendRetryReceipt.
pub fn encodeRetryReceipt(
    allocator: std.mem.Allocator,
    to: []const u8,
    id: []const u8,
    participant: ?[]const u8,
    t: []const u8,
    count: u32,
    registration_id: u32,
    keys: ?RetryKeys,
) ![]u8 {
    var count_buf: [10]u8 = undefined;
    const count_s = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch unreachable;
    var registration: [4]u8 = undefined;
    std.mem.writeInt(u32, &registration, registration_id, .big);

    var retry = binary.Node.init(allocator, "retry");
    defer retry.deinit();
    try retry.attrs.put("count", count_s);
    try retry.attrs.put("id", id);
    try retry.attrs.put("t", t);
    try retry.attrs.put("v", "1");

    var reg = binary.Node.init(allocator, "registration");
    defer reg.deinit();
    reg.content = .{ .bytes = &registration };

    var type_byte: [1]u8 = .{0x05};
    var ot_id: [3]u8 = undefined;
    var signed_id_be: [3]u8 = undefined;

    var keys_node: ?binary.Node = null;
    var keys_kids: [5]binary.Node = undefined;
    var key_kids: [2]binary.Node = undefined;
    var skey_kids: [3]binary.Node = undefined;
    if (keys) |*k| {
        writeU24BE(&ot_id, k.one_time.id);
        writeU24BE(&signed_id_be, k.signed_id);

        keys_kids[0] = binary.Node.init(allocator, "type");
        keys_kids[0].content = .{ .bytes = &type_byte };
        keys_kids[1] = binary.Node.init(allocator, "identity");
        keys_kids[1].content = .{ .bytes = &k.identity_pub };

        key_kids[0] = binary.Node.init(allocator, "id");
        key_kids[0].content = .{ .bytes = &ot_id };
        key_kids[1] = binary.Node.init(allocator, "value");
        key_kids[1].content = .{ .bytes = &k.one_time.pub_key };
        keys_kids[2] = binary.Node.init(allocator, "key");
        keys_kids[2].content = .{ .nodes = &key_kids };

        skey_kids[0] = binary.Node.init(allocator, "id");
        skey_kids[0].content = .{ .bytes = &signed_id_be };
        skey_kids[1] = binary.Node.init(allocator, "value");
        skey_kids[1].content = .{ .bytes = &k.signed_pub };
        skey_kids[2] = binary.Node.init(allocator, "signature");
        skey_kids[2].content = .{ .bytes = &k.signed_sig };
        keys_kids[3] = binary.Node.init(allocator, "skey");
        keys_kids[3].content = .{ .nodes = &skey_kids };

        keys_kids[4] = binary.Node.init(allocator, "device-identity");
        keys_kids[4].content = .{ .bytes = k.device_identity };

        var kn = binary.Node.init(allocator, "keys");
        kn.content = .{ .nodes = &keys_kids };
        keys_node = kn;
    }
    defer {
        if (keys_node != null) {
            for (&keys_kids) |*n| n.deinit();
            for (&key_kids) |*n| n.deinit();
            for (&skey_kids) |*n| n.deinit();
            keys_node.?.deinit();
        }
    }

    var content_buf: [3]binary.Node = undefined;
    content_buf[0] = retry;
    content_buf[1] = reg;
    var n_content: usize = 2;
    if (keys_node) |kn| {
        content_buf[2] = kn;
        n_content = 3;
    }

    var rec = binary.Node.init(allocator, "receipt");
    defer rec.deinit();
    try rec.attrs.put("to", to);
    try rec.attrs.put("id", id);
    try rec.attrs.put("type", "retry");
    if (participant) |p| try rec.attrs.put("participant", p);
    rec.content = .{ .nodes = content_buf[0..n_content] };
    return binary.marshal(allocator, rec);
}

test "encrypted message stanza roundtrip" {
    const alloc = std.testing.allocator;
    const ct = "ciphertext-bytes";
    const wire = try encodeEncryptedMessage(alloc, "15551212@s.whatsapp.net", "ABCD", .msg, ct, "me@s.whatsapp.net");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("message", node.tag);
    try std.testing.expectEqualStrings("15551212@s.whatsapp.net", node.getAttr("to").?);
    try std.testing.expectEqualStrings("me@s.whatsapp.net", node.getAttr("from").?);
    try std.testing.expectEqualStrings("text", node.getAttr("type").?);
    const parsed = try parseEnc(node);
    try std.testing.expectEqual(EncType.msg, parsed.enc_type);
    const enc = node.getChildByTag("enc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", enc.getAttr("v").?);
    try std.testing.expectEqualStrings("msg", enc.getAttr("type").?);
    try std.testing.expectEqualStrings(ct, enc.contentBytes().?);
}

test "encodeAck message omits type copies participant" {
    const alloc = std.testing.allocator;
    var inbound = binary.Node.init(alloc, "message");
    defer inbound.deinit();
    try inbound.attrs.put("from", "1234:5@s.whatsapp.net");
    try inbound.attrs.put("id", "MID");
    try inbound.attrs.put("type", "text");
    try inbound.attrs.put("participant", "999@s.whatsapp.net");
    const wire = try encodeAck(alloc, inbound);
    defer alloc.free(wire);
    var ack = try binary.decodeNode(alloc, wire);
    defer ack.deinit();
    try std.testing.expectEqualStrings("ack", ack.tag);
    try std.testing.expectEqualStrings("message", ack.getAttr("class").?);
    try std.testing.expectEqualStrings("MID", ack.getAttr("id").?);
    try std.testing.expectEqualStrings("1234:5@s.whatsapp.net", ack.getAttr("to").?);
    try std.testing.expectEqualStrings("999@s.whatsapp.net", ack.getAttr("participant").?);
    try std.testing.expect(ack.getAttr("type") == null);
}

test "encodeAck receipt copies type" {
    const alloc = std.testing.allocator;
    var inbound = binary.Node.init(alloc, "receipt");
    defer inbound.deinit();
    try inbound.attrs.put("from", "s.whatsapp.net");
    try inbound.attrs.put("id", "RID");
    try inbound.attrs.put("type", "inactive");
    const wire = try encodeAck(alloc, inbound);
    defer alloc.free(wire);
    var ack = try binary.decodeNode(alloc, wire);
    defer ack.deinit();
    try std.testing.expectEqualStrings("receipt", ack.getAttr("class").?);
    try std.testing.expectEqualStrings("inactive", ack.getAttr("type").?);
}

test "encodeReceipt roundtrip" {
    const alloc = std.testing.allocator;
    const wire = try encodeReceipt(alloc, "1234@s.whatsapp.net", "MID", "inactive", "p@s.whatsapp.net", null);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("receipt", node.tag);
    try std.testing.expectEqualStrings("1234@s.whatsapp.net", node.getAttr("to").?);
    try std.testing.expectEqualStrings("MID", node.getAttr("id").?);
    try std.testing.expectEqualStrings("inactive", node.getAttr("type").?);
    try std.testing.expectEqualStrings("p@s.whatsapp.net", node.getAttr("participant").?);
    try std.testing.expect(node.getAttr("t") == null);
}

test "encodeReceipt read includes t" {
    const alloc = std.testing.allocator;
    const wire = try encodeReceipt(alloc, "1234@s.whatsapp.net", "MID", "read", null, 1700000000);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("read", node.getAttr("type").?);
    try std.testing.expectEqualStrings("1700000000", node.getAttr("t").?);
}

test "encodePingIq roundtrip" {
    const alloc = std.testing.allocator;
    const wire = try encodePingIq(alloc, "ping-1");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
    try std.testing.expectEqualStrings("get", node.getAttr("type").?);
    try std.testing.expectEqualStrings("w:p", node.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("ping-1", node.getAttr("id").?);
    try std.testing.expect(node.getChildByTag("ping") != null);
}

test "encodeIqResult roundtrip" {
    const alloc = std.testing.allocator;
    const wire = try encodeIqResult(alloc, "iq-9", server_jid);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings("result", node.getAttr("type").?);
    try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
    try std.testing.expectEqualStrings("iq-9", node.getAttr("id").?);
}

test "encodePassiveIq active and passive" {
    const alloc = std.testing.allocator;
    {
        const wire = try encodePassiveIq(alloc, "p1", true);
        defer alloc.free(wire);
        var node = try binary.decodeNode(alloc, wire);
        defer node.deinit();
        try std.testing.expectEqualStrings("iq", node.tag);
        try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
        try std.testing.expectEqualStrings("passive", node.getAttr("xmlns").?);
        try std.testing.expectEqualStrings("set", node.getAttr("type").?);
        try std.testing.expectEqualStrings("p1", node.getAttr("id").?);
        try std.testing.expect(node.getChildByTag("active") != null);
    }
    {
        const wire = try encodePassiveIq(alloc, "p2", false);
        defer alloc.free(wire);
        var node = try binary.decodeNode(alloc, wire);
        defer node.deinit();
        try std.testing.expect(node.getChildByTag("passive") != null);
    }
}

test "encodePresence roundtrip" {
    const alloc = std.testing.allocator;
    const wire = try encodePresence(alloc, "available", "Barvis");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("presence", node.tag);
    try std.testing.expectEqualStrings("available", node.getAttr("type").?);
    try std.testing.expectEqualStrings("Barvis", node.getAttr("name").?);
}

test "encodePreKeyCountIq and parsePreKeyCount" {
    const alloc = std.testing.allocator;
    const wire = try encodePreKeyCountIq(alloc, "cnt-1");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings("encrypt", node.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("get", node.getAttr("type").?);
    try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
    try std.testing.expectEqualStrings("cnt-1", node.getAttr("id").?);
    try std.testing.expect(node.getChildByTag("count") != null);

    var result = binary.Node.init(alloc, "iq");
    defer result.deinit();
    var count = binary.Node.init(alloc, "count");
    defer count.deinit();
    try count.attrs.put("value", "42");
    result.content = .{ .nodes = (&count)[0..1] };
    try std.testing.expectEqual(@as(u32, 42), try parsePreKeyCount(result));
}

test "encodePreKeyUpload ids are big-endian and list length matches" {
    const alloc = std.testing.allocator;
    const ident = [_]u8{0x11} ** 32;
    const spk = [_]u8{0x22} ** 32;
    const sig = [_]u8{0x33} ** 64;
    const ot = [_]PreKeyPub{
        .{ .id = 7, .pub_key = [_]u8{0x44} ** 32 },
        .{ .id = 8, .pub_key = [_]u8{0x55} ** 32 },
    };
    const wire = try encodePreKeyUpload(alloc, "pk-1", 0x01020304, ident, 0x0000aabb, spk, sig, &ot);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings("encrypt", node.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("set", node.getAttr("type").?);
    try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
    try std.testing.expectEqualStrings("pk-1", node.getAttr("id").?);

    const reg = node.getChildByTag("registration") orelse return error.TestUnexpectedResult;
    const reg_b = reg.contentBytes() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), reg_b.len);
    try std.testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, reg_b[0..4], .big));

    const typ = node.getChildByTag("type") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &[_]u8{0x05}, typ.contentBytes().?);

    const ident_n = node.getChildByTag("identity") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &ident, ident_n.contentBytes().?);

    const list = node.getChildByTag("list") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), list.children().len);

    const skey = node.getChildByTag("skey") orelse return error.TestUnexpectedResult;
    const sid = skey.getChildByTag("id") orelse return error.TestUnexpectedResult;
    const sid_b = sid.contentBytes() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), sid_b.len);
    try std.testing.expectEqual(@as(u8, 0x00), sid_b[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), sid_b[1]);
    try std.testing.expectEqual(@as(u8, 0xbb), sid_b[2]);
    try std.testing.expectEqualSlices(u8, &spk, skey.getChildByTag("value").?.contentBytes().?);
    try std.testing.expectEqualSlices(u8, &sig, skey.getChildByTag("signature").?.contentBytes().?);
}

test "encodeUsyncDevices roundtrip" {
    const alloc = std.testing.allocator;
    const jids = [_][]const u8{ "1234@s.whatsapp.net", "5678@lid" };
    const wire = try encodeUsyncDevices(alloc, "us-1", "sid-9", &jids);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings(server_jid, node.getAttr("to").?);
    try std.testing.expectEqualStrings("get", node.getAttr("type").?);
    try std.testing.expectEqualStrings("usync", node.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("us-1", node.getAttr("id").?);
    const usync = node.getChildByTag("usync") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sid-9", usync.getAttr("sid").?);
    try std.testing.expectEqualStrings("message", usync.getAttr("context").?);
    try std.testing.expectEqualStrings("query", usync.getAttr("mode").?);
    try std.testing.expectEqualStrings("true", usync.getAttr("last").?);
    try std.testing.expectEqualStrings("0", usync.getAttr("index").?);
    const query = usync.getChildByTag("query") orelse return error.TestUnexpectedResult;
    const devices = query.getChildByTag("devices") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", devices.getAttr("version").?);
    const list = usync.getChildByTag("list") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), list.children().len);
    try std.testing.expectEqualStrings("1234@s.whatsapp.net", list.children()[0].getAttr("jid").?);
}

test "parseUsyncDevices two users devices 0,5 and 0" {
    const alloc = std.testing.allocator;

    var dev_a: [2]binary.Node = .{
        binary.Node.init(alloc, "device"),
        binary.Node.init(alloc, "device"),
    };
    defer for (&dev_a) |*n| n.deinit();
    try dev_a[0].attrs.put("id", "0");
    try dev_a[1].attrs.put("id", "5");
    try dev_a[1].attrs.put("key-index", "3");

    var dlist_a = binary.Node.init(alloc, "device-list");
    defer dlist_a.deinit();
    dlist_a.content = .{ .nodes = &dev_a };
    var devices_a = binary.Node.init(alloc, "devices");
    defer devices_a.deinit();
    devices_a.content = .{ .nodes = (&dlist_a)[0..1] };
    var user_a = binary.Node.init(alloc, "user");
    defer user_a.deinit();
    try user_a.attrs.put("jid", "111@s.whatsapp.net");
    user_a.content = .{ .nodes = (&devices_a)[0..1] };

    var dev_b = binary.Node.init(alloc, "device");
    defer dev_b.deinit();
    try dev_b.attrs.put("id", "0");
    var dlist_b = binary.Node.init(alloc, "device-list");
    defer dlist_b.deinit();
    dlist_b.content = .{ .nodes = (&dev_b)[0..1] };
    var devices_b = binary.Node.init(alloc, "devices");
    defer devices_b.deinit();
    devices_b.content = .{ .nodes = (&dlist_b)[0..1] };
    var user_b = binary.Node.init(alloc, "user");
    defer user_b.deinit();
    try user_b.attrs.put("jid", "222@lid");
    user_b.content = .{ .nodes = (&devices_b)[0..1] };

    var users: [2]binary.Node = .{ user_a, user_b };
    var list = binary.Node.init(alloc, "list");
    defer list.deinit();
    list.content = .{ .nodes = &users };
    var usync = binary.Node.init(alloc, "usync");
    defer usync.deinit();
    usync.content = .{ .nodes = (&list)[0..1] };
    var iq = binary.Node.init(alloc, "iq");
    defer iq.deinit();
    iq.content = .{ .nodes = (&usync)[0..1] };

    const wire = try binary.marshal(alloc, iq);
    defer alloc.free(wire);
    var parsed = try binary.decodeNode(alloc, wire);
    defer parsed.deinit();
    const entries = try parseUsyncDevices(alloc, parsed);
    defer alloc.free(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", entries[0].user_jid);
    try std.testing.expectEqual(@as(u32, 0), entries[0].device);
    try std.testing.expectEqual(@as(u32, 0), entries[0].key_index);
    try std.testing.expectEqual(@as(u32, 5), entries[1].device);
    try std.testing.expectEqual(@as(u32, 3), entries[1].key_index);
    try std.testing.expectEqualStrings("222@lid", entries[2].user_jid);
    try std.testing.expectEqual(@as(u32, 0), entries[2].device);
}

test "encodeMessageMulti participants and device-identity" {
    const alloc = std.testing.allocator;
    const parts = [_]Participant{
        .{ .jid = "111:0@s.whatsapp.net", .enc_type = .pkmsg, .ciphertext = "aaa" },
        .{ .jid = "111:5@s.whatsapp.net", .enc_type = .msg, .ciphertext = "bbb" },
    };
    const ident = "dev-ident-bytes";
    const wire = try encodeMessageMulti(alloc, "111@s.whatsapp.net", "MID", &parts, ident, null);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("message", node.tag);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", node.getAttr("to").?);
    try std.testing.expectEqualStrings("MID", node.getAttr("id").?);
    try std.testing.expectEqualStrings("text", node.getAttr("type").?);
    const participants = node.getChildByTag("participants") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), participants.children().len);
    const to0 = participants.children()[0];
    try std.testing.expectEqualStrings("to", to0.tag);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", to0.getAttr("jid").?);
    const enc0 = to0.getChildByTag("enc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", enc0.getAttr("v").?);
    try std.testing.expectEqualStrings("pkmsg", enc0.getAttr("type").?);
    try std.testing.expectEqualStrings("aaa", enc0.contentBytes().?);
    const enc1 = participants.children()[1].getChildByTag("enc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("msg", enc1.getAttr("type").?);
    const di = node.getChildByTag("device-identity") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(ident, di.contentBytes().?);
    try std.testing.expect(node.getAttr("peer_recipient_pn") == null);
}

test "encodeMessageMulti lid dest sets peer_recipient_pn" {
    const alloc = std.testing.allocator;
    const parts = [_]Participant{
        .{ .jid = "216638251077681:0@lid", .enc_type = .msg, .ciphertext = "ct" },
    };
    const wire = try encodeMessageMulti(
        alloc,
        "216638251077681@lid",
        "MID2",
        &parts,
        null,
        "917019895010@s.whatsapp.net",
    );
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("216638251077681@lid", node.getAttr("to").?);
    try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", node.getAttr("peer_recipient_pn").?);
    try std.testing.expect(node.getChildByTag("device-identity") == null);
}

test "encodeRetryResend bare enc device_fanout false" {
    const alloc = std.testing.allocator;
    const wire = try encodeRetryResend(alloc, "216638251077681:56@lid", "MID3", .pkmsg, "ct", "ident-bytes");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("message", node.tag);
    try std.testing.expectEqualStrings("216638251077681:56@lid", node.getAttr("to").?);
    try std.testing.expectEqualStrings("MID3", node.getAttr("id").?);
    try std.testing.expectEqualStrings("false", node.getAttr("device_fanout").?);
    try std.testing.expect(node.getChildByTag("participants") == null);
    const enc = node.getChildByTag("enc") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkmsg", enc.getAttr("type").?);
    try std.testing.expectEqualStrings("ct", enc.contentBytes().?);
    const di = node.getChildByTag("device-identity") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ident-bytes", di.contentBytes().?);
}

test "encodeRetryResend omits device-identity when null" {
    const alloc = std.testing.allocator;
    const wire = try encodeRetryResend(alloc, "111@s.whatsapp.net", "MID4", .msg, "ct2", null);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expect(node.getChildByTag("device-identity") == null);
}

test "parseMessageInfo PN DM from peer" {
    const alloc = std.testing.allocator;
    var enc = binary.Node.init(alloc, "enc");
    defer enc.deinit();
    try enc.attrs.put("v", "2");
    try enc.attrs.put("type", "msg");
    enc.content = .{ .bytes = "ct" };
    var msg = binary.Node.init(alloc, "message");
    defer msg.deinit();
    try msg.attrs.put("from", "1234:5@s.whatsapp.net");
    try msg.attrs.put("id", "ABC");
    try msg.attrs.put("t", "1700000000");
    try msg.attrs.put("notify", "Peer");
    msg.content = .{ .nodes = (&enc)[0..1] };
    const info = try parseMessageInfo(alloc, msg, "999@s.whatsapp.net", null);
    defer alloc.free(info.encs);
    try std.testing.expectEqualStrings("ABC", info.id);
    try std.testing.expectEqualStrings("1234:5@s.whatsapp.net", info.chat);
    try std.testing.expectEqualStrings("1234:5@s.whatsapp.net", info.sender);
    try std.testing.expect(!info.from_me);
    try std.testing.expect(!info.is_group);
    try std.testing.expectEqual(@as(i64, 1700000000), info.timestamp);
    try std.testing.expectEqualStrings("Peer", info.push_name.?);
    try std.testing.expectEqual(@as(usize, 1), info.encs.len);
    try std.testing.expectEqual(EncType.msg, info.encs[0].enc_type);
}

test "parseMessageInfo LID DM from own LID" {
    const alloc = std.testing.allocator;
    var enc = binary.Node.init(alloc, "enc");
    defer enc.deinit();
    try enc.attrs.put("v", "2");
    try enc.attrs.put("type", "pkmsg");
    enc.content = .{ .bytes = "ct" };
    var msg = binary.Node.init(alloc, "message");
    defer msg.deinit();
    try msg.attrs.put("from", "216638251077681:55@lid");
    try msg.attrs.put("recipient", "111@s.whatsapp.net");
    try msg.attrs.put("sender_pn", "917019895010:55@s.whatsapp.net");
    try msg.attrs.put("id", "OWN");
    try msg.attrs.put("t", "1");
    msg.content = .{ .nodes = (&enc)[0..1] };
    const info = try parseMessageInfo(alloc, msg, "917019895010:55@s.whatsapp.net", "216638251077681@lid");
    defer alloc.free(info.encs);
    try std.testing.expect(info.from_me);
    try std.testing.expect(!info.is_group);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", info.chat);
    try std.testing.expectEqualStrings("216638251077681:55@lid", info.sender);
    try std.testing.expectEqualStrings("917019895010:55@s.whatsapp.net", info.sender_alt.?);
}

test "parseMessageInfo group with participant" {
    const alloc = std.testing.allocator;
    var enc = binary.Node.init(alloc, "enc");
    defer enc.deinit();
    try enc.attrs.put("v", "2");
    try enc.attrs.put("type", "skmsg");
    enc.content = .{ .bytes = "gct" };
    var msg = binary.Node.init(alloc, "message");
    defer msg.deinit();
    try msg.attrs.put("from", "12036342@g.us");
    try msg.attrs.put("participant", "1234:5@s.whatsapp.net");
    try msg.attrs.put("participant_lid", "2166@lid");
    try msg.attrs.put("id", "G1");
    try msg.attrs.put("t", "9");
    msg.content = .{ .nodes = (&enc)[0..1] };
    const info = try parseMessageInfo(alloc, msg, "999@s.whatsapp.net", null);
    defer alloc.free(info.encs);
    try std.testing.expect(info.is_group);
    try std.testing.expect(!info.from_me);
    try std.testing.expectEqualStrings("12036342@g.us", info.chat);
    try std.testing.expectEqualStrings("1234:5@s.whatsapp.net", info.sender);
    try std.testing.expectEqualStrings("1234:5@s.whatsapp.net", info.participant.?);
    try std.testing.expectEqualStrings("2166@lid", info.sender_alt.?);
    try std.testing.expectEqual(EncType.skmsg, info.encs[0].enc_type);
}

test "parseMessageInfo two enc children" {
    const alloc = std.testing.allocator;
    var encs: [2]binary.Node = .{
        binary.Node.init(alloc, "enc"),
        binary.Node.init(alloc, "enc"),
    };
    defer for (&encs) |*n| n.deinit();
    try encs[0].attrs.put("v", "2");
    try encs[0].attrs.put("type", "pkmsg");
    encs[0].content = .{ .bytes = "one" };
    try encs[1].attrs.put("v", "2");
    try encs[1].attrs.put("type", "msg");
    encs[1].content = .{ .bytes = "two" };
    var msg = binary.Node.init(alloc, "message");
    defer msg.deinit();
    try msg.attrs.put("from", "1234@s.whatsapp.net");
    try msg.attrs.put("id", "TWO");
    msg.content = .{ .nodes = &encs };
    const info = try parseMessageInfo(alloc, msg, null, null);
    defer alloc.free(info.encs);
    try std.testing.expectEqual(@as(usize, 2), info.encs.len);
    try std.testing.expectEqual(EncType.pkmsg, info.encs[0].enc_type);
    try std.testing.expectEqualStrings("one", info.encs[0].ciphertext);
    try std.testing.expectEqual(EncType.msg, info.encs[1].enc_type);
    try std.testing.expectEqualStrings("two", info.encs[1].ciphertext);
    try std.testing.expectEqualStrings("TWO", info.encs[0].id);
}

test "parseStreamErrorCode isServerPing parseOfflineCount parseNotificationType" {
    const alloc = std.testing.allocator;
    var errn = binary.Node.init(alloc, "stream:error");
    defer errn.deinit();
    try errn.attrs.put("code", "515");
    try std.testing.expectEqual(@as(u32, 515), parseStreamErrorCode(errn));
    var empty = binary.Node.init(alloc, "stream:error");
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, 0), parseStreamErrorCode(empty));

    var ping = binary.Node.init(alloc, "iq");
    defer ping.deinit();
    try ping.attrs.put("type", "get");
    try ping.attrs.put("xmlns", "urn:xmpp:ping");
    try std.testing.expect(isServerPing(ping));
    try ping.attrs.put("xmlns", "w:p");
    try std.testing.expect(!isServerPing(ping));

    var offline = binary.Node.init(alloc, "offline");
    defer offline.deinit();
    try offline.attrs.put("count", "12");
    var ib = binary.Node.init(alloc, "ib");
    defer ib.deinit();
    ib.content = .{ .nodes = (&offline)[0..1] };
    try std.testing.expectEqual(@as(u32, 12), parseOfflineCount(ib).?);

    var n = binary.Node.init(alloc, "notification");
    defer n.deinit();
    try n.attrs.put("type", "encrypt");
    try std.testing.expectEqualStrings("encrypt", parseNotificationType(n).?);
}

test "encodeRetryReceipt without keys" {
    const alloc = std.testing.allocator;
    const wire = try encodeRetryReceipt(alloc, "1234@s.whatsapp.net", "MID", "p@s.whatsapp.net", "1700000000", 1, 0x01020304, null);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("receipt", node.tag);
    try std.testing.expectEqualStrings("1234@s.whatsapp.net", node.getAttr("to").?);
    try std.testing.expectEqualStrings("MID", node.getAttr("id").?);
    try std.testing.expectEqualStrings("retry", node.getAttr("type").?);
    try std.testing.expectEqualStrings("p@s.whatsapp.net", node.getAttr("participant").?);
    try std.testing.expect(node.getChildByTag("keys") == null);
    const retry = node.getChildByTag("retry") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", retry.getAttr("count").?);
    try std.testing.expectEqualStrings("MID", retry.getAttr("id").?);
    try std.testing.expectEqualStrings("1700000000", retry.getAttr("t").?);
    try std.testing.expectEqualStrings("1", retry.getAttr("v").?);
    const reg = node.getChildByTag("registration") orelse return error.TestUnexpectedResult;
    const reg_b = reg.contentBytes() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), reg_b.len);
    try std.testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, reg_b[0..4], .big));
}

test "encodeRetryReceipt with keys" {
    const alloc = std.testing.allocator;
    const ident = [_]u8{0x11} ** 32;
    const ot_pub = [_]u8{0x22} ** 32;
    const spk = [_]u8{0x33} ** 32;
    const sig = [_]u8{0x44} ** 64;
    const di = "dev-ident";
    const keys = RetryKeys{
        .identity_pub = ident,
        .one_time = .{ .id = 7, .pub_key = ot_pub },
        .signed_id = 0x0000aabb,
        .signed_pub = spk,
        .signed_sig = sig,
        .device_identity = di,
    };
    const wire = try encodeRetryReceipt(alloc, "1234@s.whatsapp.net", "MID", null, "9", 2, 0x0a0b0c0d, keys);
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("receipt", node.tag);
    try std.testing.expectEqualStrings("1234@s.whatsapp.net", node.getAttr("to").?);
    try std.testing.expectEqualStrings("MID", node.getAttr("id").?);
    try std.testing.expectEqualStrings("retry", node.getAttr("type").?);
    try std.testing.expect(node.getAttr("participant") == null);
    const retry = node.getChildByTag("retry") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", retry.getAttr("count").?);
    try std.testing.expectEqualStrings("MID", retry.getAttr("id").?);
    try std.testing.expectEqualStrings("9", retry.getAttr("t").?);
    try std.testing.expectEqualStrings("1", retry.getAttr("v").?);
    const reg = node.getChildByTag("registration") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x0a0b0c0d), std.mem.readInt(u32, (reg.contentBytes().?)[0..4], .big));
    const kn = node.getChildByTag("keys") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &[_]u8{0x05}, kn.getChildByTag("type").?.contentBytes().?);
    try std.testing.expectEqualSlices(u8, &ident, kn.getChildByTag("identity").?.contentBytes().?);
    const key = kn.getChildByTag("key") orelse return error.TestUnexpectedResult;
    const kid = key.getChildByTag("id").?.contentBytes().?;
    try std.testing.expectEqual(@as(usize, 3), kid.len);
    try std.testing.expectEqual(@as(u8, 0), kid[0]);
    try std.testing.expectEqual(@as(u8, 0), kid[1]);
    try std.testing.expectEqual(@as(u8, 7), kid[2]);
    try std.testing.expectEqualSlices(u8, &ot_pub, key.getChildByTag("value").?.contentBytes().?);
    const skey = kn.getChildByTag("skey") orelse return error.TestUnexpectedResult;
    const sid = skey.getChildByTag("id").?.contentBytes().?;
    try std.testing.expectEqual(@as(usize, 3), sid.len);
    try std.testing.expectEqual(@as(u8, 0x00), sid[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), sid[1]);
    try std.testing.expectEqual(@as(u8, 0xbb), sid[2]);
    try std.testing.expectEqualSlices(u8, &spk, skey.getChildByTag("value").?.contentBytes().?);
    try std.testing.expectEqualSlices(u8, &sig, skey.getChildByTag("signature").?.contentBytes().?);
    try std.testing.expectEqualStrings(di, kn.getChildByTag("device-identity").?.contentBytes().?);
}

test "encodeMediaConnIq and parseMediaConn" {
    const alloc = std.testing.allocator;
    const wire = try encodeMediaConnIq(alloc, "mc-1");
    defer alloc.free(wire);
    var node = try binary.decodeNode(alloc, wire);
    defer node.deinit();
    try std.testing.expectEqualStrings("iq", node.tag);
    try std.testing.expectEqualStrings("w:m", node.getAttr("xmlns").?);
    try std.testing.expectEqualStrings("set", node.getAttr("type").?);
    try std.testing.expect(node.getChildByTag("media_conn") != null);

    var result = binary.Node.init(alloc, "iq");
    defer result.deinit();
    var mc = binary.Node.init(alloc, "media_conn");
    defer mc.deinit();
    try mc.attrs.put("auth", "AUTHTOKEN");
    try mc.attrs.put("ttl", "600");
    var host = binary.Node.init(alloc, "host");
    defer host.deinit();
    try host.attrs.put("hostname", "mmg.whatsapp.net");
    mc.content = .{ .nodes = (&host)[0..1] };
    result.content = .{ .nodes = (&mc)[0..1] };
    const parsed = try parseMediaConn(result);
    try std.testing.expectEqualStrings("AUTHTOKEN", parsed.auth);
    try std.testing.expectEqualStrings("mmg.whatsapp.net", parsed.hostname);
    try std.testing.expectEqual(@as(u32, 600), parsed.ttl);
}
