const std = @import("std");
const binary = @import("binary.zig");
const jid = @import("jid.zig");
const stanza = @import("stanza.zig");

/// Group stanzas: metadata IQ (whatsmeow wm2_group.go) and the group message node
/// (whatsmeow wm2_send.go `sendGroup` + `prepareMessageNode` + `participantListHashV2`).
/// Pure `binary.Node` functions — Signal sender-key crypto lives in signal_groups.zig,
/// so nothing here touches sessions, sender keys, or the wire.
///
/// Memory: every builder returns an OWNED node tree (`node.owned == true`, tags /
/// attr keys+values / byte content duped, child slices allocated); one
/// `node.deinit()` frees the whole tree (same shape `binary.decodeNode` returns).

// ---------------------------------------------------------------- owned helpers

fn newNode(allocator: std.mem.Allocator, tag: []const u8) !binary.Node {
    return .{
        .tag = try allocator.dupe(u8, tag),
        .attrs = std.StringHashMap([]const u8).init(allocator),
        .owned = true,
    };
}

/// `key` must not already be present on `node` (a put over an existing key would
/// leak the previous pair). Both strings are duped; freed by `Node.deinit`.
fn setAttr(node: *binary.Node, key: []const u8, value: []const u8) !void {
    const a = node.attrs.allocator;
    try node.attrs.ensureUnusedCapacity(1);
    const k = try a.dupe(u8, key);
    errdefer a.free(k);
    const v = try a.dupe(u8, value);
    node.attrs.putAssumeCapacity(k, v);
}

/// Like `setAttr`, but `value` is already allocator-owned and is moved in. `value` is
/// released again if the pair cannot be stored.
fn setAttrOwned(node: *binary.Node, key: []const u8, value: []u8) !void {
    const a = node.attrs.allocator;
    try node.attrs.ensureUnusedCapacity(1);
    const k = a.dupe(u8, key) catch |err| {
        a.free(value);
        return err;
    };
    node.attrs.putAssumeCapacity(k, value);
}

fn setBytes(node: *binary.Node, bytes: []const u8) !void {
    // Duped into a local first: writing `.{ .bytes = try ... }` straight into
    // `node.content` leaves a poisoned `.bytes` tag behind on OutOfMemory, and the
    // caller's `errdefer deinit()` would then free it.
    const duped = try node.attrs.allocator.dupe(u8, bytes);
    node.content = .{ .bytes = duped };
}

/// Give `node` an owned copy of `kids` (moved nodes must not be deinited twice).
fn setNodes(node: *binary.Node, kids: []const binary.Node) !void {
    const a = node.attrs.allocator;
    const dst = try a.alloc(binary.Node, kids.len);
    @memcpy(dst, kids);
    node.content = .{ .nodes = dst };
}

// ---------------------------------------------------------------- group info IQ

/// whatsmeow `getGroupInfo` (wm2_group.go:658) → `sendGroupIQ(iqGet, jid,
/// <query request="interactive">)`; xmlns goes on the `<iq>` (wm_request.go:119),
/// not on the `<query>`. WhatsApp web `groupMetadata` (Socket/groups.js:18) is identical.
/// Neither adds a `notify` attr — `notify` is the inbound sender push name only.
/// `id` may be bare (no `@`), in which case `@g.us` is appended (WhatsApp web
/// `extractGroupMetadata` tolerates the same asymmetry on the way back).
/// Memory: caller owns the node; `deinit` frees it.
pub fn buildGroupInfoQuery(allocator: std.mem.Allocator, id: []const u8, iq_id: []const u8) !binary.Node {
    var iq = try newNode(allocator, "iq");
    errdefer iq.deinit();
    try setAttr(&iq, "id", iq_id);
    try setAttr(&iq, "type", "get");
    try setAttr(&iq, "xmlns", "w:g2");
    try setAttrOwned(&iq, "to", try groupJidString(allocator, id));

    var query = try newNode(allocator, "query");
    errdefer query.deinit();
    try setAttr(&query, "request", "interactive");
    // Last fallible call in this builder: on failure both errdefers above stay
    // correct, on success `iq` owns the copied child and nothing else can fail.
    try setNodes(&iq, &.{query});
    return iq;
}

fn groupJidString(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, id, '@') != null) return allocator.dupe(u8, id);
    return std.fmt.allocPrint(allocator, "{s}@g.us", .{id});
}

// ---------------------------------------------------------------- group info parse

/// One `<participant>` of a `<group>`/`<query>` element. `jid` is the wire attr
/// verbatim; `lid` follows WhatsApp web (groups.js:316): when `jid` is itself a lid it is
/// mirrored there, otherwise it carries the separate `lid` attr. Admin mirrors
/// whatsmeow `parseParticipant` (wm2_group.go:704): `superadmin` implies admin.
pub const Participant = struct {
    jid: []const u8,
    lid: ?[]const u8,
    admin: bool,
    super_admin: bool,
};

/// Group metadata as reported by `w:g2`. Every string is an allocator-owned dupe.
pub const GroupInfo = struct {
    id: []const u8 = "",
    subject: []const u8 = "",
    subject_owner: []const u8 = "",
    subject_time: i64 = 0,
    creation: i64 = 0,
    addressing_mode: []const u8 = "",
    /// `<locked/>` child or `locked="true"` attr (WhatsApp web `restrict`).
    locked: bool = false,
    participants: []Participant = &.{},

    /// Memory: frees every dupe owned by `self`; safe to call once.
    pub fn deinit(self: *GroupInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.subject);
        allocator.free(self.subject_owner);
        allocator.free(self.addressing_mode);
        for (self.participants) |*p| {
            allocator.free(p.jid);
            if (p.lid) |l| allocator.free(l);
        }
        allocator.free(self.participants);
        self.* = .{};
    }
};

fn firstAttr(node: binary.Node, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (node.getAttr(k)) |v| return v;
    }
    return null;
}

fn attrInt(node: binary.Node, keys: []const []const u8) i64 {
    const v = firstAttr(node, keys) orelse return 0;
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

fn hasTag(node: binary.Node, tag: []const u8) bool {
    for (node.children()) |child| {
        if (std.mem.eql(u8, child.tag, tag)) return true;
    }
    return false;
}

fn findTag(node: binary.Node, tag: []const u8) ?binary.Node {
    for (node.children()) |child| {
        if (std.mem.eql(u8, child.tag, tag)) return child;
    }
    return null;
}

/// Depth-first search for the first element with `tag` (response payloads are
/// `<iq><group>` today, `<iq><query><group>` for older `w:gp2` stanzas, and
/// `<iq><groups><group>` for `groupFetchAllParticipating`).
fn findTagDeep(node: binary.Node, tag: []const u8) ?binary.Node {
    for (node.children()) |child| {
        if (std.mem.eql(u8, child.tag, tag)) return child;
        if (findTagDeep(child, tag)) |deep| return deep;
    }
    return null;
}

/// Parse a group-info IQ result (or a bare `<group>` / `<query>` element). Handles
/// both attribute spellings: current `w:g2` (`s_o`/`s_t`, whatsmeow wm2_group.go:741)
/// and the legacy `subject-owner`/`subject-time` pair used by `w:gp2` stanzas.
/// Memory: caller owns the result; `GroupInfo.deinit` frees it.
pub fn parseGroupInfo(allocator: std.mem.Allocator, iq_result: binary.Node) !GroupInfo {
    const group = findTagDeep(iq_result, "group") orelse
        findTagDeep(iq_result, "query") orelse
        (if (std.mem.eql(u8, iq_result.tag, "group") or std.mem.eql(u8, iq_result.tag, "query")) iq_result else null);
    const src = group orelse return error.MissingGroupElement;

    // Field-by-field errdefers: `GroupInfo.deinit` frees every slice, so it must not
    // run while fields still hold their `""` defaults (static, not allocated).
    var info: GroupInfo = .{};
    info.id = try groupJidString(allocator, firstAttr(src, &.{"id"}) orelse
        firstAttr(iq_result, &.{"from"}) orelse "");
    errdefer allocator.free(info.id);
    info.subject = try allocator.dupe(u8, firstAttr(src, &.{"subject"}) orelse "");
    errdefer allocator.free(info.subject);
    info.subject_owner = try allocator.dupe(u8, firstAttr(src, &.{ "s_o", "subject-owner" }) orelse "");
    errdefer allocator.free(info.subject_owner);
    info.addressing_mode = try allocator.dupe(u8, firstAttr(src, &.{"addressing_mode"}) orelse "");
    errdefer allocator.free(info.addressing_mode);
    info.subject_time = attrInt(src, &.{ "s_t", "subject-time" });
    info.creation = attrInt(src, &.{"creation"});
    info.locked = hasTag(src, "locked") or isTrueAttr(firstAttr(src, &.{"locked"}));

    var list: std.ArrayList(Participant) = .empty;
    errdefer {
        for (list.items) |*p| {
            allocator.free(p.jid);
            if (p.lid) |l| allocator.free(l);
        }
        list.deinit(allocator);
    }
    for (src.children()) |child| {
        if (!std.mem.eql(u8, child.tag, "participant")) continue;
        const raw = child.getAttr("jid") orelse continue;
        if (raw.len == 0) continue;
        const kind = child.getAttr("type") orelse "";
        var p: Participant = .{
            .jid = try allocator.dupe(u8, raw),
            .lid = null,
            .admin = std.mem.eql(u8, kind, "admin") or std.mem.eql(u8, kind, "superadmin"),
            .super_admin = std.mem.eql(u8, kind, "superadmin"),
        };
        errdefer allocator.free(p.jid);
        if (jid.isLid(raw)) {
            p.lid = try allocator.dupe(u8, raw);
        } else if (child.getAttr("lid")) |l| {
            if (l.len > 0) p.lid = try allocator.dupe(u8, l);
        }
        errdefer if (p.lid) |l| allocator.free(l);
        try list.append(allocator, p);
    }
    info.participants = try list.toOwnedSlice(allocator);
    return info;
}

fn isTrueAttr(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1");
}

// ---------------------------------------------------------------- phash

/// Port of whatsmeow `types.JID.ADString()` (types/jid.go:211) applied to a wire JID
/// string: `fmt.Sprintf("%s.%d:%d@%s", User, RawAgent, Device, Server)`. Unlike
/// `JID.String()`, the `.agent:device` suffix is NEVER omitted, so a plain
/// `15551234@s.whatsapp.net` hashes as `15551234.0:0@s.whatsapp.net` and a bare
/// `216638251077681@lid` hashes as `216638251077681.0:0@lid`.
/// Fields are split by a faithful port of `types.ParseJID` (jid.go:159):
///   `user@server`               -> raw_agent 0, device 0
///   `user:device@server`        -> raw_agent 0, device N (the colon form IS the device)
///   `user.agent:device@server`  -> raw_agent A, device D (dot form = agent, then device)
///   `user.agent@server`         -> raw_agent A, device 0
///   `server` (no `@`)           -> user "", server "server"
///   `a@b@c@server`              -> server stops at the second `@` (Go splits on `@`
///                                  and only ever reads parts[0]/parts[1])
/// One deliberate deviation: Go returns `(partial JID, error)` for malformed input;
/// this keeps exactly that partially-filled JID (what Go hands back next to the error)
/// and formats it, so a phash can always be produced rather than failing the send.
/// Memory: caller frees.
pub fn adString(allocator: std.mem.Allocator, jid_str: []const u8) ![]u8 {
    const parsed = parseAdJid(jid_str);
    return std.fmt.allocPrint(allocator, "{s}.{d}:{d}@{s}", .{
        parsed.user, parsed.raw_agent, parsed.device, parsed.server,
    });
}

const AdJid = struct {
    user: []const u8 = "",
    raw_agent: u8 = 0,
    device: u16 = 0,
    server: []const u8 = "",
};

fn countChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1;
    }
    return n;
}

fn parseIntOr(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

fn parseAdJid(s: []const u8) AdJid {
    var out: AdJid = .{};
    const at = std.mem.indexOfScalar(u8, s, '@') orelse {
        // Go: no `@` → NewJID("", s): the whole string is the server.
        out.server = s;
        return out;
    };
    const user = s[0..at];
    out.server = s[at + 1 ..];
    if (std.mem.indexOfScalar(u8, out.server, '@')) |second| out.server = out.server[0..second];

    if (std.mem.indexOfScalar(u8, user, '.')) |dot| {
        if (countChar(user, '.') != 1) {
            out.user = user; // Go errors before touching User: dots stay
            return out;
        }
        const head = user[0..dot];
        const ad = user[dot + 1 ..];
        out.user = head;
        if (countChar(ad, ':') > 1) return out; // Go: "unexpected number of colons"
        const agent_s: []const u8 = if (std.mem.indexOfScalar(u8, ad, ':')) |colon| ad[0..colon] else ad;
        const dev_s: ?[]const u8 = if (std.mem.indexOfScalar(u8, ad, ':')) |colon| ad[colon + 1 ..] else null;
        // Go parses (and truncates to uint8) the agent BEFORE the device: a bad agent
        // leaves both 0, a bad device leaves the agent set and the device 0.
        const agent = parseIntOr(i64, agent_s) orelse return out;
        out.raw_agent = @intCast(agent & 0xFF); // Go's uint8(agent) wrap
        if (dev_s) |dev| {
            if (parseIntOr(u16, dev)) |d| out.device = d;
        }
        return out;
    }
    if (std.mem.indexOfScalar(u8, user, ':')) |colon| {
        if (countChar(user, ':') != 1) {
            out.user = user; // Go errors before touching User
            return out;
        }
        out.user = user[0..colon];
        if (parseIntOr(u16, user[colon + 1 ..])) |d| out.device = d;
        return out;
    }
    out.user = user;
    return out;
}

fn lessJidStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Exact port of whatsmeow `participantListHashV2` (wm2_send.go:682):
/// `ADString()` every participant device JID, sort bytewise, sha256 the concatenation
/// (no separator), then `"2:" ++ base64.RawStdEncoding(hash[:6])` — 8 unpadded chars.
/// Used as the `phash` attr of outbound `<message>` nodes (DM and group alike); the
/// caller's list is whatsmeow's `allDevices`, i.e. it INCLUDES your own devices.
/// Memory: caller frees the returned slice.
pub fn participantListHashV2(allocator: std.mem.Allocator, device_jids: []const []const u8) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    for (device_jids) |j| {
        const ad = try adString(allocator, j);
        errdefer allocator.free(ad);
        try names.append(allocator, ad);
    }
    std.mem.sort([]const u8, names.items, {}, lessJidStr);

    // `strings.Join(participantsStrings, "")` fed straight into sha256: streaming the
    // sorted pieces avoids building the concatenation at all.
    var ctx = std.crypto.hash.sha2.Sha256.init(.{});
    for (names.items) |n| ctx.update(n);
    var digest: [32]u8 = undefined;
    ctx.final(&digest);

    const b64 = std.base64.standard_no_pad.Encoder;
    const out = try allocator.alloc(u8, 2 + b64.calcSize(6));
    errdefer allocator.free(out);
    out[0] = '2';
    out[1] = ':';
    _ = b64.encode(out[2..], digest[0..6]);

    for (names.items) |n| allocator.free(n);
    names.deinit(allocator);
    return out;
}

// ---------------------------------------------------------------- group message node

pub const GroupMessageOpts = struct {
    /// Message id (`attrs.id`).
    id: []const u8,
    /// Group JID, e.g. `120363421845733873@g.us`. Sent verbatim as `attrs.to` —
    /// neither whatsmeow (wm2_send.go:1195) nor WhatsApp web rewrites the group JID for
    /// lid-addressed groups; only the participant JIDs and `addressing_mode` change.
    to_group: []const u8,
    /// Your own device JID. Targets equal to this (or `own_lid`) are dropped from the
    /// `<participants>` fanout, mirroring whatsmeow's
    /// `if jid == ownJID || jid == ownLID { continue }` (wm2_send.go:1298,1329).
    own_jid: []const u8,
    own_lid: ?[]const u8 = null,
    /// `"lid"` for lid-addressed groups (whatsmeow sets it there only), `"pn"` for
    /// WhatsApp-web-parity, `""` to omit the attr entirely.
    addressing_mode: []const u8 = "",
    /// whatsmeow `allDevices` — the phash input, own devices included.
    participants_device_jids: []const []const u8 = &.{},
    /// `<enc v="2" type="skmsg">` body: the SenderKeyMessage `SignedSerialize()`.
    skmsg_ciphertext: []const u8,
    /// whatsmeow `getMediaTypeFromMessage` value (`image`, `video`, `ptt`, ...);
    /// `mediatype` is added to the skmsg `<enc>` only — per-device `<enc>` nodes get no
    /// mediatype in groups because `dsmPlaintext` is nil there (wm2_send.go:1189).
    media_type: ?[]const u8 = null,
    /// `attrs.type`; null derives whatsmeow's `getTypeFromMessage`: `"media"` when a
    /// media_type is present, else `"text"`.
    msg_type: ?[]const u8 = null,
    /// whatsmeow `edit` attr: `"1"` message edit, `"7"` sender revoke. Omitted if null.
    edit: ?[]const u8 = null,
    /// SKDM wrapper plaintext (`proto.Message.encodeSenderKeyDistribution`). A target
    /// with an empty `ciphertext` falls back to these bytes verbatim, which lets
    /// callers that pre-encrypt elsewhere (or tests) reuse one payload.
    skdm_payload: []const u8 = "",
    /// Per-device SKDM fanout: `jid` = wire device JID of the `<to>` attr,
    /// `enc_type` = `pkmsg` (new session) or `msg` (existing session),
    /// `ciphertext` = that device's Signal ciphertext of `skdm_payload`.
    skdm_targets: []const stanza.Participant = &.{},
    /// Optional `<device-identity>` body (protobuf `Account`); whatsmeow adds it when
    /// any target needed a prekey message. Caller decides, like `encodeMessageMulti`.
    device_identity: ?[]const u8 = null,
    /// Optional `t` attr. Neither oracle sends `t` outbound (the server stamps it on
    /// the echo), so this stays null unless you specifically want it.
    timestamp: ?i64 = null,
    /// Optional `notify` attr (sender push name). whatsmeow and WhatsApp web never set it
    /// on outbound messages — the server echoes the name it knows — so null is default.
    push_name: ?[]const u8 = null,
};

fn sameDeviceJid(candidate: []const u8, own: ?[]const u8) bool {
    const o = own orelse return false;
    if (candidate.len == 0 or o.len == 0) return false;
    return std.mem.eql(u8, jid.user(candidate), jid.user(o)) and
        jid.device(candidate) == jid.device(o) and
        std.mem.eql(u8, jid.server(candidate), jid.server(o));
}

/// One `<to jid="device"><enc v="2" type="pkmsg|msg">payload</enc></to>` entry of the
/// SKDM fanout (whatsmeow `encryptMessageForDeviceAndWrap`, wm2_send.go:1374). The
/// `enc` move is the helper's last fallible statement, so its `errdefer` can never
/// fire on the copy `to` owns.
fn skdmTargetNode(
    allocator: std.mem.Allocator,
    device_jid: []const u8,
    enc_type: stanza.EncType,
    payload: []const u8,
) !binary.Node {
    var enc = try newNode(allocator, "enc");
    errdefer enc.deinit();
    try setAttr(&enc, "v", "2");
    try setAttr(&enc, "type", enc_type.attr());
    try setBytes(&enc, payload);

    var to = try newNode(allocator, "to");
    errdefer to.deinit();
    try setAttr(&to, "jid", device_jid);
    try setNodes(&to, &.{enc});
    return to;
}

/// Assemble the exact whatsmeow `sendGroup` stanza:
/// `<message id to type [addressing_mode] [t] [notify] phash>` with children
/// `<participants><to jid><enc v="2" type="pkmsg|msg">skdm-ct</enc></to>…</participants>`,
/// optional `<device-identity>`, then the appended
/// `<enc v="2" type="skmsg" [mediatype]>ciphertext</enc>` (wm2_send.go:806-814).
/// Memory: caller owns the returned node; one `deinit()` frees the tree.
pub fn buildGroupMessageNode(allocator: std.mem.Allocator, opts: GroupMessageOpts) !binary.Node {
    // Ownership chain: every node below keeps an `errdefer` deinit until the final
    // (infallible) assembly, so any allocation failure frees exactly what it owns.
    const phash = try participantListHashV2(allocator, opts.participants_device_jids);
    defer allocator.free(phash);

    var tos: std.ArrayList(binary.Node) = .empty;
    errdefer {
        for (tos.items) |*n| n.deinit();
        tos.deinit(allocator);
    }
    for (opts.skdm_targets) |t| {
        // whatsmeow `encryptMessageForDevices`: your own devices never get an SKDM.
        if (sameDeviceJid(t.jid, opts.own_jid) or sameDeviceJid(t.jid, opts.own_lid)) continue;
        const payload = if (t.ciphertext.len > 0) t.ciphertext else opts.skdm_payload;

        var to = try skdmTargetNode(allocator, t.jid, t.enc_type, payload);
        // Only `tos.append` stays fallible: on failure this errdefer releases `to`
        // with its `enc` child, and the helper's own cleanup has already unwound.
        errdefer to.deinit();
        try tos.append(allocator, to);
    }

    var participants = try newNode(allocator, "participants");
    errdefer participants.deinit();
    if (tos.items.len > 0) {
        // Same reason as `setBytes`: never write a half-built union into content.
        const moved = try tos.toOwnedSlice(allocator);
        participants.content = .{ .nodes = moved };
    }

    var skmsg = try newNode(allocator, "enc");
    errdefer skmsg.deinit();
    try setAttr(&skmsg, "v", "2");
    try setAttr(&skmsg, "type", stanza.EncType.skmsg.attr());
    if (opts.media_type) |mt| {
        if (mt.len > 0) try setAttr(&skmsg, "mediatype", mt);
    }
    try setBytes(&skmsg, opts.skmsg_ciphertext);

    var ident: binary.Node = undefined;
    var have_ident = false;
    // Checked at unwind time: covers an error after the block below but before the
    // final move into `kids` (nothing can fail once the moves start).
    errdefer if (have_ident) ident.deinit();
    if (opts.device_identity) |di| {
        ident = try newNode(allocator, "device-identity");
        errdefer ident.deinit();
        try setBytes(&ident, di);
        have_ident = true;
    }

    var msg = try newNode(allocator, "message");
    errdefer msg.deinit();
    try setAttr(&msg, "id", opts.id);
    try setAttr(&msg, "to", opts.to_group);
    const msg_type = opts.msg_type orelse
        if (opts.media_type) |mt| (if (mt.len > 0) "media" else "text") else "text";
    try setAttr(&msg, "type", msg_type);
    if (opts.addressing_mode.len > 0) try setAttr(&msg, "addressing_mode", opts.addressing_mode);
    if (opts.timestamp) |ts| {
        const ts_s = try std.fmt.allocPrint(allocator, "{d}", .{ts});
        defer allocator.free(ts_s);
        try setAttr(&msg, "t", ts_s);
    }
    if (opts.push_name) |pn| {
        if (pn.len > 0) try setAttr(&msg, "notify", pn);
    }
    if (opts.edit) |e| {
        if (e.len > 0) try setAttr(&msg, "edit", e);
    }
    try setAttr(&msg, "phash", phash);

    // Last fallible call. After this point only moves happen, so the errdefers
    // above can never fire on top of the copies `msg` is about to own.
    const kids = try allocator.alloc(binary.Node, if (have_ident) 3 else 2);
    kids[0] = participants;
    if (have_ident) {
        kids[1] = ident;
        kids[2] = skmsg;
    } else {
        kids[1] = skmsg;
    }
    msg.content = .{ .nodes = kids };
    return msg;
}

// ---------------------------------------------------------------- tests

fn expectAttr(node: binary.Node, key: []const u8, want: []const u8) !void {
    const got = node.getAttr(key) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(want, got);
}

fn childByTag(node: binary.Node, tag: []const u8) !binary.Node {
    return findTag(node, tag) orelse return error.TestUnexpectedResult;
}

test "adString ports whatsmeow ADString" {
    const a = std.testing.allocator;
    const Case = struct { jid: []const u8, want: []const u8 };
    const cases = [_]Case{
        // Plain user: agent and device are both 0, yet the suffix is still printed.
        .{ .jid = "15551234@s.whatsapp.net", .want = "15551234.0:0@s.whatsapp.net" },
        // Colon form is the DEVICE (JID.String would print `user:dev@...`).
        .{ .jid = "15551234:55@s.whatsapp.net", .want = "15551234.0:55@s.whatsapp.net" },
        // Dot form carries agent AND device.
        .{ .jid = "15551234.1:55@s.whatsapp.net", .want = "15551234.1:55@s.whatsapp.net" },
        // `agent:` with an empty device keeps the agent and zeroes the device.
        .{ .jid = "15551234.2:@s.whatsapp.net", .want = "15551234.2:0@s.whatsapp.net" },
        // LID device / bare LID.
        .{ .jid = "216638251077681:55@lid", .want = "216638251077681.0:55@lid" },
        .{ .jid = "216638251077681@lid", .want = "216638251077681.0:0@lid" },
        // Group + hosted servers.
        .{ .jid = "120363421845733873@g.us", .want = "120363421845733873.0:0@g.us" },
        .{ .jid = "15551234:11@hosted.lid", .want = "15551234.0:11@hosted.lid" },
        // No `@` at all: ParseJID puts the whole string in Server, User stays empty.
        .{ .jid = "g.us", .want = ".0:0@g.us" },
        // Malformed forms: the partially-parsed value Go returns with its error.
        .{ .jid = "15551234.x:5@s.whatsapp.net", .want = "15551234.0:0@s.whatsapp.net" },
        .{ .jid = "15551234:5:6@s.whatsapp.net", .want = "15551234:5:6.0:0@s.whatsapp.net" },
        .{ .jid = "15551234:a:b@s.whatsapp.net", .want = "15551234:a:b.0:0@s.whatsapp.net" },
        .{ .jid = "15551234.a.b@s.whatsapp.net", .want = "15551234.a.b.0:0@s.whatsapp.net" },
        // uint8 truncation of an oversized agent, like Go's uint8(agent).
        .{ .jid = "15551234.300:5@s.whatsapp.net", .want = "15551234.44:5@s.whatsapp.net" },
        // Extra `@`: Go only ever reads parts[0] and parts[1].
        .{ .jid = "15551234@lid@x", .want = "15551234.0:0@lid" },
    };
    for (cases) |c| {
        const got = try adString(a, c.jid);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "participantListHashV2 matches an independent sha256" {
    const a = std.testing.allocator;
    const devices = [_][]const u8{
        "216638251077681:55@lid",
        "15551234@s.whatsapp.net",
        "917019895010:50@lid",
    };
    const got = try participantListHashV2(a, &devices);
    defer a.free(got);

    // Independent path: literal ADStrings (no adString call), bytewise sort,
    // sha256 of the concatenation, unpadded standard base64 of the first 6 bytes.
    const sorted = [_][]const u8{
        "15551234.0:0@s.whatsapp.net",
        "216638251077681.0:55@lid",
        "917019895010.0:50@lid",
    };
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (sorted) |s| try joined.appendSlice(a, s);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(joined.items, &digest, .{});
    var buf: [16]u8 = undefined;
    const b64 = std.base64.standard_no_pad.Encoder.encode(&buf, digest[0..6]);
    const want = try std.fmt.allocPrint(a, "2:{s}", .{b64});
    defer a.free(want);
    try std.testing.expectEqualStrings(want, got);
    // Same vector computed outside Zig (node:crypto sha256 + unpadded base64).
    try std.testing.expectEqualStrings("2:+ncitBS4", got);
    // `2:` + 8 chars (6 bytes raw-base64 never pads).
    try std.testing.expectEqual(@as(usize, 10), got.len);
    try std.testing.expectEqualStrings("2:", got[0..2]);

    // Empty device list still hashes (sha256 of the empty string).
    const empty = try participantListHashV2(a, &.{});
    defer a.free(empty);
    // sha256("") starts e3b0c44298fc… -> "2:47DEQpj8", a WhatsApp dictionary token.
    try std.testing.expectEqualStrings("2:47DEQpj8", empty);
}

test "buildGroupInfoQuery shape" {
    const a = std.testing.allocator;
    var iq = try buildGroupInfoQuery(a, "120363421845733873@g.us", "ABCD1234");
    defer iq.deinit();

    const bytes = try binary.marshal(a, iq);
    defer a.free(bytes);
    var decoded = try binary.decodeNode(a, bytes);
    defer decoded.deinit();

    try std.testing.expectEqualStrings("iq", decoded.tag);
    try expectAttr(decoded, "id", "ABCD1234");
    try expectAttr(decoded, "type", "get");
    try expectAttr(decoded, "xmlns", "w:g2");
    try expectAttr(decoded, "to", "120363421845733873@g.us");
    try std.testing.expect(decoded.getAttr("notify") == null);

    const query = try childByTag(decoded, "query");
    try std.testing.expectEqual(@as(usize, 1), decoded.children().len);
    try expectAttr(query, "request", "interactive");
    try std.testing.expectEqual(@as(usize, 0), query.children().len);

    // Bare id gets the group server appended.
    var iq2 = try buildGroupInfoQuery(a, "120363421845733873", "x1");
    defer iq2.deinit();
    try expectAttr(iq2, "to", "120363421845733873@g.us");
}

const Spec = struct {
    tag: []const u8,
    attrs: []const []const u8 = &.{},
    kids: []const Spec = &.{},
    text: []const u8 = "",
};

/// Test helper: same owned-node shape the builders produce.
fn specNode(allocator: std.mem.Allocator, spec: Spec) !binary.Node {
    var n = try newNode(allocator, spec.tag);
    errdefer n.deinit();
    var i: usize = 0;
    while (i + 1 < spec.attrs.len) : (i += 2) try setAttr(&n, spec.attrs[i], spec.attrs[i + 1]);
    if (spec.kids.len > 0) {
        var kids: std.ArrayList(binary.Node) = .empty;
        errdefer {
            for (kids.items) |*k| k.deinit();
            kids.deinit(allocator);
        }
        for (spec.kids) |k| try kids.append(allocator, try specNode(allocator, k));
        const moved_kids = try kids.toOwnedSlice(allocator);
        n.content = .{ .nodes = moved_kids };
    } else if (spec.text.len > 0) {
        try setBytes(&n, spec.text);
    }
    return n;
}

/// Marshal then decode, so parsers see a node exactly like the receive path does.
fn wireNode(allocator: std.mem.Allocator, spec: Spec) !binary.Node {
    var built = try specNode(allocator, spec);
    defer built.deinit();
    const bytes = try binary.marshal(allocator, built);
    defer allocator.free(bytes);
    return binary.decodeNode(allocator, bytes);
}

const group_element = Spec{
    .tag = "group",
    .attrs = &.{
        "id",              "120363421845733873",
        "subject",         "Zepto Lab",
        "s_o",             "216638251077681@lid",
        "s_t",             "1756000000",
        "creation",        "1750000000",
        "addressing_mode", "lid",
        "creator",         "917019895010@s.whatsapp.net",
        "size",            "4",
    },
    .kids = &.{
        .{ .tag = "participant", .attrs = &.{ "jid", "917019895010:50@s.whatsapp.net", "lid", "216638251077681:50@lid", "type", "superadmin", "code", "ABCDEFGH" } },
        .{ .tag = "participant", .attrs = &.{ "jid", "15551234@lid" } },
        .{ .tag = "participant", .attrs = &.{ "jid", "5511999998888:7@lid", "type", "admin" } },
        .{ .tag = "participant", .attrs = &.{ "jid", "15559999@s.whatsapp.net", "type", "participant" } },
        .{ .tag = "description", .attrs = &.{ "id", "DESC1", "t", "1755000000" }, .kids = &.{.{ .tag = "body", .text = "topic text" }} },
        .{ .tag = "locked" },
        .{ .tag = "ephemeral", .attrs = &.{ "expiration", "86400" } },
        .{ .tag = "notification", .attrs = &.{ "subject", "Renamed", "t", "1756000000" } },
    },
};

test "parseGroupInfo reads a w:g2 group element" {
    const a = std.testing.allocator;
    var node = try wireNode(a, .{
        .tag = "iq",
        .attrs = &.{ "id", "IQ1", "type", "result", "from", "120363421845733873@g.us" },
        .kids = &.{.{ .tag = "query", .attrs = &.{"xmlns", "w:g2"}, .kids = &.{group_element} }},
    });
    defer node.deinit();

    var info = try parseGroupInfo(a, node);
    defer info.deinit(a);

    try std.testing.expectEqualStrings("120363421845733873@g.us", info.id);
    try std.testing.expectEqualStrings("Zepto Lab", info.subject);
    try std.testing.expectEqualStrings("216638251077681@lid", info.subject_owner);
    try std.testing.expectEqual(@as(i64, 1756000000), info.subject_time);
    try std.testing.expectEqual(@as(i64, 1750000000), info.creation);
    try std.testing.expectEqualStrings("lid", info.addressing_mode);
    try std.testing.expect(info.locked);

    try std.testing.expectEqual(@as(usize, 4), info.participants.len);
    const owner = info.participants[0];
    try std.testing.expectEqualStrings("917019895010:50@s.whatsapp.net", owner.jid);
    try std.testing.expect(owner.lid != null);
    try std.testing.expectEqualStrings("216638251077681:50@lid", owner.lid.?);
    try std.testing.expect(owner.admin);
    try std.testing.expect(owner.super_admin);

    const lid_member = info.participants[1];
    try std.testing.expectEqualStrings("15551234@lid", lid_member.jid);
    // WhatsApp web groups.js:316: a lid `jid` is mirrored into `lid`.
    try std.testing.expectEqualStrings("15551234@lid", lid_member.lid.?);
    try std.testing.expect(!lid_member.admin);
    try std.testing.expect(!lid_member.super_admin);

    const admin_member = info.participants[2];
    try std.testing.expect(admin_member.admin);
    try std.testing.expect(!admin_member.super_admin);
    try std.testing.expectEqualStrings("5511999998888:7@lid", admin_member.lid.?);

    const plain = info.participants[3];
    try std.testing.expectEqualStrings("15559999@s.whatsapp.net", plain.jid);
    try std.testing.expect(!plain.admin);
    try std.testing.expect(plain.lid == null);
}

test "parseGroupInfo accepts a bare group and legacy query attrs" {
    const a = std.testing.allocator;

    // Bare `<group>` (no wrapping iq) parses directly.
    var bare = try wireNode(a, group_element);
    defer bare.deinit();
    var b_info = try parseGroupInfo(a, bare);
    defer b_info.deinit(a);
    try std.testing.expectEqualStrings("120363421845733873@g.us", b_info.id);
    try std.testing.expectEqual(@as(usize, 4), b_info.participants.len);

    // Legacy `w:gp2` spelling: subject-owner/subject-time on `<query>`, id from the iq.
    var legacy = try wireNode(a, .{
        .tag = "iq",
        .attrs = &.{ "id", "IQ2", "type", "result", "from", "12345678901234-1593401085@g.us" },
        .kids = &.{.{
            .tag = "query",
            .attrs = &.{
                "xmlns",          "w:gp2",
                "subject",        "Old Name",
                "subject-owner",  "917019895010@s.whatsapp.net",
                "subject-time",   "1600000000",
                "creation",       "1590000000",
                "locked",         "true",
            },
            .kids = &.{
                .{ .tag = "participant", .attrs = &.{"jid", "917019895010@s.whatsapp.net"} },
                .{ .tag = "participant", .attrs = &.{} },
            },
        }},
    });
    defer legacy.deinit();
    var l_info = try parseGroupInfo(a, legacy);
    defer l_info.deinit(a);
    try std.testing.expectEqualStrings("12345678901234-1593401085@g.us", l_info.id);
    try std.testing.expectEqualStrings("Old Name", l_info.subject);
    try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", l_info.subject_owner);
    try std.testing.expectEqual(@as(i64, 1600000000), l_info.subject_time);
    try std.testing.expectEqual(@as(i64, 1590000000), l_info.creation);
    try std.testing.expectEqualStrings("", l_info.addressing_mode);
    try std.testing.expect(l_info.locked);
    // Participant without a jid attr is skipped.
    try std.testing.expectEqual(@as(usize, 1), l_info.participants.len);

    // No group/query element at all is an error, not a silent empty result.
    var junk = try wireNode(a, .{ .tag = "iq", .attrs = &.{ "id", "IQ3", "type", "error" } });
    defer junk.deinit();
    try std.testing.expectError(error.MissingGroupElement, parseGroupInfo(a, junk));
}

const skdm_ct_1 = [_]u8{ 0x33, 0x0a, 0x01, 0x41, 0x55 };
const skdm_ct_2 = [_]u8{ 0x34, 0x0b, 0x02, 0x99 };
const skmsg_ct = "\x01\x02\x03\xfesigned-ser!";
const skdm_plain = "SKDM-WRAPPER-PLAINTEXT";

test "buildGroupMessageNode matches the whatsmeow sendGroup shape" {
    const a = std.testing.allocator;
    const targets = [_]stanza.Participant{
        .{ .jid = "917019895010:50@lid", .enc_type = .pkmsg, .ciphertext = &skdm_ct_1 },
        // Own lid device: whatsmeow `continue`s on it, so it must not appear.
        .{ .jid = "216638251077681:55@lid", .enc_type = .msg, .ciphertext = &skdm_ct_2 },
        .{ .jid = "15551234.0:52@s.whatsapp.net", .enc_type = .msg, .ciphertext = &skdm_ct_2 },
    };
    // phash input keeps own devices (whatsmeow hashes allDevices).
    const devices = [_][]const u8{
        "216638251077681:55@lid",
        "917019895010:50@lid",
        "15551234.0:52@s.whatsapp.net",
    };
    var node = try buildGroupMessageNode(a, .{
        .id = "3EB0A7C9F0",
        .to_group = "120363421845733873@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .own_lid = "216638251077681:55@lid",
        .addressing_mode = "lid",
        .participants_device_jids = &devices,
        .skmsg_ciphertext = skmsg_ct,
        .media_type = "image",
        .skdm_payload = skdm_plain,
        .skdm_targets = &targets,
        .device_identity = &.{ 0x0a, 0x04, 'a', 'd', 'd', 'r' },
    });
    defer node.deinit();

    const bytes = try binary.marshal(a, node);
    defer a.free(bytes);
    var d = try binary.decodeNode(a, bytes);
    defer d.deinit();

    try std.testing.expectEqualStrings("message", d.tag);
    try expectAttr(d, "id", "3EB0A7C9F0");
    try expectAttr(d, "to", "120363421845733873@g.us");
    // getTypeFromMessage: media present -> "media".
    try expectAttr(d, "type", "media");
    try expectAttr(d, "addressing_mode", "lid");
    try std.testing.expect(d.getAttr("t") == null);
    try std.testing.expect(d.getAttr("notify") == null);
    const want_phash = try participantListHashV2(a, &devices);
    defer a.free(want_phash);
    try expectAttr(d, "phash", want_phash);
    try std.testing.expectEqual(@as(usize, 5), d.attrs.count());

    // Children: participants, device-identity, then the appended skmsg <enc>.
    try std.testing.expectEqual(@as(usize, 3), d.children().len);
    try std.testing.expectEqualStrings("participants", d.children()[0].tag);
    try std.testing.expectEqualStrings("device-identity", d.children()[1].tag);
    try std.testing.expectEqualStrings("enc", d.children()[2].tag);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x04, 'a', 'd', 'd', 'r' }, d.children()[1].contentBytes().?);

    const skmsg = d.children()[2];
    try expectAttr(skmsg, "v", "2");
    try expectAttr(skmsg, "type", "skmsg");
    try expectAttr(skmsg, "mediatype", "image");
    try std.testing.expectEqualStrings(skmsg_ct, skmsg.contentBytes().?);

    const parts = d.children()[0];
    try std.testing.expectEqual(@as(usize, 0), parts.attrs.count());
    try std.testing.expectEqual(@as(usize, 2), parts.children().len);

    const to_a = parts.children()[0];
    try std.testing.expectEqualStrings("to", to_a.tag);
    try expectAttr(to_a, "jid", "917019895010:50@lid");
    try std.testing.expectEqual(@as(usize, 1), to_a.children().len);
    const enc_a = to_a.children()[0];
    try std.testing.expectEqualStrings("enc", enc_a.tag);
    try expectAttr(enc_a, "v", "2");
    try expectAttr(enc_a, "type", "pkmsg");
    // whatsmeow gives groups no per-device mediatype (dsmPlaintext is nil).
    try std.testing.expect(enc_a.getAttr("mediatype") == null);
    try std.testing.expectEqualSlices(u8, &skdm_ct_1, enc_a.contentBytes().?);

    const to_b = parts.children()[1];
    try expectAttr(to_b, "jid", "15551234.0:52@s.whatsapp.net");
    try expectAttr(to_b.children()[0], "type", "msg");
    try std.testing.expectEqualSlices(u8, &skdm_ct_2, to_b.children()[0].contentBytes().?);

    // Byte regions survive the framing untouched, and nothing plaintext leaks out.
    try std.testing.expect(std.mem.indexOf(u8, bytes, skmsg_ct) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &skdm_ct_1) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, skdm_plain) == null);
}

test "buildGroupMessageNode defaults, opt-in attrs, and payload fallback" {
    const a = std.testing.allocator;
    const targets = [_]stanza.Participant{
        // Empty ciphertext -> falls back to the shared SKDM wrapper plaintext.
        .{ .jid = "15551234:5@lid", .enc_type = .msg, .ciphertext = "" },
    };
    const devices = [_][]const u8{"15551234:5@lid"};

    var node = try buildGroupMessageNode(a, .{
        .id = "ID1",
        .to_group = "120363421845733873@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .participants_device_jids = &devices,
        .skmsg_ciphertext = skmsg_ct,
        .skdm_payload = skdm_plain,
        .skdm_targets = &targets,
        .timestamp = 1756800000,
        .push_name = "Barvis",
    });
    defer node.deinit();

    const bytes = try binary.marshal(a, node);
    defer a.free(bytes);
    var d = try binary.decodeNode(a, bytes);
    defer d.deinit();

    try expectAttr(d, "type", "text");
    try std.testing.expect(d.getAttr("addressing_mode") == null);
    try expectAttr(d, "t", "1756800000");
    try expectAttr(d, "notify", "Barvis");
    try std.testing.expect(d.getAttr("phash") != null);
    try std.testing.expectEqual(@as(usize, 2), d.children().len);
    try std.testing.expectEqualStrings("participants", d.children()[0].tag);
    try std.testing.expectEqualStrings("enc", d.children()[1].tag);
    try std.testing.expect(d.children()[1].getAttr("mediatype") == null);

    const enc = d.children()[0].children()[0].children()[0];
    try std.testing.expectEqualStrings("enc", enc.tag);
    try std.testing.expectEqualStrings(skdm_plain, enc.contentBytes().?);

    // No targets at all -> empty <participants/>, skmsg still sent.
    var empty = try buildGroupMessageNode(a, .{
        .id = "ID2",
        .to_group = "123@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .skmsg_ciphertext = skmsg_ct,
        .msg_type = "text",
    });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 2), empty.children().len);
    try std.testing.expectEqual(@as(usize, 0), empty.children()[0].children().len);
    try expectAttr(empty, "type", "text");
    const empty_phash = try participantListHashV2(a, &.{});
    defer a.free(empty_phash);
    try expectAttr(empty, "phash", empty_phash);
}

test "group stanza marshal roundtrip is stable" {
    const a = std.testing.allocator;
    const devices = [_][]const u8{ "917019895010:50@lid", "15551234.0:52@s.whatsapp.net" };
    const targets = [_]stanza.Participant{
        .{ .jid = "917019895010:50@lid", .enc_type = .pkmsg, .ciphertext = &skdm_ct_1 },
        .{ .jid = "15551234.0:52@s.whatsapp.net", .enc_type = .msg, .ciphertext = &skdm_ct_2 },
    };
    var node = try buildGroupMessageNode(a, .{
        .id = "STABLE1",
        .to_group = "120363421845733873@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .addressing_mode = "lid",
        .participants_device_jids = &devices,
        .skmsg_ciphertext = skmsg_ct,
        .media_type = "ptt",
        .skdm_targets = &targets,
    });
    defer node.deinit();

    const first = try binary.marshal(a, node);
    defer a.free(first);
    const second = try binary.marshal(a, node);
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    var decoded = try binary.decodeNode(a, first);
    defer decoded.deinit();
    const third = try binary.marshal(a, decoded);
    defer a.free(third);
    try std.testing.expectEqualSlices(u8, first, third);

    // 29 ciphertext bytes ride along; the rest is literal attr value bytes (message
    // id, group JID, participant JIDs, phash) plus a few framing bytes per node.
    const payload: usize = skmsg_ct.len + skdm_ct_1.len + skdm_ct_2.len;
    try std.testing.expect(first.len > payload);
    try std.testing.expect(first.len < 220);

    // Sender-key fanout must stay cheap and linear: each extra device only pays for
    // one `<to jid><enc>` pair, never for the whole stanza again.
    var devs: std.ArrayList([]const u8) = .empty;
    defer {
        for (devs.items) |d| a.free(d);
        devs.deinit(a);
    }
    // `many` aliases the `devs` strings; `devs` owns the allocations.
    var many: std.ArrayList(stanza.Participant) = .empty;
    defer many.deinit(a);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const j = try std.fmt.allocPrint(a, "1555000000{d}@lid", .{i});
        try devs.append(a, j);
        try many.append(a, .{ .jid = j, .enc_type = .msg, .ciphertext = &skdm_ct_2 });
    }
    var big = try buildGroupMessageNode(a, .{
        .id = "STABLE1",
        .to_group = "120363421845733873@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .addressing_mode = "lid",
        .participants_device_jids = devs.items,
        .skmsg_ciphertext = skmsg_ct,
        .media_type = "ptt",
        .skdm_targets = many.items,
    });
    defer big.deinit();
    const big_bytes = try binary.marshal(a, big);
    defer a.free(big_bytes);
    try std.testing.expectEqual(@as(usize, 8), big.children()[0].children().len);
    const per_device = (big_bytes.len - first.len) / 7;
    try std.testing.expect(per_device > 16);
    try std.testing.expect(per_device < 48);
}

// Every builder below must release everything it took on BOTH paths; the
// FailingAllocator behind checkAllAllocationFailures walks every allocation site in
// turn and the testing allocator reports any leak or double free.

fn probeQueryBuild(allocator: std.mem.Allocator) !void {
    var iq = try buildGroupInfoQuery(allocator, "120363421845733873", "IQID1");
    defer iq.deinit();
    const bytes = try binary.marshal(allocator, iq);
    allocator.free(bytes);
}

fn probeInfoParse(allocator: std.mem.Allocator, src: binary.Node) !void {
    var info = try parseGroupInfo(allocator, src);
    info.deinit(allocator);
}

fn probeHash(allocator: std.mem.Allocator) !void {
    const devices = [_][]const u8{ "917019895010:50@lid", "15551234@s.whatsapp.net" };
    const hash = try participantListHashV2(allocator, &devices);
    allocator.free(hash);
}

fn probeMessageBuild(allocator: std.mem.Allocator) !void {
    const targets = [_]stanza.Participant{
        .{ .jid = "917019895010:50@lid", .enc_type = .pkmsg, .ciphertext = &skdm_ct_1 },
        .{ .jid = "216638251077681:55@lid", .enc_type = .msg, .ciphertext = &skdm_ct_2 },
        .{ .jid = "15551234:5@lid", .enc_type = .msg, .ciphertext = "" },
    };
    const devices = [_][]const u8{ "216638251077681:55@lid", "917019895010:50@lid", "15551234:5@lid" };
    var node = try buildGroupMessageNode(allocator, .{
        .id = "FAULT1",
        .to_group = "120363421845733873@g.us",
        .own_jid = "917019895010:50@s.whatsapp.net",
        .own_lid = "216638251077681:55@lid",
        .addressing_mode = "lid",
        .participants_device_jids = &devices,
        .skmsg_ciphertext = skmsg_ct,
        .media_type = "image",
        .skdm_payload = skdm_plain,
        .skdm_targets = &targets,
        .device_identity = &.{ 0x0a, 0x01, 0x41 },
        .timestamp = 1756800000,
    });
    defer node.deinit();
    const bytes = try binary.marshal(allocator, node);
    allocator.free(bytes);
}

test "group builders unwind cleanly on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, probeQueryBuild, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, probeHash, .{});

    var src = try wireNode(std.testing.allocator, .{
        .tag = "iq",
        .attrs = &.{ "id", "IQ1", "type", "result" },
        .kids = &.{group_element},
    });
    defer src.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, probeInfoParse, .{src});

    try std.testing.checkAllAllocationFailures(std.testing.allocator, probeMessageBuild, .{});
}
