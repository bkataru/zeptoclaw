const std = @import("std");
const nc = @import("noise_crypto.zig");
const proto = @import("proto.zig");
const handshake = @import("handshake.zig");
const socket = @import("socket.zig");
const pair = @import("pair.zig");
const binary = @import("binary.zig");
const store_mod = @import("store.zig");
const jid = @import("jid.zig");
const signal = @import("signal.zig");
const stanza = @import("stanza.zig");
const curve_sigs = @import("curve_sigs.zig");
const encrypt = @import("encrypt.zig");
const media = @import("media.zig");
const sg = @import("signal_groups.zig");
const groups_mod = @import("groups.zig");

const keepalive_interval_ms: u32 = 25_000;
const iq_timeout_ms: i64 = 20_000;
/// whatsmeow MinPreKeyCount / WantedPreKeyCount.
const min_prekey_count: u32 = 5;
const wanted_prekey_count: u32 = 50;
/// Cache size for automatic retry-receipt resend (whatsmeow recentMessagesSize
/// is 256; this is a single-account gateway, not a multi-tenant server).
const recent_out_cap: usize = 64;
const recent_in_cap: usize = 64;
/// Cap on automatic resends per cached outbound message id (whatsmeow's
/// internal retry counter drops at 10); stops a persistently broken session
/// from causing an unbounded resend loop.
const max_auto_retries: u32 = 5;

/// Port of whatsmeow/client.go connection lifecycle (Connect + doHandshake).
/// Native WhatsApp multi-device client (Noise + Signal). Pairing QR and
/// inbound decrypt share this connection lifecycle.
const PeerSession = struct {
    session: signal.Session,
    pending_prekey: ?signal.PreKeyHeader = null,
};

/// Cached plaintext of a message we sent, keyed by message id, so a later
/// `<receipt type=retry>` from any fanned-out device can trigger an automatic
/// resend (whatsmeow retry.go addRecentMessage). `dest` is the wire `to` used
/// on the original send (post LID rewrite) — needed to rebuild the
/// DeviceSentMessage wrapper for a retrying own-device.
const RecentOut = struct {
    dest: []u8,
    plaintext: []u8,
    retries: u32 = 0,

    fn deinit(self: RecentOut, allocator: std.mem.Allocator) void {
        allocator.free(self.dest);
        allocator.free(self.plaintext);
    }
};

const RecentIn = struct {
    id: []u8,
    chat: []u8,
    sender: []u8,
    from_me: bool,

    fn deinit(self: RecentIn, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.chat);
        allocator.free(self.sender);
    }
};

/// Decrypted chat message handed to the channel. Memory: receiver calls deinit.
pub const InboundMessage = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    chat: []u8,
    sender: []u8,
    sender_pn: ?[]u8 = null,
    push_name: ?[]u8 = null,
    text: []u8,
    /// Present when the message carried downloadable media (image/video/audio/doc).
    media: ?MediaAttachment = null,
    from_me: bool,
    timestamp: i64,
    is_group: bool,
    mentioned_jids: [][]u8 = &.{},
    quoted_stanza_id: ?[]u8 = null,
    quoted_participant: ?[]u8 = null,
    quoted_text: ?[]u8 = null,
    location: ?proto.Geo = null,
    kind: Kind = .text,

    pub const Kind = enum { text, reaction, poll, location, revoke };

    pub const MediaAttachment = struct {
        kind: media.Kind,
        /// direct_path (preferred) or absolute url (owned).
        url: []u8,
        media_key: [32]u8,
        mimetype: ?[]u8 = null,

        pub fn deinit(self: *const MediaAttachment, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
            if (self.mimetype) |m| allocator.free(m);
        }
    };

    pub fn deinit(self: *InboundMessage) void {
        self.allocator.free(self.id);
        self.allocator.free(self.chat);
        self.allocator.free(self.sender);
        if (self.sender_pn) |s| self.allocator.free(s);
        if (self.push_name) |s| self.allocator.free(s);
        if (self.media) |*m| m.deinit(self.allocator);
        self.allocator.free(self.text);
        for (self.mentioned_jids) |m| self.allocator.free(m);
        if (self.mentioned_jids.len > 0) self.allocator.free(self.mentioned_jids);
        if (self.quoted_stanza_id) |s| self.allocator.free(s);
        if (self.quoted_participant) |s| self.allocator.free(s);
        if (self.quoted_text) |s| self.allocator.free(s);
    }
};

/// One server frame → one event (see `Client.poll`).
pub const Event = union(enum) {
    /// Nothing for the channel (ack sent, presence, offline preview, ...).
    idle,
    /// Pairing refs from `<iq pair-device>`. Slices owned by Client; valid until the next poll.
    qr: []const []u8,
    /// `<iq pair-success>` handled and persisted; server closes next, caller reconnects.
    paired: struct { jid: []const u8, lid: []const u8 },
    /// `<success>`: logged in on the paired identity.
    connected: struct { jid: []const u8, lid: []const u8 },
    /// Decrypted text; receiver owns and must deinit.
    message: InboundMessage,
    /// `<failure>` / `<stream:error>` / stream end. 515 = restart required (reconnect now).
    disconnected: struct { code: u32, logged_out: bool },
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    sock: socket.NoiseSocket,
    noise: nc.KeyPair,
    identity: nc.KeyPair,
    signed_pre_key: nc.KeyPair,
    signed_pre_key_id: u32 = 1,
    signed_pre_key_sig: [64]u8 = [_]u8{0} ** 64,
    registration_id: u32,
    adv_secret: [32]u8,
    connected: bool = false,
    logged_in: bool = false,
    paired: bool = false,
    qr_codes: std.ArrayList([]u8) = .empty,
    store: ?store_mod.Store = null,
    paired_jid: ?[]u8 = null,
    paired_lid: ?[]u8 = null,
    sessions: std.StringHashMap(PeerSession),
    write_mu: std.Io.Mutex = .init,
    /// Guards `sessions` + store access from the poll thread and senders.
    state_mu: std.Io.Mutex = .init,
    pending_mu: std.Io.Mutex = .init,
    pending: std.StringHashMap(*Waiter),
    retries: std.StringHashMap(u32),
    /// Bounded FIFO cache backing automatic retry-receipt resend; see `RecentOut`.
    recent_out: std.StringHashMap(RecentOut),
    recent_out_ring: [recent_out_cap]?[]u8 = [_]?[]u8{null} ** recent_out_cap,
    recent_out_ring_pos: usize = 0,
    recent_out_mu: std.Io.Mutex = .init,
    recent_in: [recent_in_cap]?RecentIn = [_]?RecentIn{null} ** recent_in_cap,
    recent_in_pos: usize = 0,
    recent_in_mu: std.Io.Mutex = .init,
    /// Count of in-flight detached retry-resend worker threads; `disconnect`
    /// waits for this to hit zero so a worker never outlives its `*Client`.
    retry_workers_active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// In-memory sender-key records over sqlite (mirrors `sessions`).
    sender_key_cache: std.StringHashMap(*sg.SenderKeyRecord),
    keepalive_thread: ?std.Thread = null,
    keepalive_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    prekey_count_iq: ?[]u8 = null,
    prekey_upload_iq: ?[]u8 = null,
    prekey_upload_up_to: u32 = 0,
    /// Marshaled ADVSignedDeviceIdentity for `<device-identity>` (owned).
    adv_account: ?[]u8 = null,
    media_conn_auth: ?[]u8 = null,
    media_conn_host: ?[]u8 = null,
    media_conn_until_ms: i64 = 0,
    /// Raw ADV parts + pairing metadata as stored in `whatsmeow_device` (owned slices).
    adv_details: ?[]u8 = null,
    adv_account_sig: [64]u8 = [_]u8{0} ** 64,
    adv_account_sig_key: [32]u8 = [_]u8{0} ** 32,
    adv_device_sig: [64]u8 = [_]u8{0} ** 64,
    platform: ?[]u8 = null,
    business_name: ?[]u8 = null,
    id_epoch: u32 = 0,
    id_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    last_message_id: [16]u8 = [_]u8{'0'} ** 16,

    pub fn init(allocator: std.mem.Allocator) Client {
        const io = std.Io.Threaded.global_single_threaded.io();
        var rid_buf: [4]u8 = undefined;
        io.random(&rid_buf);
        var rid = std.mem.readInt(u32, &rid_buf, .little);
        if (rid == 0) rid = 1;
        var adv: [32]u8 = undefined;
        io.random(&adv);
        var epoch_buf: [4]u8 = undefined;
        io.random(&epoch_buf);
        var cli = Client{
            .allocator = allocator,
            .sock = socket.NoiseSocket.init(allocator),
            .noise = nc.KeyPair.generate(io),
            .identity = nc.KeyPair.generate(io),
            .signed_pre_key = nc.KeyPair.generate(io),
            .registration_id = rid,
            .adv_secret = adv,
            .sessions = std.StringHashMap(PeerSession).init(allocator),
            .pending = std.StringHashMap(*Waiter).init(allocator),
            .retries = std.StringHashMap(u32).init(allocator),
            .recent_out = std.StringHashMap(RecentOut).init(allocator),
            .sender_key_cache = std.StringHashMap(*sg.SenderKeyRecord).init(allocator),
            .id_epoch = std.mem.readInt(u32, &epoch_buf, .little) & 0xffff,
        };
        cli.signSignedPreKey(io);
        return cli;
    }

    fn signSignedPreKey(self: *Client, io: std.Io) void {
        var random: [64]u8 = undefined;
        io.random(&random);
        const key33 = signal.encodeDjb(self.signed_pre_key.pub_key);
        self.signed_pre_key_sig = curve_sigs.sign(self.identity.priv_key, &key33, random) catch [_]u8{0} ** 64;
    }

    pub fn deinit(self: *Client) void {
        self.waitRetryWorkersIdle();
        self.stopKeepalive();
        self.clearQr();
        self.qr_codes.deinit(self.allocator);
        if (self.paired_jid) |s| self.allocator.free(s);
        if (self.paired_lid) |s| self.allocator.free(s);
        if (self.adv_account) |s| self.allocator.free(s);
        if (self.media_conn_auth) |s| self.allocator.free(s);
        if (self.media_conn_host) |s| self.allocator.free(s);
        if (self.adv_details) |s| self.allocator.free(s);
        if (self.platform) |s| self.allocator.free(s);
        if (self.business_name) |s| self.allocator.free(s);
        if (self.prekey_count_iq) |s| self.allocator.free(s);
        if (self.prekey_upload_iq) |s| self.allocator.free(s);
        if (self.store) |*s| s.deinit();
        var sit = self.sessions.iterator();
        while (sit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.sessions.deinit();
        var pit = self.pending.iterator();
        while (pit.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.*.response) |r| self.allocator.free(r);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.pending.deinit();
        var rit = self.retries.iterator();
        while (rit.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.retries.deinit();
        var rot = self.recent_out.iterator();
        while (rot.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(self.allocator);
        }
        {
            const io = ioOf();
            self.recent_in_mu.lock(io) catch {};
            for (self.recent_in) |slot| if (slot) |ri| ri.deinit(self.allocator);
            self.recent_in_mu.unlock(io);
        }
        self.recent_out.deinit();
        var kit = self.sender_key_cache.iterator();
        while (kit.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.sender_key_cache.deinit();
        self.sock.deinit();
        self.connected = false;
        self.paired = false;
    }

    fn setAdvAccount(self: *Client, details: []const u8, acct_key: [32]u8, acct_sig: [64]u8, dev_sig: [64]u8) !void {
        const signed = proto.ADVSignedDeviceIdentity{
            .details = details,
            .account_signature_key = &acct_key,
            .account_signature = &acct_sig,
            .device_signature = &dev_sig,
        };
        const blob = try signed.encode(self.allocator);
        errdefer self.allocator.free(blob);
        const details_copy = try self.allocator.dupe(u8, details);
        if (self.adv_account) |old| self.allocator.free(old);
        if (self.adv_details) |old| self.allocator.free(old);
        self.adv_account = blob;
        self.adv_details = details_copy;
        self.adv_account_sig_key = acct_key;
        self.adv_account_sig = acct_sig;
        self.adv_device_sig = dev_sig;
    }

    /// Upsert our `whatsmeow_device` row from live keys. Every other table has a
    /// FOREIGN KEY onto it (foreign_keys=ON), so sessions/identities/prekeys silently
    /// fail to persist until this row exists. Called on pairing, LID change, and by
    /// tests that simulate a restart.
    pub fn persistDevice(self: *Client) !void {
        const s = if (self.store) |*st| st else return error.NotOpen;
        const own = self.paired_jid orelse return error.NotPaired;
        try s.putDevice(.{
            .allocator = self.allocator,
            .jid = own,
            .lid = self.paired_lid,
            .registration_id = self.registration_id,
            .noise_key = self.noise.priv_key,
            .identity_key = self.identity.priv_key,
            .signed_pre_key = self.signed_pre_key.priv_key,
            .signed_pre_key_id = self.signed_pre_key_id,
            .signed_pre_key_sig = self.signed_pre_key_sig,
            .adv_key = self.adv_secret,
            .adv_details = self.adv_details orelse "",
            .adv_account_sig = self.adv_account_sig,
            .adv_account_sig_key = self.adv_account_sig_key,
            .adv_device_sig = self.adv_device_sig,
            .platform = self.platform orelse "",
            .business_name = self.business_name orelse "",
        });
        if (self.paired_lid) |lid| try s.putLidMap(jid.user(lid), jid.user(own));
    }

    pub fn openStore(self: *Client, path: []const u8) !void {
        if (self.store) |*s| s.deinit();
        var s = store_mod.Store.init(self.allocator, path);
        try s.open();
        self.store = s;
    }

    fn setPairedIds(self: *Client, pn_jid: []const u8, lid_jid: []const u8) !void {
        if (self.paired_jid) |s| self.allocator.free(s);
        if (self.paired_lid) |s| self.allocator.free(s);
        self.paired_jid = if (pn_jid.len == 0) null else try self.allocator.dupe(u8, pn_jid);
        self.paired_lid = if (lid_jid.len == 0) null else try self.allocator.dupe(u8, lid_jid);
        self.paired = self.paired_jid != null;
    }

    pub fn setOwnJid(self: *Client, pn: []const u8) !void {
        try self.setPairedIds(pn, "");
    }

    /// Restore keys from the first sqlite device row.
    pub fn loadFromStore(self: *Client) !void {
        const s = if (self.store) |*st| st else return error.NotOpen;
        var dev = (try s.getAnyDevice()) orelse return error.NotPaired;
        defer dev.deinit();
        self.noise = nc.KeyPair.fromPrivate(dev.noise_key);
        self.identity = nc.KeyPair.fromPrivate(dev.identity_key);
        self.signed_pre_key = nc.KeyPair.fromPrivate(dev.signed_pre_key);
        self.signed_pre_key_id = dev.signed_pre_key_id;
        self.signed_pre_key_sig = dev.signed_pre_key_sig;
        self.adv_secret = dev.adv_key;
        self.registration_id = dev.registration_id;
        try self.setPairedIds(dev.jid, dev.lid orelse "");
        try self.setAdvAccount(dev.adv_details, dev.adv_account_sig_key, dev.adv_account_sig, dev.adv_device_sig);
        try self.setOwnedStr(&self.platform, dev.platform);
        try self.setOwnedStr(&self.business_name, dev.business_name);
    }

    /// Drop dead pairing state and restart as a brand-new device.
    /// QR re-pair after a 401: fresh keys, no jid, dead sqlite device row
    /// gone so getAnyDevice can't resurrect it. Pair-success repopulates.
    pub fn resetForRepair(self: *Client) !void {
        const io = ioOf();
        if (self.paired_jid) |dead| {
            if (self.store) |*s| s.deleteDevice(dead) catch |err| storeWarn("delete dead device", err);
            self.allocator.free(dead);
            self.paired_jid = null;
        }
        if (self.paired_lid) |s| {
            self.allocator.free(s);
            self.paired_lid = null;
        }
        self.paired = false;
        self.noise = nc.KeyPair.generate(io);
        self.identity = nc.KeyPair.generate(io);
        self.signed_pre_key = nc.KeyPair.generate(io);
        self.signSignedPreKey(io);
        var rid_buf: [4]u8 = undefined;
        io.random(&rid_buf);
        self.registration_id = std.mem.readInt(u32, &rid_buf, .little);
        if (self.registration_id == 0) self.registration_id = 1;
        io.random(&self.adv_secret);
        if (self.adv_account) |s| {
            self.allocator.free(s);
            self.adv_account = null;
        }
        if (self.adv_details) |s| {
            self.allocator.free(s);
            self.adv_details = null;
        }
        self.adv_account_sig = [_]u8{0} ** 64;
        self.adv_account_sig_key = [_]u8{0} ** 32;
        self.adv_device_sig = [_]u8{0} ** 64;
    }

    fn setOwnedStr(self: *Client, slot: *?[]u8, value: []const u8) !void {
        const copy = if (value.len == 0) null else try self.allocator.dupe(u8, value);
        if (slot.*) |old| self.allocator.free(old);
        slot.* = copy;
    }

    fn clearQr(self: *Client) void {
        for (self.qr_codes.items) |c| self.allocator.free(c);
        self.qr_codes.clearRetainingCapacity();
    }

    /// Parse a pair-device IQ, store QR URLs, return the binary ACK stanza.
    /// Memory: caller frees the ACK bytes; QR strings are owned by Client.
    pub fn handlePairDeviceIq(self: *Client, iq: binary.Node) ![]u8 {
        const ev = try pair.handlePairDevice(
            self.allocator,
            iq,
            self.noise.pub_key,
            self.identity.pub_key,
            self.adv_secret,
            pair.default_client_type,
        );
        self.clearQr();
        try self.qr_codes.appendSlice(self.allocator, ev.codes);
        self.allocator.free(ev.codes);
        return ev.ack;
    }

    pub fn getQr(self: *const Client) []const []u8 {
        return self.qr_codes.items;
    }

    /// Verify pair-success HMAC + account signature, attach device signature,
    /// return pair-device-sign IQ bytes. Does not persist sqlite (caller does).
    /// Memory: caller frees the returned stanza.
    pub fn handlePairSuccessIq(self: *Client, iq: binary.Node, random: [64]u8) ![]u8 {
        const parts = try pair.parsePairSuccess(iq);
        const container = try proto.ADVSignedDeviceIdentityHMAC.decode(parts.device_identity);
        if (!pair.hmacMatches(self.adv_secret, container)) return error.HmacMismatch;
        var signed = try proto.ADVSignedDeviceIdentity.decode(container.details);
        const details = try proto.ADVDeviceIdentity.decode(signed.details);
        const hosted = details.device_type == 1;
        if (!pair.verifyAccountSignature(signed, self.identity.pub_key, hosted))
            return error.SignatureMismatch;
        const dev_sig = try pair.generateDeviceSignature(
            signed,
            self.identity.priv_key,
            self.identity.pub_key,
            hosted,
            random,
        );
        try self.persistPairing(parts, signed, dev_sig);
        signed.device_signature = &dev_sig;
        signed.account_signature_key = &.{};
        const blob = try signed.encode(self.allocator);
        defer self.allocator.free(blob);
        return pair.encodePairDeviceSign(self.allocator, parts.id, details.key_index, blob);
    }

    fn persistPairing(
        self: *Client,
        parts: pair.PairSuccessParts,
        signed: proto.ADVSignedDeviceIdentity,
        dev_sig: [64]u8,
    ) !void {
        try self.setPairedIds(parts.jid, parts.lid);
        var acct_sig: [64]u8 = [_]u8{0} ** 64;
        if (signed.account_signature.len == 64)
            @memcpy(&acct_sig, signed.account_signature[0..64]);
        var acct_key: [32]u8 = [_]u8{0} ** 32;
        if (signed.account_signature_key.len == 32)
            @memcpy(&acct_key, signed.account_signature_key[0..32]);
        try self.setAdvAccount(signed.details, acct_key, acct_sig, dev_sig);
        try self.setOwnedStr(&self.platform, parts.platform);
        try self.setOwnedStr(&self.business_name, parts.business_name);
        if (self.store == null) return;
        try self.persistDevice();
    }

    /// Decode a WA binary frame and handle pairing IQs. Returns reply stanza bytes
    /// (caller frees) or null if no reply.
    pub fn handleIncomingFrame(self: *Client, frame: []const u8) !?[]u8 {
        var node = try binary.decodeNode(self.allocator, frame);
        defer node.deinit();
        return self.handleNode(node);
    }

    pub fn handleNode(self: *Client, node: binary.Node) !?[]u8 {
        if (!std.mem.eql(u8, node.tag, "iq")) return null;
        if (node.getChildByTag("pair-device") != null) {
            return try self.handlePairDeviceIq(node);
        }
        if (node.getChildByTag("pair-success") != null) {
            var random: [64]u8 = undefined;
            std.Io.Threaded.global_single_threaded.io().random(&random);
            return try self.handlePairSuccessIq(node, random);
        }
        return null;
    }

    /// Unpaired chrome-like companion ClientPayload (devicePairingData=19):
    /// passive=false pull=false + buildHash + deviceProps (WhatsApp web generateRegistrationNode).
    /// Memory: caller frees with allocator.
    pub fn unpairedPayload(self: *const Client, allocator: std.mem.Allocator) ![]u8 {
        var e_regid: [4]u8 = undefined;
        std.mem.writeInt(u32, &e_regid, self.registration_id, .big);
        const e_keytype = [_]u8{5};
        var e_skey_id: [3]u8 = undefined;
        e_skey_id[0] = @intCast((self.signed_pre_key_id >> 16) & 0xff);
        e_skey_id[1] = @intCast((self.signed_pre_key_id >> 8) & 0xff);
        e_skey_id[2] = @intCast(self.signed_pre_key_id & 0xff);
        const user_agent = proto.UserAgent{};
        const build_hash = user_agent.app_version.buildHash();
        const device_props = try (proto.DeviceProps{}).encode(allocator);
        defer allocator.free(device_props);
        const payload = proto.ClientPayload{
            .user_agent = user_agent,
            .passive = false,
            .pull = false,
            .device_pairing_data = .{
                .e_regid = &e_regid,
                .e_keytype = &e_keytype,
                .e_ident = &self.identity.pub_key,
                .e_skey_id = &e_skey_id,
                .e_skey_val = &self.signed_pre_key.pub_key,
                .e_skey_sig = &self.signed_pre_key_sig,
                .build_hash = &build_hash,
                .device_props = device_props,
            },
        };
        return payload.encode(allocator);
    }

    /// Paired companion login ClientPayload: username=PN user, device=id,
    /// passive=false pull=true (WhatsApp web generateLoginNode).
    /// Memory: caller frees with allocator.
    pub fn loginPayload(self: *const Client, allocator: std.mem.Allocator) ![]u8 {
        const own = self.paired_jid orelse return error.NotPaired;
        const user_digits = jid.user(own);
        const username = std.fmt.parseInt(u64, user_digits, 10) catch return error.InvalidOwnJid;
        const payload = proto.ClientPayload{
            .username = username,
            .device = jid.device(own),
            .passive = false,
            .pull = true,
        };
        return payload.encode(allocator);
    }

    /// Dial `url` (empty → wss://web.whatsapp.com/ws/chat), Noise XX handshake,
    /// install frame cipher. Registration payload when unpaired, login payload
    /// when paired. `<success>` (login) or `<iq pair-device>` (registration)
    /// arrives via `poll`.
    pub fn connect(self: *Client, url: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ephemeral = nc.KeyPair.generate(io);
        try self.sock.connect(url);
        const payload = if (self.paired)
            try self.loginPayload(self.allocator)
        else
            try self.unpairedPayload(self.allocator);
        defer self.allocator.free(payload);
        const keys = try handshake.doHandshake(self.allocator, &self.sock, ephemeral, self.noise, payload);
        self.sock.installCipher(keys.write_key, keys.read_key);
        self.connected = true;
        self.logged_in = false;
        // Ping before login too — otherwise the socket dies while the user scans.
        self.startKeepalive();
    }

    pub fn disconnect(self: *Client) void {
        self.stopKeepalive();
        self.sock.ws.disconnect();
        self.sock.cipher = null;
        self.connected = false;
        self.logged_in = false;
        self.failPendingIqs();
        self.waitRetryWorkersIdle();
    }

    pub fn isConnected(self: *const Client) bool {
        return self.connected and self.logged_in;
    }

    pub fn selfJid(self: *const Client) ?[]const u8 {
        return self.paired_jid;
    }

    pub fn selfLid(self: *const Client) ?[]const u8 {
        return self.paired_lid;
    }

    fn ioOf() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    fn nowMs() i64 {
        return @intCast(@divTrunc(std.Io.Clock.real.now(ioOf()).nanoseconds, 1_000_000));
    }

    fn sleepMs(ms: u32) void {
        _ = std.c.nanosleep(&.{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) }, null);
    }

    /// Serialized frame write (poll thread + senders share the socket).
    fn writeFrame(self: *Client, data: []const u8) !void {
        const io = ioOf();
        try self.write_mu.lock(io);
        defer self.write_mu.unlock(io);
        try self.sock.sendFrame(data);
    }

    fn nextId(self: *Client, buf: *[24]u8) []const u8 {
        const n = self.id_counter.fetchAdd(1, .monotonic);
        return std.fmt.bufPrint(buf, "{d}.{d}", .{ self.id_epoch, n }) catch unreachable;
    }

    // ---- IQ request/response correlation -------------------------------------

    const Waiter = struct {
        done: bool = false,
        failed: bool = false,
        response: ?[]u8 = null,
    };

    /// Send an IQ frame and block until `poll` delivers `<iq id=…>` (any thread
    /// except the poll thread). Memory: caller frees the returned raw frame.
    fn sendIqWait(self: *Client, id: []const u8, frame: []const u8, timeout_ms: i64) ![]u8 {
        if (!self.connected) return error.NotConnected;
        const io = ioOf();
        const w = try self.allocator.create(Waiter);
        w.* = .{};
        const key = try self.allocator.dupe(u8, id);
        {
            try self.pending_mu.lock(io);
            defer self.pending_mu.unlock(io);
            try self.pending.put(key, w);
        }
        defer {
            self.pending_mu.lock(io) catch {};
            if (self.pending.fetchRemove(id)) |kv| self.allocator.free(kv.key);
            self.pending_mu.unlock(io);
            self.allocator.destroy(w);
        }
        try self.writeFrame(frame);
        const deadline = nowMs() + timeout_ms;
        while (true) {
            try self.pending_mu.lock(io);
            const done = w.done;
            const failed = w.failed;
            const resp = w.response;
            w.response = null;
            self.pending_mu.unlock(io);
            if (failed) return error.NotConnected;
            if (done) return resp orelse error.IqEmpty;
            if (nowMs() > deadline) return error.IqTimeout;
            sleepMs(10);
        }
    }

    /// Poll thread: hand an `<iq type=result|error>` to its waiter. True if consumed.
    fn deliverIqResponse(self: *Client, node: binary.Node, frame: []const u8) bool {
        const id = node.getAttr("id") orelse return false;
        const io = ioOf();
        self.pending_mu.lock(io) catch return false;
        defer self.pending_mu.unlock(io);
        const w = self.pending.get(id) orelse return false;
        w.response = self.allocator.dupe(u8, frame) catch null;
        w.done = true;
        return true;
    }

    fn failPendingIqs(self: *Client) void {
        const io = ioOf();
        self.pending_mu.lock(io) catch return;
        defer self.pending_mu.unlock(io);
        var it = self.pending.valueIterator();
        while (it.next()) |w| w.*.failed = true;
    }

    // ---- keepalive -------------------------------------------------------------

    fn startKeepalive(self: *Client) void {
        if (self.keepalive_thread != null) return;
        self.keepalive_stop.store(false, .release);
        self.keepalive_thread = std.Thread.spawn(.{}, keepaliveLoop, .{self}) catch null;
    }

    fn stopKeepalive(self: *Client) void {
        self.keepalive_stop.store(true, .release);
        if (self.keepalive_thread) |t| {
            t.join();
            self.keepalive_thread = null;
        }
    }

    fn keepaliveLoop(self: *Client) void {
        var waited: u32 = 0;
        while (!self.keepalive_stop.load(.acquire)) {
            sleepMs(250);
            waited += 250;
            if (waited < keepalive_interval_ms) continue;
            waited = 0;
            var id_buf: [24]u8 = undefined;
            const id = self.nextId(&id_buf);
            const frame = stanza.encodePingIq(self.allocator, id) catch continue;
            defer self.allocator.free(frame);
            self.writeFrame(frame) catch return;
        }
    }

    // ---- event loop ---------------------------------------------------------------

    /// Block for the next server frame and turn it into one Event.
    /// Socket errors other than OOM become a disconnect so the runner can retry
    /// (Zig 0.16 maps EHOSTUNREACH/113 on read to UnexpectedError and dumps a
    /// stack; we still treat that as a dropped socket).
    pub fn poll(self: *Client) !Event {
        const frame = self.sock.recvFrameAlloc() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.log.warn("[whatsapp-native] recv failed: {}", .{err});
                return .{ .disconnected = .{ .code = 0, .logged_out = false } };
            },
        };
        defer self.allocator.free(frame);
        var node = try binary.decodeNode(self.allocator, frame);
        defer node.deinit();
        return self.dispatch(node, frame);
    }

    fn dispatch(self: *Client, node: binary.Node, frame: []const u8) !Event {
        const tag = node.tag;
        std.log.info("[whatsapp-native][diag] recv tag={s} id={s} type={s} from={s}", .{ tag, node.getAttr("id") orelse "-", node.getAttr("type") orelse "-", node.getAttr("from") orelse "-" });
        if (std.mem.eql(u8, tag, "iq")) return self.dispatchIq(node, frame);
        if (std.mem.eql(u8, tag, "message")) return self.dispatchMessage(node);
        if (std.mem.eql(u8, tag, "receipt")) {
            const rtype = node.getAttr("type") orelse "";
            std.log.info("[whatsapp-native][diag] recv receipt id={s} type={s} from={s} participant={s}", .{ node.getAttr("id") orelse "-", rtype, node.getAttr("from") orelse "-", node.getAttr("participant") orelse "-" });
            self.ackNode(node);
            if (std.mem.eql(u8, rtype, "retry")) {
                self.handleRetryReceipt(node) catch |err| {
                    std.log.warn("[whatsapp-native] retry receipt handling failed: {}", .{err});
                };
            }
            return .idle;
        }
        if (std.mem.eql(u8, tag, "notification")) {
            self.ackNode(node);
            if (stanza.parseNotificationType(node)) |t| {
                if (std.mem.eql(u8, t, "encrypt")) self.requestPreKeyCount();
            }
            return .idle;
        }
        if (std.mem.eql(u8, tag, "call")) {
            self.ackNode(node);
            return .idle;
        }
        if (std.mem.eql(u8, tag, "success")) return self.handleSuccess(node);
        if (std.mem.eql(u8, tag, "failure") or std.mem.eql(u8, tag, "stream:error")) {
            var code: u32 = stanza.parseStreamErrorCode(node);
            if (code == 0) {
                if (node.getAttr("reason")) |r| code = std.fmt.parseInt(u32, r, 10) catch 0;
            }
            // Forensics: a bare `failure` with no code tells us nothing after the
            // fact. Log attrs + child tags so the next logout verdict is diagnosable.
            var attr_it = node.attrs.iterator();
            while (attr_it.next()) |e| {
                std.log.err("[whatsapp-native] failure attr {s}={s}", .{ e.key_ptr.*, e.value_ptr.* });
            }
            for (node.children()) |*ch| {
                std.log.err("[whatsapp-native] failure child tag={s}", .{ch.tag});
                var ch_it = ch.attrs.iterator();
                while (ch_it.next()) |e| {
                    std.log.err("[whatsapp-native] failure child {s} attr {s}={s}", .{ ch.tag, e.key_ptr.*, e.value_ptr.* });
                }
            }
            self.logged_in = false;
            self.failPendingIqs();
            const conflict = node.getChildByTag("conflict");
            const removed = conflict != null and conflict.?.getAttr("type") != null and std.mem.eql(u8, conflict.?.getAttr("type").?, "device_removed");
            std.log.err("[whatsapp-native] stream failure code={d} removed={} logged_out={}", .{ code, removed, code == 401 or code == 403 or removed });
            return .{ .disconnected = .{ .code = code, .logged_out = code == 401 or code == 403 or removed } };
        }
        if (std.mem.eql(u8, tag, "xmlstreamend")) {
            self.logged_in = false;
            self.failPendingIqs();
            return .{ .disconnected = .{ .code = 0, .logged_out = false } };
        }
        if (std.mem.eql(u8, tag, "ib")) {
            // whatsmeow: `<ib><offline_preview count=N/></ib>` announces a queued
            // backlog; the server will not actually push it until we reply with
            // `<ib><offline_batch count=N/></ib>` requesting delivery. Skipping this leaves
            // the socket connected but permanently deaf to anything queued while offline.
            if (node.getChildByTag("offline_preview")) |_| self.requestOfflineBatch();
        }
        return .idle;
    }

    fn handleSuccess(self: *Client, node: binary.Node) !Event {
        self.logged_in = true;
        if (node.getAttr("lid")) |lid| {
            if (self.paired_lid == null or !std.mem.eql(u8, self.paired_lid.?, lid)) {
                if (self.paired_lid) |s| self.allocator.free(s);
                self.paired_lid = try self.allocator.dupe(u8, lid);
                if (self.store != null) self.persistDevice() catch |err| storeWarn("device lid", err);
            }
        }
        self.startKeepalive();
        self.requestPreKeyCount();
        self.sendActive();
        return .{ .connected = .{ .jid = self.paired_jid orelse "", .lid = self.paired_lid orelse "" } };
    }

    fn dispatchIq(self: *Client, node: binary.Node, frame: []const u8) !Event {
        if (node.getChildByTag("pair-device") != null) {
            const ack = try self.handlePairDeviceIq(node);
            defer self.allocator.free(ack);
            try self.writeFrame(ack);
            return .{ .qr = self.qr_codes.items };
        }
        if (node.getChildByTag("pair-success") != null) {
            var random: [64]u8 = undefined;
            ioOf().random(&random);
            const reply = try self.handlePairSuccessIq(node, random);
            defer self.allocator.free(reply);
            try self.writeFrame(reply);
            return .{ .paired = .{ .jid = self.paired_jid orelse "", .lid = self.paired_lid orelse "" } };
        }
        if (stanza.isServerPing(node)) {
            var id_buf: [24]u8 = undefined;
            const id = node.getAttr("id") orelse self.nextId(&id_buf);
            const reply = try stanza.encodeIqResult(self.allocator, id, node.getAttr("from") orelse stanza.server_jid);
            defer self.allocator.free(reply);
            try self.writeFrame(reply);
            return .idle;
        }
        if (node.getAttr("id")) |id| {
            if (self.prekey_count_iq) |want| {
                if (std.mem.eql(u8, want, id)) {
                    self.allocator.free(want);
                    self.prekey_count_iq = null;
                    const count = stanza.parsePreKeyCount(node) catch 0;
                    if (count < min_prekey_count) self.uploadPreKeys();
                    return .idle;
                }
            }
            if (self.prekey_upload_iq) |want| {
                if (std.mem.eql(u8, want, id)) {
                    self.allocator.free(want);
                    self.prekey_upload_iq = null;
                    const t = node.getAttr("type") orelse "";
                    if (std.mem.eql(u8, t, "result")) {
                        if (self.store) |*s| {
                            if (self.paired_jid) |pj| s.markPreKeysUploaded(pj, self.prekey_upload_up_to) catch |err| storeWarn("mark prekeys uploaded", err);
                        }
                    }
                    return .idle;
                }
            }
        }
        if (self.deliverIqResponse(node, frame)) return .idle;
        if (node.getAttr("type")) |t| {
            if (std.mem.eql(u8, t, "get") or std.mem.eql(u8, t, "set")) {
                // Unhandled server request: answer so it does not repeat.
                if (node.getAttr("id")) |id| {
                    const reply = try stanza.encodeIqResult(self.allocator, id, node.getAttr("from") orelse stanza.server_jid);
                    defer self.allocator.free(reply);
                    try self.writeFrame(reply);
                }
            }
        }
        return .idle;
    }

    fn ackNode(self: *Client, node: binary.Node) void {
        const ack = stanza.encodeAck(self.allocator, node) catch return;
        defer self.allocator.free(ack);
        self.writeFrame(ack) catch {};
    }

    /// whatsmeow `sendPassiveIq('active')`: tell the server this companion is
    /// live so it routes new messages here (not just the offline/history backlog).
    /// Skipping this leaves the socket connected but silently deaf to real-time traffic.
    fn sendActive(self: *Client) void {
        var id_buf: [24]u8 = undefined;
        const id = self.nextId(&id_buf);
        const frame = stanza.encodePassiveIq(self.allocator, id, true) catch return;
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch {};
    }

    /// whatsmeow reply to `<ib><offline_preview/></ib>`: request the server
    /// actually push the queued backlog instead of just announcing it exists.
    fn requestOfflineBatch(self: *Client) void {
        var child = binary.Node.init(self.allocator, "offline_batch");
        defer child.deinit();
        child.attrs.put("count", "100") catch return;
        var ib = binary.Node.init(self.allocator, "ib");
        defer ib.deinit();
        ib.content = .{ .nodes = (&child)[0..1] };
        const frame = binary.marshal(self.allocator, ib) catch return;
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch {};
    }

    // ---- prekeys --------------------------------------------------------------------

    /// Ask the server how many one-time prekeys it still holds (poll thread, async).
    fn requestPreKeyCount(self: *Client) void {
        if (self.store == null or self.paired_jid == null) return;
        if (self.prekey_count_iq != null) return;
        var id_buf: [24]u8 = undefined;
        const id = self.nextId(&id_buf);
        const frame = stanza.encodePreKeyCountIq(self.allocator, id) catch return;
        defer self.allocator.free(frame);
        self.prekey_count_iq = self.allocator.dupe(u8, id) catch return;
        self.writeFrame(frame) catch {
            self.allocator.free(self.prekey_count_iq.?);
            self.prekey_count_iq = null;
        };
    }

    /// Generate + persist a batch of one-time prekeys and upload them (async).
    fn uploadPreKeys(self: *Client) void {
        if (self.prekey_upload_iq != null) return;
        const s = if (self.store) |*st| st else return;
        const own = self.paired_jid orelse return;
        const io = ioOf();
        var recs: [wanted_prekey_count]store_mod.PreKeyRecord = undefined;
        var pubs: [wanted_prekey_count]stanza.PreKeyPub = undefined;
        var next = s.nextPreKeyId(own) catch 1;
        if (next == 0) next = 1;
        var i: usize = 0;
        while (i < recs.len) : (i += 1) {
            const kp = nc.KeyPair.generate(io);
            recs[i] = .{ .id = next + @as(u32, @intCast(i)), .priv_key = kp.priv_key, .pub_key = kp.pub_key, .uploaded = false };
            pubs[i] = .{ .id = recs[i].id, .pub_key = kp.pub_key };
        }
        s.putPreKeys(own, &recs) catch return;
        var id_buf: [24]u8 = undefined;
        const id = self.nextId(&id_buf);
        const frame = stanza.encodePreKeyUpload(
            self.allocator,
            id,
            self.registration_id,
            self.identity.pub_key,
            self.signed_pre_key_id,
            self.signed_pre_key.pub_key,
            self.signed_pre_key_sig,
            &pubs,
        ) catch return;
        defer self.allocator.free(frame);
        self.prekey_upload_up_to = recs[recs.len - 1].id;
        self.prekey_upload_iq = self.allocator.dupe(u8, id) catch return;
        self.writeFrame(frame) catch {
            self.allocator.free(self.prekey_upload_iq.?);
            self.prekey_upload_iq = null;
        };
    }

    // ---- sessions (memory cache over sqlite) -------------------------------------

    /// Signal address used for the session with `sender`: LID when known.
    /// Memory: caller frees.
    fn encryptionJid(self: *Client, wire_jid: []const u8, alt: ?[]const u8) ![]u8 {
        if (jid.isLid(wire_jid)) return self.allocator.dupe(u8, wire_jid);
        if (alt) |a| {
            if (jid.isLid(a)) {
                if (self.store) |*s| s.putLidMap(jid.user(a), jid.user(wire_jid)) catch |err| storeWarn("lid map", err);
                return jid.lidJid(self.allocator, jid.user(a), jid.device(wire_jid));
            }
        }
        if (self.store) |*s| {
            if (s.getLidForPn(jid.user(wire_jid)) catch null) |lid_user| {
                defer self.allocator.free(lid_user);
                return jid.lidJid(self.allocator, lid_user, jid.device(wire_jid));
            }
        }
        return self.allocator.dupe(u8, wire_jid);
    }

    /// Cached session for a Signal id, loading from sqlite on miss. Caller holds state_mu.
    fn sessionFor(self: *Client, sid: []const u8) ?*PeerSession {
        if (self.sessions.getPtr(sid)) |p| return p;
        const s = if (self.store) |*st| st else return null;
        const own = self.paired_jid orelse return null;
        const blob = (s.getSession(own, sid) catch null) orelse return null;
        defer self.allocator.free(blob);
        const sess = signal.Session.deserialize(blob) catch return null;
        const key = self.allocator.dupe(u8, sid) catch return null;
        self.sessions.put(key, .{ .session = sess, .pending_prekey = null }) catch {
            self.allocator.free(key);
            return null;
        };
        return self.sessions.getPtr(sid);
    }

    fn putSession(self: *Client, sid: []const u8, peer: PeerSession) !void {
        if (self.sessions.getPtr(sid)) |p| {
            p.* = peer;
        } else {
            const key = try self.allocator.dupe(u8, sid);
            errdefer self.allocator.free(key);
            try self.sessions.put(key, peer);
        }
        self.persistSession(sid);
    }

    fn persistSession(self: *Client, sid: []const u8) void {
        const s = if (self.store) |*st| st else return;
        const own = self.paired_jid orelse return;
        const peer = self.sessions.getPtr(sid) orelse return;
        const blob = peer.session.serialize(self.allocator) catch return;
        defer self.allocator.free(blob);
        s.putSession(own, sid, blob) catch |err| storeWarn("session", err);
    }

    /// Store writes are best-effort on the message path, but never silent: a lost
    /// row (e.g. FK failure before the device row exists) breaks decrypt after restart.
    fn storeWarn(what: []const u8, err: anyerror) void {
        std.log.warn("[whatsapp-native] store {s} write failed: {}", .{ what, err });
    }

    // ---- retry receipts (whatsmeow retry.go: addRecentMessage / handleRetryReceipt) --

    /// Cache `plaintext` (the raw, pre-DSM-wrap conversation proto) for `msg_id`
    /// so a later `<receipt type=retry>` from any fanned-out device can trigger
    /// an automatic resend. Evicts the oldest entry past `recent_out_cap`.
    /// DM (`sendText`) and group (`sendGroupPlaintext`) sends; group retries
    /// resend as SKDM + skmsg via `resendGroupForRetry`.
    fn rememberOutbound(self: *Client, msg_id: []const u8, dest: []const u8, plaintext: []const u8) !void {
        const io = ioOf();
        try self.recent_out_mu.lock(io);
        defer self.recent_out_mu.unlock(io);
        if (self.recent_out_ring[self.recent_out_ring_pos]) |old_key| {
            if (self.recent_out.fetchRemove(old_key)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit(self.allocator);
            }
        }
        const key = try self.allocator.dupe(u8, msg_id);
        errdefer self.allocator.free(key);
        const d = try self.allocator.dupe(u8, dest);
        errdefer self.allocator.free(d);
        const pt = try self.allocator.dupe(u8, plaintext);
        errdefer self.allocator.free(pt);
        try self.recent_out.put(key, .{ .dest = d, .plaintext = pt });
        self.recent_out_ring[self.recent_out_ring_pos] = key;
        self.recent_out_ring_pos = (self.recent_out_ring_pos + 1) % recent_out_cap;
    }

    const RecentOutCopy = struct {
        dest: []u8,
        plaintext: []u8,

        fn deinit(self: RecentOutCopy, allocator: std.mem.Allocator) void {
            allocator.free(self.dest);
            allocator.free(self.plaintext);
        }
    };

    /// Copies out the cached plaintext for `msg_id` and bumps its retry
    /// counter, capping automatic resends at `max_auto_retries` so a
    /// persistently broken device session cannot trigger an unbounded loop.
    fn takeRecentOutboundForRetry(self: *Client, msg_id: []const u8) !?RecentOutCopy {
        const io = ioOf();
        try self.recent_out_mu.lock(io);
        defer self.recent_out_mu.unlock(io);
        const e = self.recent_out.getPtr(msg_id) orelse return null;
        e.retries += 1;
        if (e.retries > max_auto_retries) return error.TooManyRetries;
        return .{
            .dest = try self.allocator.dupe(u8, e.dest),
            .plaintext = try self.allocator.dupe(u8, e.plaintext),
        };
    }

    /// Best-effort: drop the cached + persisted session so the next encrypt
    /// forces a fresh handshake (used when a device reports it can't decrypt).
    fn dropSession(self: *Client, enc_jid: []const u8) void {
        const io = ioOf();
        self.state_mu.lock(io) catch return;
        defer self.state_mu.unlock(io);
        const sid = jid.signalId(self.allocator, enc_jid) catch return;
        defer self.allocator.free(sid);
        if (self.sessions.fetchRemove(sid)) |kv| self.allocator.free(kv.key);
        if (self.store) |*s| {
            if (self.paired_jid) |own| s.deleteSession(own, sid) catch |err| storeWarn("delete session", err);
        }
    }

    /// Retry-resend workers block on `sendIqWait`/`state_mu`; give them a
    /// moment to notice a disconnect (via `failPendingIqs`, called just before
    /// this) and exit before the caller may `deinit` this Client out from
    /// under a still-running detached thread.
    fn waitRetryWorkersIdle(self: *Client) void {
        var waited_ms: u32 = 0;
        while (self.retry_workers_active.load(.acquire) != 0 and waited_ms < 5000) {
            sleepMs(20);
            waited_ms += 20;
        }
    }

    /// Heap-owned handoff to the detached retry-resend worker thread.
    const RetryWork = struct {
        client: *Client,
        from_device: []u8,
        msg_id: []u8,
        dest: []u8,
        plaintext: []u8,

        fn deinit(self: *const RetryWork, allocator: std.mem.Allocator) void {
            allocator.free(self.from_device);
            allocator.free(self.msg_id);
            allocator.free(self.dest);
            allocator.free(self.plaintext);
        }
    };

    /// Inbound `<receipt type=retry>`: a device we fanned out to (including our
    /// own phone) couldn't decrypt what we sent and is asking for a resend.
    /// Looks up the cached plaintext and hands off to a detached worker thread
    /// that drops the stale session, re-establishes it via a fresh prekey
    /// fetch, and resends to that one device with the same message id
    /// (whatsmeow handleRetryReceipt). Must not run on the poll thread itself:
    /// the prekey fetch blocks on `sendIqWait`, whose response only `poll`
    /// (this very call stack) can deliver. Group retries use the `participant`
    /// attr as the target device.
    fn handleRetryReceipt(self: *Client, node: binary.Node) !void {
        const from = node.getAttr("from") orelse return error.MissingFrom;
        const participant = node.getAttr("participant");
        const retry_device = participant orelse from;
        const msg_id = node.getAttr("id") orelse return error.MissingId;
        if (node.getChildByTag("retry") == null) return error.MissingRetryChild;

        const cached = self.takeRecentOutboundForRetry(msg_id) catch |err| {
            std.log.warn("[whatsapp-native] dropping retry for {s} from {s}: {}", .{ msg_id, retry_device, err });
            return;
        } orelse {
            std.log.warn("[whatsapp-native] retry receipt for unknown/expired message id={s} from={s}", .{ msg_id, retry_device });
            return;
        };

        const work = try self.allocator.create(RetryWork);
        work.* = .{
            .client = self,
            .from_device = try self.allocator.dupe(u8, retry_device),
            .msg_id = try self.allocator.dupe(u8, msg_id),
            .dest = cached.dest,
            .plaintext = cached.plaintext,
        };
        _ = self.retry_workers_active.fetchAdd(1, .monotonic);
        const t = std.Thread.spawn(.{}, retryWorkerEntry, .{work}) catch |err| {
            _ = self.retry_workers_active.fetchSub(1, .monotonic);
            std.log.warn("[whatsapp-native] spawn retry worker for {s} failed: {}", .{ retry_device, err });
            work.deinit(self.allocator);
            self.allocator.destroy(work);
            return;
        };
        t.detach();
    }

    fn retryWorkerEntry(work: *RetryWork) void {
        const client = work.client;
        const alloc = client.allocator;
        defer {
            work.deinit(alloc);
            alloc.destroy(work);
            _ = client.retry_workers_active.fetchSub(1, .release);
        }
        client.resendForRetry(work) catch |err| {
            std.log.warn("[whatsapp-native] retry resend to {s} for {s} failed: {}", .{ work.from_device, work.msg_id, err });
        };
    }

    /// Runs on the detached worker thread spawned by `handleRetryReceipt`.
    fn resendForRetry(self: *Client, work: *RetryWork) !void {
        if (!self.isConnected()) return error.NotConnected;
        if (std.mem.eql(u8, jid.server(work.dest), "g.us")) {
            return self.resendGroupForRetry(work);
        }
        const own = self.paired_jid orelse return error.NotPaired;
        const own_lid = self.paired_lid;

        const enc_jid = try self.encryptionJid(work.from_device, null);
        defer self.allocator.free(enc_jid);

        self.dropSession(enc_jid);
        try self.fetchAndProcessPreKeys(&.{enc_jid});

        const is_own_user = std.mem.eql(u8, jid.user(work.from_device), jid.user(own)) or
            (own_lid != null and std.mem.eql(u8, jid.user(work.from_device), jid.user(own_lid.?)));
        var plain_owned: ?[]u8 = null;
        defer if (plain_owned) |p| self.allocator.free(p);
        const plain: []const u8 = if (is_own_user) blk: {
            const wrapped = try proto.Message.encodeDeviceSent(self.allocator, work.dest, work.plaintext);
            plain_owned = wrapped;
            break :blk wrapped;
        } else work.plaintext;

        const enc = try self.encryptForDevice(enc_jid, plain);
        defer self.allocator.free(enc.ciphertext);

        const frame = try stanza.encodeRetryResend(
            self.allocator,
            work.from_device,
            work.msg_id,
            enc.enc_type,
            enc.ciphertext,
            if (enc.enc_type == .pkmsg) self.adv_account else null,
        );
        defer self.allocator.free(frame);
        try self.writeFrame(frame);
        std.log.info("[whatsapp-native][diag] retry resend id={s} to={s} device={s} enc_type={s}", .{ work.msg_id, work.dest, work.from_device, enc.enc_type.attr() });
    }

    /// Sender-key retry: SKDM to the failing device + skmsg of the cached
    /// group plaintext (whatsmeow handleRetryReceipt for g.us). Pairwise
    /// `encodeRetryResend` cannot decrypt on group devices.
    fn resendGroupForRetry(self: *Client, work: *RetryWork) !void {
        if (!self.isConnected()) return error.NotConnected;
        const alloc = self.allocator;
        const io = ioOf();
        const own = self.paired_jid orelse return error.NotPaired;
        const own_lid = self.paired_lid;

        const enc_jid = try self.encryptionJid(work.from_device, null);
        defer alloc.free(enc_jid);

        self.dropSession(enc_jid);
        try self.fetchAndProcessPreKeys(&.{enc_jid});

        const skdm_plain = blk: {
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            const rec = try self.senderKeyRecordPtr(work.dest, own);
            const axolotl = try sg.create(alloc, rec, io);
            defer alloc.free(axolotl);
            self.saveSenderKeyRecord(work.dest, own, rec);
            break :blk try proto.Message.encodeSenderKeyDistribution(alloc, work.dest, axolotl);
        };
        defer alloc.free(skdm_plain);

        const enc = try self.encryptForDevice(enc_jid, skdm_plain);
        defer alloc.free(enc.ciphertext);
        const skdm_targets = [1]stanza.Participant{.{
            .jid = enc_jid,
            .enc_type = enc.enc_type,
            .ciphertext = enc.ciphertext,
        }};

        const padded = try proto.padMessageRandom(alloc, work.plaintext, io);
        defer alloc.free(padded);
        const skmsg = blk: {
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            const rec = try self.senderKeyRecordPtr(work.dest, own);
            const ct = try sg.encrypt(alloc, rec, padded, io);
            self.saveSenderKeyRecord(work.dest, own, rec);
            break :blk ct;
        };
        defer alloc.free(skmsg);

        var phash_devs: std.ArrayList([]const u8) = .empty;
        defer phash_devs.deinit(alloc);
        if (own_lid) |ol| try phash_devs.append(alloc, ol);
        var own_dev_buf: [128]u8 = undefined;
        const own_dev = std.fmt.bufPrint(&own_dev_buf, "{s}:{d}@{s}", .{
            jid.user(own), jid.device(own), jid.server(own),
        }) catch return error.JidTooLong;
        try phash_devs.append(alloc, own_dev);
        try phash_devs.append(alloc, work.from_device);

        const addressing_mode: []const u8 = if (jid.isLid(work.from_device)) "lid" else "";
        var node = try groups_mod.buildGroupMessageNode(alloc, .{
            .id = work.msg_id,
            .to_group = work.dest,
            .own_jid = own,
            .own_lid = own_lid,
            .addressing_mode = addressing_mode,
            .participants_device_jids = phash_devs.items,
            .skmsg_ciphertext = skmsg,
            .skdm_payload = skdm_plain,
            .skdm_targets = &skdm_targets,
            .device_identity = if (enc.enc_type == .pkmsg) self.adv_account else null,
        });
        defer node.deinit();
        const frame = try binary.marshal(alloc, node);
        defer alloc.free(frame);
        try self.writeFrame(frame);
        std.log.info("[whatsapp-native][diag] group retry resend id={s} to={s} device={s} enc_type={s}", .{
            work.msg_id, work.dest, work.from_device, enc.enc_type.attr(),
        });
    }

    // ---- group sender keys (signal_groups over sqlite) ---------------------------
    /// Caller holds `state_mu`. Memory-cached over sqlite, mirroring `sessions`:
    /// the returned record is owned by the cache and mutated in place.
    fn senderKeyRecordPtr(self: *Client, group: []const u8, sender: []const u8) !*sg.SenderKeyRecord {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ group, sender });
        errdefer self.allocator.free(key);
        if (self.sender_key_cache.get(key)) |p| {
            self.allocator.free(key);
            return p;
        }
        const rec = try self.allocator.create(sg.SenderKeyRecord);
        errdefer self.allocator.destroy(rec);
        rec.* = blk: {
            if (self.store) |*s| {
                if (self.paired_jid) |own| {
                    if (s.getSenderKey(own, group, sender) catch null) |blob| {
                        defer self.allocator.free(blob);
                        break :blk try sg.SenderKeyRecord.deserialize(self.allocator, blob);
                    }
                }
            }
            break :blk sg.SenderKeyRecord.init(self.allocator);
        };
        try self.sender_key_cache.put(key, rec);
        return rec;
    }

    /// Caller holds `state_mu`. Best-effort like every other message-path write.
    fn saveSenderKeyRecord(self: *Client, group: []const u8, sender: []const u8, record: *const sg.SenderKeyRecord) void {
        const s = if (self.store) |*st| st else return;
        const own = self.paired_jid orelse return;
        const blob = record.serialize(self.allocator) catch return;
        defer self.allocator.free(blob);
        s.putSenderKey(own, group, sender, blob) catch |err| storeWarn("sender key", err);
    }

    /// Adopt a peer's SenderKeyDistributionMessage into the (group, sender) record.
    fn processSenderKeyDistribution(self: *Client, chat: []const u8, sender: []const u8, group_id: []const u8, axolotl: []const u8) !void {
        const group = if (group_id.len > 0) group_id else chat;
        const io = ioOf();
        try self.state_mu.lock(io);
        defer self.state_mu.unlock(io);
        const record = try self.senderKeyRecordPtr(group, sender);
        try sg.processDistribution(record, axolotl);
        self.saveSenderKeyRecord(group, sender, record);
    }

    /// Group-decrypt an `<enc type=skmsg>` body; returns unpadded plaintext.
    /// WhatsApp web persists the ratchet only after a successful decrypt.
    fn decryptGroup(self: *Client, chat: []const u8, sender: []const u8, skm: []const u8, version: u32) ![]u8 {
        const io = ioOf();
        try self.state_mu.lock(io);
        defer self.state_mu.unlock(io);
        const record = try self.senderKeyRecordPtr(chat, sender);
        const padded = try sg.decrypt(self.allocator, record, skm);
        defer self.allocator.free(padded);
        self.saveSenderKeyRecord(chat, sender, record);
        return unpadEnc(self.allocator, padded, version);
    }
    // ---- inbound messages --------------------------------------------------------------

    fn dispatchMessage(self: *Client, node: binary.Node) !Event {
        const info = stanza.parseMessageInfo(self.allocator, node, self.paired_jid, self.paired_lid) catch {
            self.ackNode(node);
            return .idle;
        };
        defer self.allocator.free(info.encs);
        if (info.encs.len == 0) {
            self.ackNode(node);

            return .idle;
        }
        const enc_jid = try self.encryptionJid(info.sender, info.sender_alt);
        defer self.allocator.free(enc_jid);

        var text: ?[]u8 = null;
        var chat_override: ?[]u8 = null;
        defer if (chat_override) |c| self.allocator.free(c);
        var mentions: std.ArrayList([]u8) = .empty;
        defer {
            for (mentions.items) |m| self.allocator.free(m);
            mentions.deinit(self.allocator);
        }
        var quoted_stanza_id: ?[]u8 = null;
        var quoted_participant: ?[]u8 = null;
        var quoted_text: ?[]u8 = null;
        defer {
            if (quoted_stanza_id) |s| self.allocator.free(s);
            if (quoted_participant) |s| self.allocator.free(s);
            if (quoted_text) |s| self.allocator.free(s);
        }
        var location: ?proto.Geo = null;
        var kind: InboundMessage.Kind = .text;
        var media_ref: ?InboundMessage.MediaAttachment = null;
        var decrypted_any = false;
        var real_failure = false;
        for (info.encs) |enc| {
            const plain: []u8 = switch (enc.enc_type) {
                .pkmsg, .msg => self.decryptDm(enc_jid, enc) catch |err| {
                    if (err == error.DuplicateMessage) {
                        // Already decrypted this exact ratchet message once; the sender is
                        // just retransmitting because our receipt hasn't reached it yet.
                        // Asking for a retry here only teaches it to keep resending forever.
                        continue;
                    }
                    std.log.warn("[whatsapp-native] decrypt {s} from {s} failed: {}", .{ info.id, info.sender, err });
                    real_failure = true;
                    continue;
                },
                .skmsg => if (info.is_group)
                    self.decryptGroup(info.chat, info.sender, enc.ciphertext, enc.version) catch |err| {
                        if (err == error.OldCounter) {
                            // Already decrypted this exact sender-key iteration once; a
                            // group fanout retransmit, not a fresh message. Retrying only
                            // teaches the sender to keep resending forever.
                            continue;
                        }
                        std.log.warn("[whatsapp-native] group decrypt {s} from {s} failed: {}", .{ info.id, info.sender, err });
                        real_failure = true;
                        continue;
                    }
                else
                    continue,
            };
            defer self.allocator.free(plain);
            decrypted_any = true;
            const msg = proto.Message.decode(plain) catch continue;
            if (msg.sender_key_distribution) |skd| {
                self.processSenderKeyDistribution(info.chat, info.sender, skd.group_id, skd.axolotl) catch |err| {
                    std.log.warn("[whatsapp-native] skdm from {s} failed: {}", .{ info.sender, err });
                };
            }
            captureMedia(self.allocator, &media_ref, msg.media) catch {};
            try takeMentions(self.allocator, msg, &mentions);
            try takeQuote(self.allocator, msg, &quoted_stanza_id, &quoted_participant, &quoted_text);
            applyKind(msg, &kind);
            try takeTarget(self.allocator, msg, kind, &quoted_stanza_id, &quoted_participant);
            if (msg.location) |loc| location = loc;
            if (msg.device_sent) |ds| {
                const inner = proto.Message.decode(ds.message) catch continue;
                captureMedia(self.allocator, &media_ref, inner.media) catch {};
                try takeMentions(self.allocator, inner, &mentions);
                try takeQuote(self.allocator, inner, &quoted_stanza_id, &quoted_participant, &quoted_text);
                applyKind(inner, &kind);
                try takeTarget(self.allocator, inner, kind, &quoted_stanza_id, &quoted_participant);
                if (inner.location) |loc| location = loc;
                if (inner.reaction) |rxn| {
                    if (rxn.text.len > 0) {
                        if (text) |old| self.allocator.free(old);
                        text = try self.allocator.dupe(u8, rxn.text);
                    }
                    if (chat_override) |old| self.allocator.free(old);
                    chat_override = try self.allocator.dupe(u8, ds.destination_jid);
                    continue;
                }
                if (inner.text()) |t| {
                    if (text) |old| self.allocator.free(old);
                    text = try self.allocator.dupe(u8, t);
                    if (chat_override) |old| self.allocator.free(old);
                    chat_override = try self.allocator.dupe(u8, ds.destination_jid);
                }
                continue;
            }
            if (msg.reaction) |rxn| {
                if (rxn.text.len > 0) {
                    if (text) |old| self.allocator.free(old);
                    text = try self.allocator.dupe(u8, rxn.text);
                }
                continue;
            }
            if (msg.text()) |t| {
                if (text) |old| self.allocator.free(old);
                text = try self.allocator.dupe(u8, t);
            }
        }
        if (real_failure and !decrypted_any) {
            self.sendRetryReceipt(node, info);
            self.ackNode(node);
            if (text) |t| self.allocator.free(t);
            if (media_ref) |*m| m.deinit(self.allocator);
            return .idle;
        }
        if (!decrypted_any) {
            // Every enc was a duplicate (or produced nothing new). We already fully
            // processed this message once; send the same delivery receipt a fresh
            // decrypt would get, or the sender's server keeps redelivering it forever.
            self.sendMessageReceipt(node, info);
            if (text) |t| self.allocator.free(t);
            if (media_ref) |*m| m.deinit(self.allocator);
            return .idle;
        }
        self.sendMessageReceipt(node, info);
        const body = text orelse try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(body);
        if (media_ref == null and body.len == 0 and location == null and kind == .text) {
            self.allocator.free(body);
            return .idle;
        }
        const owned_qid = quoted_stanza_id;
        const owned_qp = quoted_participant;
        const owned_qt = quoted_text;
        quoted_stanza_id = null;
        quoted_participant = null;
        quoted_text = null;
        errdefer {
            if (owned_qid) |s| self.allocator.free(s);
            if (owned_qp) |s| self.allocator.free(s);
            if (owned_qt) |s| self.allocator.free(s);
        }
        const chat_src = chat_override orelse info.chat;
        const sender_pn: ?[]u8 = blk: {
            if (jid.isPn(info.sender)) break :blk try self.allocator.dupe(u8, jid.user(info.sender));
            if (info.sender_alt) |a| {
                if (jid.isPn(a)) break :blk try self.allocator.dupe(u8, jid.user(a));
            }
            if (self.store) |*s| {
                if (s.getPnForLid(jid.user(info.sender)) catch null) |pn| break :blk pn;
            }
            break :blk null;
        };
        rememberInbound(self, info.id, chat_src, info.sender, info.from_me);
        return .{ .message = .{
            .allocator = self.allocator,
            .id = try self.allocator.dupe(u8, info.id),
            .chat = try self.allocator.dupe(u8, chat_src),
            .sender = try self.allocator.dupe(u8, info.sender),
            .sender_pn = sender_pn,
            .push_name = if (info.push_name) |p| try self.allocator.dupe(u8, p) else null,
            .text = body,
            .media = media_ref,
            .mentioned_jids = try mentions.toOwnedSlice(self.allocator),
            .quoted_stanza_id = owned_qid,
            .quoted_participant = owned_qp,
            .quoted_text = owned_qt,
            .location = location,
            .kind = kind,
            .from_me = info.from_me,
            .timestamp = info.timestamp,
            .is_group = info.is_group,
        } };
    }

    /// Signal-decrypt one `<enc type=pkmsg|msg>` from `enc_jid`. Memory: caller frees.
    fn decryptDm(self: *Client, enc_jid: []const u8, enc: stanza.EncPayload) ![]u8 {
        const io = ioOf();
        try self.state_mu.lock(io);
        defer self.state_mu.unlock(io);
        const sid = try jid.signalId(self.allocator, enc_jid);
        defer self.allocator.free(sid);
        var padded: []u8 = undefined;
        switch (enc.enc_type) {
            .pkmsg => {
                const parsed = try signal.decodePreKeyMessage(enc.ciphertext);
                padded = blk: {
                    // Existing session with the same base key: the peer is retransmitting
                    // its PreKey message (it has not seen a reply yet). Its one-time prekey
                    // was consumed on first receipt, so check this before the prekey lookup.
                    if (self.sessionFor(sid)) |existing| {
                        if (existing.session.decrypt(self.allocator, parsed.whisper)) |pt| {
                            self.persistSession(sid);
                            break :blk pt;
                        } else |retry_err| {
                            // Genuine replay (already decrypted this exact ratchet message):
                            // the one-time prekey is long gone, so X3DH would only fail with
                            // UnknownOneTimePreKey. Surface the real reason instead.
                            if (retry_err == error.DuplicateMessage) return retry_err;
                            std.log.warn("[whatsapp-native] pkmsg retransmit decrypt via existing session for sid={s} failed: {} (prekey_id={d}, falling back to X3DH)", .{ sid, retry_err, parsed.header.prekey_id });
                        }
                    }
                    var keys = self.localKeys();
                    if (parsed.header.prekey_id != 0) {
                        const s = if (self.store) |*st| st else return error.NoStore;
                        const own = self.paired_jid orelse return error.NotPaired;
                        const rec = (try s.getPreKey(own, parsed.header.prekey_id)) orelse {
                            const have = s.countPreKeys(own) catch 0;
                            std.log.warn("[whatsapp-native] prekey id={d} not found locally for own={s} (have {d} prekeys stored, signed_prekey_id={d})", .{ parsed.header.prekey_id, own, have, self.signed_pre_key_id });
                            return error.UnknownOneTimePreKey;
                        };
                        keys.one_time = .{ .id = rec.id, .pair = nc.KeyPair.fromPrivate(rec.priv_key) };
                    }
                    var sess = try signal.acceptPreKey(
                        keys,
                        parsed.header.identity_pub,
                        parsed.header.base_pub,
                        parsed.header.signed_prekey_id,
                        parsed.header.prekey_id,
                    );
                    const pt = try sess.decrypt(self.allocator, parsed.whisper);
                    errdefer self.allocator.free(pt);
                    try self.putSession(sid, .{ .session = sess, .pending_prekey = null });
                    if (self.store) |*s| {
                        if (self.paired_jid) |own| {
                            s.putIdentity(own, sid, parsed.header.identity_pub) catch |err| storeWarn("identity", err);
                            if (parsed.header.prekey_id != 0) s.removePreKey(own, parsed.header.prekey_id) catch |err| storeWarn("remove prekey", err);
                            const left = s.countPreKeys(own) catch wanted_prekey_count;
                            if (left < min_prekey_count) self.requestPreKeyCount();
                        }
                    }
                    break :blk pt;
                };
            },
            .msg => {
                const peer = self.sessionFor(sid) orelse return error.NoSession;
                padded = try peer.session.decrypt(self.allocator, enc.ciphertext);
                // libsignal: a message from the peer acknowledges our PreKey message.
                peer.pending_prekey = null;
                self.persistSession(sid);
            },
            .skmsg => return error.NotDirect,
        }
        defer self.allocator.free(padded);
        return unpadEnc(self.allocator, padded, enc.version);
    }

    fn sendMessageReceipt(self: *Client, node: binary.Node, info: stanza.MessageInfo) void {
        const to = node.getAttr("from") orelse return;
        const rtype: ?[]const u8 = if (info.from_me) "sender" else "inactive";
        const frame = stanza.encodeReceipt(self.allocator, to, info.id, rtype, node.getAttr("participant"), null) catch |err| {
            std.log.warn("[whatsapp-native] receipt encode failed for id={s}: {}", .{ info.id, err });
            return;
        };
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch |err| {
            std.log.warn("[whatsapp-native] receipt write failed for id={s} to={s}: {}", .{ info.id, to, err });
        };
    }

    /// whatsmeow sendRetryReceipt: ask the sender to re-encrypt with a fresh session.
    fn sendRetryReceipt(self: *Client, node: binary.Node, info: stanza.MessageInfo) void {
        const count = self.bumpRetry(info.id);
        if (count == 0 or count >= 5) return;
        const from = node.getAttr("from") orelse return;
        var one_time: ?stanza.PreKeyPub = null;
        // Offer a fresh one-time prekey unconditionally (not just after the 2nd
        // failure like whatsmeow's default): a peer sending genuinely new messages
        // rather than retrying the same one never reaches count>1, so a stale
        // cached prekey bundle on their end would otherwise never get corrected.
        {
            if (self.store) |*s| {
                if (self.paired_jid) |own| {
                    const io = ioOf();
                    const kp = nc.KeyPair.generate(io);
                    const id = s.nextPreKeyId(own) catch 1;
                    const rec = store_mod.PreKeyRecord{ .id = id, .priv_key = kp.priv_key, .pub_key = kp.pub_key, .uploaded = true };
                    s.putPreKeys(own, &.{rec}) catch {};
                    one_time = .{ .id = id, .pub_key = kp.pub_key };
                }
            }
        }
        const frame = stanza.encodeRetryReceipt(
            self.allocator,
            from,
            info.id,
            node.getAttr("participant"),
            node.getAttr("t") orelse "0",
            count,
            self.registration_id,
            if (one_time != null) .{
                .identity_pub = self.identity.pub_key,
                .one_time = one_time.?,
                .signed_id = self.signed_pre_key_id,
                .signed_pub = self.signed_pre_key.pub_key,
                .signed_sig = self.signed_pre_key_sig,
                .device_identity = self.adv_account orelse "",
            } else null,
        ) catch return;
        defer self.allocator.free(frame);
        self.writeFrame(frame) catch {};
    }

    fn bumpRetry(self: *Client, id: []const u8) u32 {
        if (self.retries.getPtr(id)) |c| {
            c.* += 1;
            return c.*;
        }
        if (self.retries.count() >= 256) {
            var it = self.retries.iterator();
            if (it.next()) |kv| {
                const k = kv.key_ptr.*;
                _ = self.retries.remove(k);
                self.allocator.free(k);
            }
        }
        const key = self.allocator.dupe(u8, id) catch return 0;
        self.retries.put(key, 1) catch {
            self.allocator.free(key);
            return 0;
        };
        return 1;
    }

    // ---- outbound ---------------------------------------------------------------------
    const LidDmDest = struct {
        dest: []const u8,
        dest_owned: ?[]u8 = null,
        pn_owned: ?[]u8 = null,

        fn deinit(self: LidDmDest, alloc: std.mem.Allocator) void {
            if (self.dest_owned) |p| alloc.free(p);
            if (self.pn_owned) |p| alloc.free(p);
        }
    };

    /// whatsmeow SendMessage (2026): 1:1 DMs are addressed to the recipient LID
    /// with `peer_recipient_pn` = their phone JID. Without this the server ACKs
    /// but LID-keyed clients (the phone) drop the stanza.
    fn lidDmDestination(self: *Client, to: []const u8) !LidDmDest {
        const alloc = self.allocator;
        if (jid.isPn(to)) {
            if (self.store) |*s| {
                if (s.getLidForPn(jid.user(to)) catch null) |lid_user| {
                    defer alloc.free(lid_user);
                    const dest_owned = try jid.lidJid(alloc, lid_user, 0);
                    errdefer alloc.free(dest_owned);
                    const pn_owned = try jid.pnJid(alloc, jid.user(to), 0);
                    return .{ .dest = dest_owned, .dest_owned = dest_owned, .pn_owned = pn_owned };
                }
            }
            return .{ .dest = to };
        }
        if (jid.isLid(to)) {
            const dest_owned = try jid.lidJid(alloc, jid.user(to), 0);
            errdefer alloc.free(dest_owned);
            var pn_owned: ?[]u8 = null;
            if (self.store) |*s| {
                if (s.getPnForLid(jid.user(to)) catch null) |pn_user| {
                    defer alloc.free(pn_user);
                    pn_owned = try jid.pnJid(alloc, pn_user, 0);
                }
            }
            return .{ .dest = dest_owned, .dest_owned = dest_owned, .pn_owned = pn_owned };
        }
        return .{ .dest = to };
    }

    /// Send a text to a DM chat: usync devices for the peer and ourselves, fetch
    /// prekeys for devices without sessions, encrypt per device (DeviceSentMessage
    /// for our own devices), one `<message>` with `<participants>`.
    /// Thread-safe (not from the poll thread). Memory: caller frees the message id.
    pub fn sendText(self: *Client, to: []const u8, text: []const u8) ![]u8 {
        return self.sendTextWith(to, text, .{});
    }

    pub fn sendTextWith(self: *Client, to: []const u8, text: []const u8, opts: proto.Message.TextOpts) ![]u8 {
        const msg_plain = try proto.Message.encodeTextWith(self.allocator, text, opts);
        defer self.allocator.free(msg_plain);
        return self.sendPlaintext(to, msg_plain);
    }

    /// Encrypt and send a pre-encoded protobuf Message to a DM or group JID.
    /// Memory: caller frees the message id.
    pub fn sendPlaintext(self: *Client, to: []const u8, msg_plain: []const u8) ![]u8 {
        return self.sendPlaintextWithEdit(to, msg_plain, null);
    }

    fn sendPlaintextWithEdit(self: *Client, to: []const u8, msg_plain: []const u8, edit: ?[]const u8) ![]u8 {
        if (!self.isConnected()) return error.NotConnected;
        if (std.mem.eql(u8, jid.server(to), "g.us")) return self.sendGroupPlaintext(to, msg_plain, edit);
        return self.sendDmPlaintext(to, msg_plain, edit);
    }

    fn sendDmPlaintext(self: *Client, to: []const u8, msg_plain: []const u8, edit: ?[]const u8) ![]u8 {
        const own = self.paired_jid orelse return error.NotPaired;
        const own_lid = self.paired_lid;
        const alloc = self.allocator;

        const dm = try self.lidDmDestination(to);
        defer dm.deinit(alloc);
        const dest = dm.dest;
        std.log.info("[whatsapp-native][diag] sendText dest={s} peer_pn={s} orig={s}", .{
            dest,
            dm.pn_owned orelse "-",
            to,
        });

        // 1. devices — usync dest + own. LID dest uses own LID so device 0 (phone)
        // is included as `…@lid` rather than skipped/misaddressed as PN.
        const dest_user = try jid.format(alloc, jid.user(dest), 0, jid.server(dest));
        defer alloc.free(dest_user);
        const own_sync = if (jid.isLid(dest) and own_lid != null)
            try jid.format(alloc, jid.user(own_lid.?), 0, jid.server(own_lid.?))
        else
            try jid.format(alloc, jid.user(own), 0, jid.server(own));
        defer alloc.free(own_sync);
        const to_is_self = std.mem.eql(u8, jid.user(to), jid.user(own)) or
            (own_lid != null and std.mem.eql(u8, jid.user(to), jid.user(own_lid.?))) or
            std.mem.eql(u8, jid.user(dest_user), jid.user(own_sync));
        var users_buf: [2][]const u8 = .{ dest_user, own_sync };
        const users: []const []const u8 = if (to_is_self) users_buf[0..1] else users_buf[0..2];
        var id_buf: [24]u8 = undefined;
        const usync_id = self.nextId(&id_buf);
        var sid_buf: [24]u8 = undefined;
        const sid = self.nextId(&sid_buf);
        const usync_frame = try stanza.encodeUsyncDevices(alloc, usync_id, sid, users);
        defer alloc.free(usync_frame);
        const usync_resp = try self.sendIqWait(usync_id, usync_frame, iq_timeout_ms);
        defer alloc.free(usync_resp);
        var usync_node = try binary.decodeNode(alloc, usync_resp);
        defer usync_node.deinit();
        const entries = try stanza.parseUsyncDevices(alloc, usync_node);
        defer alloc.free(entries);

        var devices: std.ArrayList([]u8) = .empty;
        defer {
            for (devices.items) |d| alloc.free(d);
            devices.deinit(alloc);
        }
        for (entries) |e| {
            const dj = try jid.format(alloc, jid.user(e.user_jid), e.device, jid.server(e.user_jid));
            if (std.mem.eql(u8, dj, own) or (own_lid != null and std.mem.eql(u8, dj, own_lid.?))) {
                alloc.free(dj);
                continue;
            }
            try devices.append(alloc, dj);
        }
        if (devices.items.len == 0) return error.NoDevices;
        for (devices.items) |dj| std.log.info("[whatsapp-native][diag] sendText target device={s}", .{dj});

        // 2. plaintexts
        const dsm_plain = try proto.Message.encodeDeviceSent(alloc, dest, msg_plain);
        defer alloc.free(dsm_plain);

        // 3. encryption ids + prekey fetch for missing sessions
        var enc_ids: std.ArrayList([]u8) = .empty;
        defer {
            for (enc_ids.items) |d| alloc.free(d);
            enc_ids.deinit(alloc);
        }
        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(alloc);
        {
            const io = ioOf();
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            for (devices.items) |dj| {
                const ej = try self.encryptionJid(dj, null);
                try enc_ids.append(alloc, ej);
                const s = try jid.signalId(alloc, ej);
                defer alloc.free(s);
                if (self.sessionFor(s) == null) try missing.append(alloc, ej);
            }
        }
        if (missing.items.len > 0) try self.fetchAndProcessPreKeys(missing.items);

        // 4. encrypt per device
        var parts: std.ArrayList(stanza.Participant) = .empty;
        defer {
            for (parts.items) |part| alloc.free(part.ciphertext);
            parts.deinit(alloc);
        }
        var any_prekey = false;
        for (devices.items, 0..) |dj, i| {
            const is_own_user = std.mem.eql(u8, jid.user(dj), jid.user(own)) or (own_lid != null and std.mem.eql(u8, jid.user(dj), jid.user(own_lid.?)));
            const plain = if (is_own_user) dsm_plain else msg_plain;
            const enc = self.encryptForDevice(enc_ids.items[i], plain) catch |err| {
                std.log.warn("[whatsapp-native] encrypt for {s} failed: {}", .{ dj, err });
                continue;
            };
            if (enc.enc_type == .pkmsg) any_prekey = true;
            try parts.append(alloc, .{ .jid = dj, .enc_type = enc.enc_type, .ciphertext = enc.ciphertext });
        }
        if (parts.items.len == 0) return error.NoSession;

        // 5. send
        var rnd: [8]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&rnd);
        const msg_id = std.fmt.bytesToHex(rnd, .upper);
        const frame = try stanza.encodeMessageMulti(alloc, dest, &msg_id, parts.items, if (any_prekey) self.adv_account else null, dm.pn_owned, edit);
        defer alloc.free(frame);
        std.log.info("[whatsapp-native][diag] sendText frame to={s} dest={s} peer_pn={s} id={s} any_prekey={} devices={d} parts={d}", .{ to, dest, dm.pn_owned orelse "-", msg_id, any_prekey, devices.items.len, parts.items.len });
        try self.writeFrame(frame);
        self.rememberOutbound(&msg_id, dest, msg_plain) catch |err| storeWarn("remember outbound", err);
        return alloc.dupe(u8, &msg_id);
    }

    const GroupSend = struct { frame: []u8, id: []u8 };

    /// Build (not send) a group text message: SKDM fanout + skmsg over the group
    /// sender key. `device_jids` is the full participant device list — own devices
    /// are skipped for sessions/encryption (whatsmeow fanout) but counted in phash.
    /// Memory: caller frees both fields.
    pub fn buildGroupText(self: *Client, to: []const u8, addressing_mode: []const u8, device_jids: []const []const u8, text: []const u8) !GroupSend {
        const msg_plain = try proto.Message.encodeTextWith(self.allocator, text, .{});
        defer self.allocator.free(msg_plain);
        return self.buildGroupPayload(to, addressing_mode, device_jids, msg_plain, null);
    }

    pub fn buildGroupPayload(self: *Client, to: []const u8, addressing_mode: []const u8, device_jids: []const []const u8, msg_plain: []const u8, edit: ?[]const u8) !GroupSend {
        const alloc = self.allocator;
        const io = ioOf();
        const own = self.paired_jid orelse return error.NotPaired;
        const own_lid = self.paired_lid;

        // Signal sessions per target device, skipping our own.
        var targets: std.ArrayList([]u8) = .empty;
        defer {
            for (targets.items) |t| alloc.free(t);
            targets.deinit(alloc);
        }
        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(alloc);
        {
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            for (device_jids) |dj| {
                // Skip only the sending device itself. Own-user *other* devices
                // (phone :0, companions) must still get the SKDM or they can
                // never decrypt our group messages — the old user-wide skip
                // made our own group replies invisible on our own phone.
                // PN and LID are different namespaces; match per namespace.
                const self_pn = jid.isPn(dj) and std.mem.eql(u8, jid.user(dj), jid.user(own)) and jid.device(dj) == jid.device(own);
                const self_lid = jid.isLid(dj) and own_lid != null and std.mem.eql(u8, jid.user(dj), jid.user(own_lid.?)) and jid.device(dj) == jid.device(own_lid.?);
                if (self_pn or self_lid) continue;
                const ej = try self.encryptionJid(dj, null);
                try targets.append(alloc, ej);
                const s = try jid.signalId(alloc, ej);
                defer alloc.free(s);
                if (self.sessionFor(s) == null) try missing.append(alloc, ej);
            }
        }
        if (missing.items.len > 0) try self.fetchAndProcessPreKeys(missing.items);

        // Own sender-key state + SKDM wrapper plaintext (proto Message{2}).
        // The cached record pointer is shared across SKDM creation and group
        // encryption, so the ratchet persists even without a store (tests).
        const skdm_plain = blk: {
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            const rec = try self.senderKeyRecordPtr(to, own);
            const axolotl = try sg.create(alloc, rec, io);
            defer alloc.free(axolotl);
            self.saveSenderKeyRecord(to, own, rec);
            break :blk try proto.Message.encodeSenderKeyDistribution(alloc, to, axolotl);
        };
        defer alloc.free(skdm_plain);

        // SKDM pairwise to every target device (whatsmeow prepareMessageNode).
        var parts: std.ArrayList(stanza.Participant) = .empty;
        defer {
            for (parts.items) |part| alloc.free(part.ciphertext);
            parts.deinit(alloc);
        }
        for (targets.items) |ej| {
            const enc = self.encryptForDevice(ej, skdm_plain) catch |err| {
                std.log.warn("[whatsapp-native] group skdm encrypt for {s} failed: {}", .{ ej, err });
                continue;
            };
            try parts.append(alloc, .{ .jid = ej, .enc_type = enc.enc_type, .ciphertext = enc.ciphertext });
        }

        // Group-encrypt the padded marshalled message (whatsmeow padMessage(marshal)).
        const padded = try proto.padMessageRandom(alloc, msg_plain, io);
        defer alloc.free(padded);
        const skmsg = blk: {
            try self.state_mu.lock(io);
            defer self.state_mu.unlock(io);
            const rec = try self.senderKeyRecordPtr(to, own);
            const ct = try sg.encrypt(alloc, rec, padded, io);
            self.saveSenderKeyRecord(to, own, rec);
            break :blk ct;
        };
        defer alloc.free(skmsg);

        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const hex = std.fmt.bytesToHex(rnd, .upper);
        const msg_id = try alloc.dupe(u8, &hex);
        errdefer alloc.free(msg_id);
        var node = try groups_mod.buildGroupMessageNode(alloc, .{
            .id = msg_id,
            .to_group = to,
            .own_jid = own,
            .own_lid = own_lid,
            .addressing_mode = addressing_mode,
            .participants_device_jids = device_jids,
            .skmsg_ciphertext = skmsg,
            .skdm_payload = skdm_plain,
            .skdm_targets = parts.items,
            .edit = edit,
        });
        defer node.deinit();
        const frame = try binary.marshal(alloc, node);
        return .{ .frame = frame, .id = msg_id };
    }

    /// Send a text to a group chat: group metadata IQ → participant devices via
    /// usync → buildGroupText → write. Thread-safe (not from the poll thread).
    /// Memory: caller frees the message id.
    pub fn sendGroupText(self: *Client, to: []const u8, text: []const u8) ![]u8 {
        const msg_plain = try proto.Message.encodeTextWith(self.allocator, text, .{});
        defer self.allocator.free(msg_plain);
        return self.sendGroupPlaintext(to, msg_plain, null);
    }

    fn sendGroupPlaintext(self: *Client, to: []const u8, msg_plain: []const u8, edit: ?[]const u8) ![]u8 {
        if (!self.isConnected()) return error.NotConnected;
        if (!std.mem.eql(u8, jid.server(to), "g.us")) return error.NotGroupJid;
        const alloc = self.allocator;
        const own = self.paired_jid orelse return error.NotPaired;
        const own_lid = self.paired_lid;

        // 1. group metadata
        var id_buf: [24]u8 = undefined;
        const iq_id = self.nextId(&id_buf);
        var giq = try groups_mod.buildGroupInfoQuery(alloc, to, iq_id);
        defer giq.deinit();
        const iq_frame = try binary.marshal(alloc, giq);
        defer alloc.free(iq_frame);
        const resp = try self.sendIqWait(iq_id, iq_frame, iq_timeout_ms);
        defer alloc.free(resp);
        var rnode = try binary.decodeNode(alloc, resp);
        defer rnode.deinit();
        var info = try groups_mod.parseGroupInfo(alloc, rnode);
        defer info.deinit(alloc);

        // 2. participant users for usync (own user included; whatsmeow hashes allDevices)
        var users: std.ArrayList([]u8) = .empty;
        defer {
            for (users.items) |u| alloc.free(u);
            users.deinit(alloc);
        }
        {
            const own_user = try jid.format(alloc, jid.user(own), 0, jid.server(own));
            try users.append(alloc, own_user);
        }
        for (info.participants) |part| {
            const addr = if (std.mem.eql(u8, info.addressing_mode, "lid"))
                (part.lid orelse part.jid)
            else
                part.jid;
            if (std.mem.eql(u8, jid.user(addr), jid.user(own)) or
                (own_lid != null and std.mem.eql(u8, jid.user(addr), jid.user(own_lid.?))))
            {
                continue;
            }
            try users.append(alloc, try jid.format(alloc, jid.user(addr), 0, jid.server(addr)));
        }
        // dedupe (participants can repeat across PN/lid mirrors)
        var ui: usize = 0;
        while (ui < users.items.len) {
            var uj = ui + 1;
            var dup = false;
            while (uj < users.items.len) : (uj += 1) {
                if (std.mem.eql(u8, users.items[ui], users.items[uj])) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                alloc.free(users.swapRemove(ui));
            } else {
                ui += 1;
            }
        }

        var id2_buf: [24]u8 = undefined;
        const usync_id = self.nextId(&id2_buf);
        var sid_buf: [24]u8 = undefined;
        const sid = self.nextId(&sid_buf);
        const usync_frame = try stanza.encodeUsyncDevices(alloc, usync_id, sid, users.items);
        defer alloc.free(usync_frame);
        const usync_resp = try self.sendIqWait(usync_id, usync_frame, iq_timeout_ms);
        defer alloc.free(usync_resp);
        var usync_node = try binary.decodeNode(alloc, usync_resp);
        defer usync_node.deinit();
        const entries = try stanza.parseUsyncDevices(alloc, usync_node);
        defer alloc.free(entries);

        var devices: std.ArrayList([]u8) = .empty;
        defer {
            for (devices.items) |d| alloc.free(d);
            devices.deinit(alloc);
        }
        for (entries) |e| {
            const dj = try jid.format(alloc, jid.user(e.user_jid), e.device, jid.server(e.user_jid));
            try devices.append(alloc, dj);
        }
        if (devices.items.len == 0) return error.NoDevices;

        // phash input = allDevices (own phone + this companion + every participant device)
        var all_devices: std.ArrayList([]const u8) = .empty;
        defer all_devices.deinit(alloc);
        if (own_lid) |ol| try all_devices.append(alloc, ol);
        var own_dev_buf: [128]u8 = undefined;
        const own_dev = std.fmt.bufPrint(&own_dev_buf, "{s}:{d}@{s}", .{ jid.user(own), jid.device(own), jid.server(own) }) catch return error.JidTooLong;
        try all_devices.append(alloc, own_dev);
        for (devices.items) |d| try all_devices.append(alloc, d);

        const send = try self.buildGroupPayload(to, if (std.mem.eql(u8, info.addressing_mode, "lid")) "lid" else "", all_devices.items, msg_plain, edit);
        defer alloc.free(send.frame);
        defer alloc.free(send.id);
        try self.writeFrame(send.frame);
        self.rememberOutbound(send.id, to, msg_plain) catch |err| storeWarn("remember outbound", err);
        return alloc.dupe(u8, send.id);
    }

    const EncResult = struct { enc_type: stanza.EncType, ciphertext: []u8 };

    /// Memory: caller frees `ciphertext`.
    fn encryptForDevice(self: *Client, enc_jid: []const u8, plain: []const u8) !EncResult {
        const io = ioOf();
        try self.state_mu.lock(io);
        defer self.state_mu.unlock(io);
        const sid = try jid.signalId(self.allocator, enc_jid);
        defer self.allocator.free(sid);
        const peer = self.sessionFor(sid) orelse return error.NoSession;
        const padded = try proto.padMessageRandom(self.allocator, plain, io);
        defer self.allocator.free(padded);
        const whisper = try peer.session.encrypt(self.allocator, padded);
        var out = EncResult{ .enc_type = .msg, .ciphertext = whisper };
        if (peer.pending_prekey) |hdr| {
            defer self.allocator.free(whisper);
            out.ciphertext = try signal.encodePreKeyMessage(self.allocator, hdr, whisper);
            out.enc_type = .pkmsg;
        }
        self.persistSession(sid);
        return out;
    }

    /// `<iq xmlns=encrypt type=get>` for `targets`, then X3DH-initiate a session per bundle.
    fn fetchAndProcessPreKeys(self: *Client, targets: []const []const u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = self.nextId(&id_buf);
        const frame = try encrypt.encodeEncryptGet(self.allocator, id, targets);
        defer self.allocator.free(frame);
        const resp = try self.sendIqWait(id, frame, iq_timeout_ms);
        defer self.allocator.free(resp);
        var node = try binary.decodeNode(self.allocator, resp);
        defer node.deinit();
        const list = node.getChildByTag("list") orelse return error.NoPreKeyList;
        var got: usize = 0;
        for (list.children()) |user| {
            const parsed = encrypt.parseUser(user) catch continue;
            self.processPreKeyBundle(parsed.jid, parsed.bundle) catch |err| {
                std.log.warn("[whatsapp-native] prekey bundle for {s} rejected: {}", .{ parsed.jid, err });
                continue;
            };
            got += 1;
        }
        if (got == 0) return error.NoPreKeyBundle;
    }

    pub fn localKeys(self: *const Client) signal.LocalKeys {
        return .{
            .identity = self.identity,
            .signed_prekey = self.signed_pre_key,
            .signed_prekey_id = self.signed_pre_key_id,
            .registration_id = self.registration_id,
        };
    }

    pub fn preKeyBundle(self: *const Client) signal.PreKeyBundle {
        return .{
            .registration_id = self.registration_id,
            .signed_prekey_id = self.signed_pre_key_id,
            .signed_prekey_pub = self.signed_pre_key.pub_key,
            .signed_prekey_sig = self.signed_pre_key_sig,
            .identity_pub = self.identity.pub_key,
        };
    }

    /// Verify signed-prekey, run X3DH Alice, store session. First encrypt is pkmsg.
    pub fn processPreKeyBundle(self: *Client, their_jid: []const u8, bundle: signal.PreKeyBundle) !void {
        const key33 = signal.encodeDjb(bundle.signed_prekey_pub);
        try curve_sigs.verify(bundle.identity_pub, &key33, bundle.signed_prekey_sig);
        const io = ioOf();
        const initiated = try signal.initiateFromBundle(bundle, self.identity, io);
        const enc_jid = try self.encryptionJid(their_jid, null);
        defer self.allocator.free(enc_jid);
        const sid = try jid.signalId(self.allocator, enc_jid);
        defer self.allocator.free(sid);
        try self.state_mu.lock(io);
        defer self.state_mu.unlock(io);
        try self.putSession(sid, .{ .session = initiated.session, .pending_prekey = initiated.header });
        if (self.store) |*s| {
            if (self.paired_jid) |own| s.putIdentity(own, sid, bundle.identity_pub) catch {};
        }
    }

    /// Single-device `<message><enc/></message>` for `to` (tests / direct peers).
    /// Memory: caller frees the stanza.
    pub fn encryptText(self: *Client, to: []const u8, text: []const u8) ![]u8 {
        const inner = try proto.Message.encodeText(self.allocator, text);
        defer self.allocator.free(inner);
        const enc_jid = try self.encryptionJid(to, null);
        defer self.allocator.free(enc_jid);
        const enc = self.encryptForDevice(enc_jid, inner) catch |err| switch (err) {
            error.NoSession => return error.NeedPreKeyBundle,
            else => return err,
        };
        defer self.allocator.free(enc.ciphertext);
        var id_buf: [8]u8 = undefined;
        ioOf().random(&id_buf);
        self.last_message_id = std.fmt.bytesToHex(id_buf, .upper);
        const from = self.paired_jid orelse "0:0@s.whatsapp.net";
        return stanza.encodeEncryptedMessage(self.allocator, to, &self.last_message_id, enc.enc_type, enc.ciphertext, from);
    }

    /// Decrypt a single-`<enc>` `<message>` to its text. Memory: caller frees.
    pub fn decryptIncomingMessage(self: *Client, node: binary.Node) ![]u8 {
        const enc = try stanza.parseEnc(node);
        if (enc.from.len == 0) return error.MissingFrom;
        const enc_jid = try self.encryptionJid(enc.from, null);
        defer self.allocator.free(enc_jid);
        const plain = try self.decryptDm(enc_jid, enc);
        defer self.allocator.free(plain);
        const msg = try proto.Message.decode(plain);
        return self.allocator.dupe(u8, msg.text() orelse "");
    }

    pub fn sendPresence(self: *Client, presence: []const u8, name: ?[]const u8) !void {
        if (!self.isConnected()) return error.NotConnected;
        const ptype = if (presence.len == 0) "available" else presence;
        const frame = try stanza.encodePresence(self.allocator, ptype, name);
        defer self.allocator.free(frame);
        try self.writeFrame(frame);
    }

    pub fn sendChatState(self: *Client, to: []const u8, state: []const u8) !void {
        if (!self.isConnected()) return error.NotConnected;
        const frame = try stanza.encodeChatState(self.allocator, to, state);
        defer self.allocator.free(frame);
        try self.writeFrame(frame);
    }

    pub fn sendLocation(self: *Client, to: []const u8, lat: f64, lon: f64) ![]u8 {
        const proto_bytes = try proto.Message.encodeLocation(self.allocator, lat, lon);
        defer self.allocator.free(proto_bytes);
        return self.sendPlaintext(to, proto_bytes);
    }

    pub fn markRead(self: *Client, chat: []const u8, id: []const u8, participant: ?[]const u8) !void {
        if (!self.isConnected()) return error.NotConnected;
        const ts: i64 = @divTrunc(nowMs(), 1000);
        const frame = try stanza.encodeReceipt(self.allocator, chat, id, "read", participant, ts);
        defer self.allocator.free(frame);
        try self.writeFrame(frame);
    }

    pub fn fetchGroupInfo(self: *Client, group_jid: []const u8) !groups_mod.GroupInfo {
        if (!self.isConnected()) return error.NotConnected;
        var id_buf: [24]u8 = undefined;
        const iq_id = self.nextId(&id_buf);
        var giq = try groups_mod.buildGroupInfoQuery(self.allocator, group_jid, iq_id);
        defer giq.deinit();
        const iq_frame = try binary.marshal(self.allocator, giq);
        defer self.allocator.free(iq_frame);
        const resp = try self.sendIqWait(iq_id, iq_frame, iq_timeout_ms);
        defer self.allocator.free(resp);
        var rnode = try binary.decodeNode(self.allocator, resp);
        defer rnode.deinit();
        return groups_mod.parseGroupInfo(self.allocator, rnode);
    }

    pub fn sendReaction(self: *Client, chat_jid: []const u8, message_id: []const u8, emoji: []const u8, participant: ?[]const u8) ![]u8 {
        var looked_up: ?[]u8 = null;
        defer if (looked_up) |s| self.allocator.free(s);
        const hit = lookupInbound(self, chat_jid, message_id);
        if (hit) |h| looked_up = h.sender;
        const part = participant orelse blk: {
            if (!std.mem.eql(u8, jid.server(chat_jid), "g.us")) break :blk null;
            break :blk looked_up;
        };
        const from_me = if (hit) |h| h.from_me else false;
        const proto_bytes = try proto.Message.encodeReaction(self.allocator, chat_jid, from_me, message_id, part, emoji);
        defer self.allocator.free(proto_bytes);
        return self.sendPlaintext(chat_jid, proto_bytes);
    }

    pub fn sendRevoke(self: *Client, chat_jid: []const u8, message_id: []const u8, participant: ?[]const u8) ![]u8 {
        var looked_up: ?[]u8 = null;
        defer if (looked_up) |s| self.allocator.free(s);
        const hit = lookupInbound(self, chat_jid, message_id);
        if (hit) |h| looked_up = h.sender;
        const part = participant orelse blk: {
            if (!std.mem.eql(u8, jid.server(chat_jid), "g.us")) break :blk null;
            break :blk looked_up;
        };
        const from_me = if (hit) |h| h.from_me else true;
        const proto_bytes = try proto.Message.encodeRevoke(self.allocator, chat_jid, from_me, message_id, part);
        defer self.allocator.free(proto_bytes);
        const edit_attr: []const u8 = if (from_me) "7" else "8";
        return self.sendPlaintextWithEdit(chat_jid, proto_bytes, edit_attr);
    }

    pub fn sendEdit(self: *Client, chat_jid: []const u8, message_id: []const u8, new_text: []const u8) ![]u8 {
        const proto_bytes = try proto.Message.encodeEdit(self.allocator, chat_jid, message_id, new_text);
        defer self.allocator.free(proto_bytes);
        return self.sendPlaintextWithEdit(chat_jid, proto_bytes, "1");
    }

    pub fn sendPoll(self: *Client, to: []const u8, name: []const u8, options: []const []const u8, selectable: u32) ![]u8 {
        var key: [32]u8 = undefined;
        ioOf().random(&key);
        const proto_bytes = try proto.Message.encodePoll(self.allocator, name, options, selectable, &key);
        defer self.allocator.free(proto_bytes);
        return self.sendPlaintext(to, proto_bytes);
    }

    pub fn ensureMediaConn(self: *Client) !stanza.MediaConn {
        if (!self.isConnected()) return error.NotConnected;
        if (self.media_conn_auth) |auth| {
            if (self.media_conn_host) |host| {
                if (nowMs() < self.media_conn_until_ms) {
                    return .{ .auth = auth, .hostname = host, .ttl = 0 };
                }
            }
        }
        var id_buf: [24]u8 = undefined;
        const iq_id = self.nextId(&id_buf);
        const frame = try stanza.encodeMediaConnIq(self.allocator, iq_id);
        defer self.allocator.free(frame);
        const resp = try self.sendIqWait(iq_id, frame, iq_timeout_ms);
        defer self.allocator.free(resp);
        var node = try binary.decodeNode(self.allocator, resp);
        defer node.deinit();
        const parsed = try stanza.parseMediaConn(node);
        if (self.media_conn_auth) |old| self.allocator.free(old);
        if (self.media_conn_host) |old| self.allocator.free(old);
        self.media_conn_auth = try self.allocator.dupe(u8, parsed.auth);
        self.media_conn_host = try self.allocator.dupe(u8, parsed.hostname);
        const ttl_ms: i64 = @as(i64, parsed.ttl) * 1000;
        self.media_conn_until_ms = nowMs() + @max(ttl_ms - 15_000, 5_000);
        return .{ .auth = self.media_conn_auth.?, .hostname = self.media_conn_host.?, .ttl = parsed.ttl };
    }
};

/// whatsmeow `unpadMessage`: v>=3 is unpadded; v2 last-byte pad; on v2
/// failure keep the raw bytes (history/protocol payloads often skip WA pad).
fn unpadEnc(alloc: std.mem.Allocator, padded: []const u8, version: u32) ![]u8 {
    const ver = if (version == 0) 2 else version;
    const slice = proto.unpadMessage(padded, ver) catch padded;
    return alloc.dupe(u8, slice);
}

fn takeMentions(alloc: std.mem.Allocator, msg: proto.Message, list: *std.ArrayList([]u8)) !void {
    var i: u8 = 0;
    while (i < msg.mentioned_jid_count) : (i += 1) {
        try list.append(alloc, try alloc.dupe(u8, msg.mentioned_jids[i]));
    }
}

fn takeQuote(
    alloc: std.mem.Allocator,
    msg: proto.Message,
    qid: *?[]u8,
    qp: *?[]u8,
    qt: *?[]u8,
) !void {
    if (msg.quoted_stanza_id) |id| if (id.len > 0 and qid.* == null) {
        qid.* = try alloc.dupe(u8, id);
    };
    if (msg.quoted_participant) |p| if (p.len > 0 and qp.* == null) {
        qp.* = try alloc.dupe(u8, p);
    };
    if (msg.quoted_text) |t| if (t.len > 0 and qt.* == null) {
        qt.* = try alloc.dupe(u8, t);
    };
}

fn applyKind(msg: proto.Message, kind: *InboundMessage.Kind) void {
    if (msg.reaction != null) {
        kind.* = .reaction;
    } else if (msg.protocol_type) |pt| {
        if (pt == 0) kind.* = .revoke;
    } else if (msg.poll_name != null) {
        kind.* = .poll;
    } else if (msg.location != null and kind.* == .text) {
        kind.* = .location;
    }
}

fn takeTarget(
    alloc: std.mem.Allocator,
    msg: proto.Message,
    kind: InboundMessage.Kind,
    stanza_id: *?[]u8,
    participant: *?[]u8,
) !void {
    const key: ?proto.MessageKey = if (msg.reaction) |rxn|
        rxn.key
    else if (kind == .revoke and msg.protocol_key.id.len > 0)
        msg.protocol_key
    else
        null;
    const k = key orelse return;
    if (k.id.len > 0 and stanza_id.* == null) {
        stanza_id.* = try alloc.dupe(u8, k.id);
    }
    if (k.participant.len > 0 and participant.* == null) {
        participant.* = try alloc.dupe(u8, k.participant);
    }
}

fn rememberInbound(self: *Client, id: []const u8, chat: []const u8, sender: []const u8, from_me: bool) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    self.recent_in_mu.lock(io) catch return;
    defer self.recent_in_mu.unlock(io);
    const id_d = self.allocator.dupe(u8, id) catch return;
    const chat_d = self.allocator.dupe(u8, chat) catch {
        self.allocator.free(id_d);
        return;
    };
    const sender_d = self.allocator.dupe(u8, sender) catch {
        self.allocator.free(chat_d);
        self.allocator.free(id_d);
        return;
    };
    if (self.recent_in[self.recent_in_pos]) |old| old.deinit(self.allocator);
    self.recent_in[self.recent_in_pos] = .{ .id = id_d, .chat = chat_d, .sender = sender_d, .from_me = from_me };
    self.recent_in_pos = (self.recent_in_pos + 1) % recent_in_cap;
}

const InboundHit = struct { sender: []u8, from_me: bool };

fn lookupInbound(self: *Client, chat: []const u8, id: []const u8) ?InboundHit {
    const io = std.Io.Threaded.global_single_threaded.io();
    self.recent_in_mu.lock(io) catch return null;
    defer self.recent_in_mu.unlock(io);
    for (self.recent_in) |slot| {
        const rec = slot orelse continue;
        if (std.mem.eql(u8, rec.id, id) and std.mem.eql(u8, rec.chat, chat)) {
            const sender = self.allocator.dupe(u8, rec.sender) catch return null;
            return .{ .sender = sender, .from_me = rec.from_me };
        }
    }
    return null;
}

fn lookupInboundSender(self: *Client, chat: []const u8, id: []const u8) ?[]u8 {
    const hit = lookupInbound(self, chat, id) orelse return null;
    return hit.sender;
}

/// Keep the first decryptable media attachment (kind + direct path + key).
fn captureMedia(alloc: std.mem.Allocator, slot: *?InboundMessage.MediaAttachment, m: ?proto.Media) !void {
    const mm = m orelse return;
    if (slot.* != null) return;
    const key = mm.media_key orelse return;
    if (key.len != 32) return;
    const src = mm.direct_path orelse mm.url orelse return;
    if (src.len == 0) return;
    var k: [32]u8 = undefined;
    @memcpy(&k, key[0..32]);
    slot.* = .{
        .kind = switch (mm.kind) {
            .image => .image,
            .video => .video,
            .audio => if (mm.ptt) .ptt else .audio,
            .document => .document,
            .sticker => .sticker,
        },
        .url = try alloc.dupe(u8, src),
        .media_key = k,
        .mimetype = if (mm.mimetype) |mi| try alloc.dupe(u8, mi) else null,
    };
}

fn stampGroupEcho(node: *binary.Node, group: []const u8, participant: []const u8) !void {
    const a = node.attrs.allocator;
    const fk = try a.dupe(u8, "from");
    errdefer a.free(fk);
    const fv = try a.dupe(u8, group);
    errdefer a.free(fv);
    try node.attrs.put(fk, fv);
    const pk = try a.dupe(u8, "participant");
    errdefer a.free(pk);
    const pv = try a.dupe(u8, participant);
    try node.attrs.put(pk, pv);
}

fn wrapEncMessage(alloc: std.mem.Allocator, from: []const u8, to: []const u8, id: []const u8, enc: EncResultPub, dsm: bool) ![]u8 {
    var enc_node = binary.Node.init(alloc, "enc");
    defer enc_node.deinit();
    try enc_node.attrs.put("v", "2");
    try enc_node.attrs.put("type", if (enc.enc_type == .pkmsg) "pkmsg" else "msg");
    enc_node.content = .{ .bytes = enc.ciphertext };
    var msg = binary.Node.init(alloc, "message");
    defer msg.deinit();
    try msg.attrs.put("from", from);
    try msg.attrs.put("to", to);
    try msg.attrs.put("id", id);
    try msg.attrs.put("t", "1700000000");
    try msg.attrs.put("type", "text");
    if (dsm) try msg.attrs.put("notify", "Me");
    msg.content = .{ .nodes = (&enc_node)[0..1] };
    return binary.marshal(alloc, msg);
}

const EncResultPub = struct { enc_type: stanza.EncType, ciphertext: []u8 };

fn encryptFor(cli: *Client, enc_jid: []const u8, plain: []const u8) !EncResultPub {
    const r = try cli.encryptForDevice(enc_jid, plain);
    return .{ .enc_type = r.enc_type, .ciphertext = r.ciphertext };
}

test "client: every decl analyzes" {
    std.testing.refAllDecls(Client);
}

test "dispatch: peer pkmsg then msg become message events" {
    const alloc = std.testing.allocator;
    var alice = Client.init(alloc);
    defer alice.deinit();
    var bob = Client.init(alloc);
    defer bob.deinit();
    try alice.setOwnJid("111:0@s.whatsapp.net");
    try bob.setOwnJid("222:7@s.whatsapp.net");

    try alice.processPreKeyBundle("222:7@s.whatsapp.net", bob.preKeyBundle());
    const plain = try proto.Message.encodeText(alloc, "hi barvis");
    defer alloc.free(plain);
    const e1 = try encryptFor(&alice, "222:7@s.whatsapp.net", plain);
    defer alloc.free(e1.ciphertext);
    try std.testing.expectEqual(stanza.EncType.pkmsg, e1.enc_type);
    const f1 = try wrapEncMessage(alloc, "111:0@s.whatsapp.net", "222:7@s.whatsapp.net", "M1", e1, false);
    defer alloc.free(f1);
    var n1 = try binary.decodeNode(alloc, f1);
    defer n1.deinit();
    var ev = try bob.dispatch(n1, f1);
    try std.testing.expect(ev == .message);
    defer ev.message.deinit();
    try std.testing.expectEqualStrings("hi barvis", ev.message.text);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", ev.message.sender);
    try std.testing.expectEqualStrings("111", ev.message.sender_pn.?);
    try std.testing.expect(!ev.message.from_me);
    try std.testing.expect(!ev.message.is_group);
    try std.testing.expectEqual(@as(i64, 1700000000), ev.message.timestamp);

    // Bob replies on the established session: plain msg, Alice decrypts.
    const reply = try proto.Message.encodeText(alloc, "hello back");
    defer alloc.free(reply);
    const e2 = try encryptFor(&bob, "111:0@s.whatsapp.net", reply);
    defer alloc.free(e2.ciphertext);
    try std.testing.expectEqual(stanza.EncType.msg, e2.enc_type);
    const f2 = try wrapEncMessage(alloc, "222:7@s.whatsapp.net", "111:0@s.whatsapp.net", "M2", e2, false);
    defer alloc.free(f2);
    var n2 = try binary.decodeNode(alloc, f2);
    defer n2.deinit();
    var ev2 = try alice.dispatch(n2, f2);
    try std.testing.expect(ev2 == .message);
    defer ev2.message.deinit();
    try std.testing.expectEqualStrings("hello back", ev2.message.text);

    // Replay of M2 is rejected and yields no event.
    var n2b = try binary.decodeNode(alloc, f2);
    defer n2b.deinit();
    const ev3 = try alice.dispatch(n2b, f2);
    try std.testing.expect(ev3 == .idle);
}

test "dispatch: phone DeviceSentMessage to companion is from_me with destination chat" {
    const alloc = std.testing.allocator;
    var phone = Client.init(alloc);
    defer phone.deinit();
    var companion = Client.init(alloc);
    defer companion.deinit();
    try phone.setOwnJid("917019895010:0@s.whatsapp.net");
    try companion.setOwnJid("917019895010:55@s.whatsapp.net");

    try phone.processPreKeyBundle("917019895010:55@s.whatsapp.net", companion.preKeyBundle());
    const inner = try proto.Message.encodeText(alloc, "barvis ping");
    defer alloc.free(inner);
    const dsm = try proto.Message.encodeDeviceSent(alloc, "216638251077681@lid", inner);
    defer alloc.free(dsm);
    const e = try encryptFor(&phone, "917019895010:55@s.whatsapp.net", dsm);
    defer alloc.free(e.ciphertext);
    const f = try wrapEncMessage(alloc, "917019895010:0@s.whatsapp.net", "917019895010:55@s.whatsapp.net", "S1", e, true);
    defer alloc.free(f);
    var n = try binary.decodeNode(alloc, f);
    defer n.deinit();
    var ev = try companion.dispatch(n, f);
    try std.testing.expect(ev == .message);
    defer ev.message.deinit();
    try std.testing.expect(ev.message.from_me);
    try std.testing.expectEqualStrings("216638251077681@lid", ev.message.chat);
    try std.testing.expectEqualStrings("barvis ping", ev.message.text);
    try std.testing.expectEqualStrings("Me", ev.message.push_name.?);
}

test "dispatch: sessions persist across client restarts via sqlite" {
    const alloc = std.testing.allocator;
    var rnd: [6]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&rnd);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "/tmp/zepto-native-{s}.sqlite", .{std.fmt.bytesToHex(rnd, .lower)}, 0);
    defer alloc.free(db_path);
    defer _ = std.c.unlink(db_path.ptr);

    var alice = Client.init(alloc);
    defer alice.deinit();
    try alice.setOwnJid("111:0@s.whatsapp.net");
    var plain: []u8 = undefined;
    var f1: []u8 = undefined;
    {
        var bob = Client.init(alloc);
        defer bob.deinit();
        try bob.openStore(db_path);
        try bob.setOwnJid("222:7@s.whatsapp.net");
        // Sessions FK onto whatsmeow_device: without this row the write is rejected.
        try bob.persistDevice();
        try alice.processPreKeyBundle("222:7@s.whatsapp.net", bob.preKeyBundle());
        plain = try proto.Message.encodeText(alloc, "one");
        const e1 = try encryptFor(&alice, "222:7@s.whatsapp.net", plain);
        defer alloc.free(e1.ciphertext);
        f1 = try wrapEncMessage(alloc, "111:0@s.whatsapp.net", "222:7@s.whatsapp.net", "P1", e1, false);
        var n1 = try binary.decodeNode(alloc, f1);
        defer n1.deinit();
        var ev = try bob.dispatch(n1, f1);
        try std.testing.expect(ev == .message);
        ev.message.deinit();
        // Restart: a second client on the same store restores keys + session.
    }
    alloc.free(plain);
    alloc.free(f1);
    var bob2 = Client.init(alloc);
    defer bob2.deinit();
    try bob2.openStore(db_path);
    try bob2.loadFromStore();
    try std.testing.expectEqualStrings("222:7@s.whatsapp.net", bob2.paired_jid.?);
    try std.testing.expect(bob2.sessions.count() == 0);
    const plain2 = try proto.Message.encodeText(alloc, "two");
    defer alloc.free(plain2);
    const e2 = try encryptFor(&alice, "222:7@s.whatsapp.net", plain2);
    defer alloc.free(e2.ciphertext);
    const f2 = try wrapEncMessage(alloc, "111:0@s.whatsapp.net", "222:7@s.whatsapp.net", "P2", e2, false);
    defer alloc.free(f2);
    var n2 = try binary.decodeNode(alloc, f2);
    defer n2.deinit();
    var ev2 = try bob2.dispatch(n2, f2);
    try std.testing.expect(ev2 == .message);
    defer ev2.message.deinit();
    try std.testing.expectEqualStrings("two", ev2.message.text);
    try std.testing.expect(bob2.sessions.count() == 1);
}

test "persistSession without a device row is a no-op, not a crash" {
    const alloc = std.testing.allocator;
    var rnd: [6]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&rnd);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "/tmp/zepto-native-{s}.sqlite", .{std.fmt.bytesToHex(rnd, .lower)}, 0);
    defer alloc.free(db_path);
    defer _ = std.c.unlink(db_path.ptr);
    var alice = Client.init(alloc);
    defer alice.deinit();
    try alice.setOwnJid("111:0@s.whatsapp.net");
    var bob = Client.init(alloc);
    defer bob.deinit();
    try bob.openStore(db_path);
    try bob.setOwnJid("222:7@s.whatsapp.net");
    try alice.processPreKeyBundle("222:7@s.whatsapp.net", bob.preKeyBundle());
    const plain = try proto.Message.encodeText(alloc, "one");
    defer alloc.free(plain);
    const e1 = try encryptFor(&alice, "222:7@s.whatsapp.net", plain);
    defer alloc.free(e1.ciphertext);
    const f1 = try wrapEncMessage(alloc, "111:0@s.whatsapp.net", "222:7@s.whatsapp.net", "P1", e1, false);
    defer alloc.free(f1);
    var n1 = try binary.decodeNode(alloc, f1);
    defer n1.deinit();
    var ev = try bob.dispatch(n1, f1);
    try std.testing.expect(ev == .message);
    ev.message.deinit();
    // In-memory session works; sqlite has no row because the FK target is missing.
    try std.testing.expect(bob.sessions.count() == 1);
    const row = try bob.store.?.getSession("222:7@s.whatsapp.net", "111");
    try std.testing.expect(row == null);
    // Once the device row exists the next persist lands.
    try bob.persistDevice();
    bob.persistSession("111");
    const row2 = (try bob.store.?.getSession("222:7@s.whatsapp.net", "111")) orelse return error.TestUnexpectedResult;
    defer alloc.free(row2);
    try std.testing.expect(row2.len > 0);
}

test "dispatch: group skmsg with SKDM becomes a group message event" {
    const alloc = std.testing.allocator;
    var alice = Client.init(alloc);
    defer alice.deinit();
    var bob = Client.init(alloc);
    defer bob.deinit();
    try alice.setOwnJid("111:0@s.whatsapp.net");
    try bob.setOwnJid("222:7@s.whatsapp.net");
    const group = "120363421845733873@g.us";
    try alice.processPreKeyBundle("222:7@s.whatsapp.net", bob.preKeyBundle());

    // Alice builds the group frame (SKDM fanout + skmsg) for bob's device.
    const devices = [_][]const u8{"222:7@s.whatsapp.net"};
    const send = try alice.buildGroupText(group, "", &devices, "hi group");
    defer alloc.free(send.frame);
    defer alloc.free(send.id);

    // Without the SKDM the skmsg cannot decrypt: no event. The server stamps
    // `from`/`participant` on the echo; simulate that for the inbound parse.
    var n0 = try binary.decodeNode(alloc, send.frame);
    defer n0.deinit();
    try stampGroupEcho(&n0, group, "111@s.whatsapp.net");
    try std.testing.expect((try bob.dispatch(n0, send.frame)) == .idle);

    // Deliver the SKDM wrapper to bob as its own message (whatsmeow: per-device
    // enc of the same frame → separate inbound message).
    var frame_node = try binary.decodeNode(alloc, send.frame);
    defer frame_node.deinit();
    const participants = frame_node.getChildByTag("participants") orelse return error.TestUnexpectedResult;
    const to0 = participants.children()[0];
    const skdm_enc = to0.getChildByTag("enc") orelse return error.TestUnexpectedResult;
    var enc_node = binary.Node.init(alloc, "enc");
    defer enc_node.deinit();
    try enc_node.attrs.put("v", "2");
    try enc_node.attrs.put("type", skdm_enc.getAttr("type").?);
    enc_node.content = .{ .bytes = skdm_enc.contentBytes().? };
    var skdm_msg = binary.Node.init(alloc, "message");
    defer skdm_msg.deinit();
    try skdm_msg.attrs.put("from", "111@s.whatsapp.net");
    try skdm_msg.attrs.put("to", "222:7@s.whatsapp.net");
    try skdm_msg.attrs.put("id", "SK1");
    try skdm_msg.attrs.put("t", "1700000001");
    try skdm_msg.attrs.put("type", "text");
    skdm_msg.content = .{ .nodes = (&enc_node)[0..1] };
    const skdm_wire = try binary.marshal(alloc, skdm_msg);
    defer alloc.free(skdm_wire);
    var n1 = try binary.decodeNode(alloc, skdm_wire);
    defer n1.deinit();
    try std.testing.expect((try bob.dispatch(n1, skdm_wire)) == .idle);

    // Now the group frame decrypts into a group message event.
    var n2 = try binary.decodeNode(alloc, send.frame);
    defer n2.deinit();
    try stampGroupEcho(&n2, group, "111@s.whatsapp.net");
    var ev = try bob.dispatch(n2, send.frame);
    try std.testing.expect(ev == .message);
    defer ev.message.deinit();
    try std.testing.expectEqualStrings("hi group", ev.message.text);
    try std.testing.expect(ev.message.is_group);
    try std.testing.expectEqualStrings(group, ev.message.chat);
    try std.testing.expectEqualStrings("111@s.whatsapp.net", ev.message.sender);

    // Replay of the same skmsg is rejected: no second event.
    var n3 = try binary.decodeNode(alloc, send.frame);
    defer n3.deinit();
    try stampGroupEcho(&n3, group, "111:0@s.whatsapp.net");
    try std.testing.expect((try bob.dispatch(n3, send.frame)) == .idle);
}

test "group SKDM targets own phone but not the sending device" {
    const alloc = std.testing.allocator;
    var alice = Client.init(alloc);
    defer alice.deinit();
    var phone = Client.init(alloc);
    defer phone.deinit();
    var bob = Client.init(alloc);
    defer bob.deinit();
    try alice.setOwnJid("111:58@s.whatsapp.net");
    try phone.setOwnJid("111:0@s.whatsapp.net");
    try bob.setOwnJid("222:7@s.whatsapp.net");
    try alice.processPreKeyBundle("111:0@s.whatsapp.net", phone.preKeyBundle());
    try alice.processPreKeyBundle("222:7@s.whatsapp.net", bob.preKeyBundle());
    const devices = [_][]const u8{
        "111:0@s.whatsapp.net",
        "111:58@s.whatsapp.net",
        "222:7@s.whatsapp.net",
    };
    const send = try alice.buildGroupText("120363421845733873@g.us", "", &devices, "hi group");
    defer alloc.free(send.frame);
    defer alloc.free(send.id);
    var node = try binary.decodeNode(alloc, send.frame);
    defer node.deinit();
    const participants = node.getChildByTag("participants") orelse return error.TestUnexpectedResult;
    var saw_phone = false;
    var saw_peer = false;
    for (participants.children()) |*to| {
        const j = to.getAttr("jid") orelse continue;
        // Device 0 normalizes to bare user form on the wire.
        if (std.mem.eql(u8, j, "111@s.whatsapp.net") or std.mem.eql(u8, j, "111:0@s.whatsapp.net")) saw_phone = true;
        if (std.mem.eql(u8, j, "222:7@s.whatsapp.net")) saw_peer = true;
        try std.testing.expect(!std.mem.eql(u8, j, "111:58@s.whatsapp.net"));
    }
    try std.testing.expect(saw_phone);
    try std.testing.expect(saw_peer);
}

test "client unpaired payload has pairing data" {
    var cli = Client.init(std.testing.allocator);
    defer cli.deinit();
    const enc = try cli.unpairedPayload(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    try std.testing.expect(enc.len > 0);
    // devicePairingData field 19 wire 2 → tag 0x9A 0x01
    try std.testing.expect(std.mem.indexOf(u8, enc, &[_]u8{ 0x9A, 0x01 }) != null);
    try std.testing.expect(!cli.connected);
    const key33 = signal.encodeDjb(cli.signed_pre_key.pub_key);
    try curve_sigs.verify(cli.identity.pub_key, &key33, cli.signed_pre_key_sig);
    try std.testing.expect(!std.mem.allEqual(u8, &cli.signed_pre_key_sig, 0));
}

test "client pair-device stores QR codes in comma-separated format" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();

    var ref = binary.Node.init(alloc, "ref");
    defer ref.deinit();
    ref.content = .{ .bytes = "qrref" };
    var pd = binary.Node.init(alloc, "pair-device");
    defer pd.deinit();
    pd.content = .{ .nodes = (&ref)[0..1] };
    var iq = binary.Node.init(alloc, "iq");
    defer iq.deinit();
    try iq.attrs.put("from", "s.whatsapp.net");
    try iq.attrs.put("id", "x");
    iq.content = .{ .nodes = (&pd)[0..1] };

    const ack = try cli.handlePairDeviceIq(iq);
    defer alloc.free(ack);
    try std.testing.expectEqual(@as(usize, 1), cli.getQr().len);
    const qr = cli.getQr()[0];
    try std.testing.expect(std.mem.startsWith(u8, qr, "qrref,"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, qr, ","));
    try std.testing.expect(std.mem.indexOf(u8, qr, "https://") == null);
}

test "lidDmDestination rewrites PN to LID with peer_recipient_pn" {
    const alloc = std.testing.allocator;
    var rnd: [6]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&rnd);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "/tmp/zepto-lid-dm-{s}.sqlite", .{std.fmt.bytesToHex(rnd, .lower)}, 0);
    defer alloc.free(db_path);
    defer _ = std.c.unlink(db_path.ptr);

    var cli = Client.init(alloc);
    defer cli.deinit();
    try cli.openStore(db_path);
    try cli.store.?.putLidMap("216638251077681", "917019895010");

    const from_pn = try cli.lidDmDestination("917019895010:58@s.whatsapp.net");
    defer from_pn.deinit(alloc);
    try std.testing.expectEqualStrings("216638251077681@lid", from_pn.dest);
    try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", from_pn.pn_owned.?);

    const from_lid = try cli.lidDmDestination("216638251077681:55@lid");
    defer from_lid.deinit(alloc);
    try std.testing.expectEqualStrings("216638251077681@lid", from_lid.dest);
    try std.testing.expectEqualStrings("917019895010@s.whatsapp.net", from_lid.pn_owned.?);

    const unknown = try cli.lidDmDestination("15555550101@s.whatsapp.net");
    defer unknown.deinit(alloc);
    try std.testing.expectEqualStrings("15555550101@s.whatsapp.net", unknown.dest);
    try std.testing.expect(unknown.pn_owned == null);
}

test "rememberOutbound and takeRecentOutboundForRetry cache + cap retries" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();

    try cli.rememberOutbound("MID1", "216638251077681@lid", "hello-plaintext");

    try std.testing.expect((try cli.takeRecentOutboundForRetry("NOPE")) == null);

    var i: u32 = 0;
    while (i < max_auto_retries) : (i += 1) {
        const got = (try cli.takeRecentOutboundForRetry("MID1")) orelse return error.TestUnexpectedResult;
        defer got.deinit(alloc);
        try std.testing.expectEqualStrings("216638251077681@lid", got.dest);
        try std.testing.expectEqualStrings("hello-plaintext", got.plaintext);
    }
    try std.testing.expectError(error.TooManyRetries, cli.takeRecentOutboundForRetry("MID1"));
}

test "rememberOutbound caches group dest for retry" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();

    try cli.rememberOutbound("GID1", "120363425058847361@g.us", "group-plain");
    const got = (try cli.takeRecentOutboundForRetry("GID1")) orelse return error.TestUnexpectedResult;
    defer got.deinit(alloc);
    try std.testing.expectEqualStrings("120363425058847361@g.us", got.dest);
    try std.testing.expectEqualStrings("group-plain", got.plaintext);
}

test "rememberOutbound evicts oldest past recent_out_cap" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();

    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < recent_out_cap + 1) : (i += 1) {
        const id = std.fmt.bufPrint(&buf, "id{d}", .{i}) catch unreachable;
        try cli.rememberOutbound(id, "dest@s.whatsapp.net", "plain");
    }
    try std.testing.expect((try cli.takeRecentOutboundForRetry("id0")) == null);
    const still_there = (try cli.takeRecentOutboundForRetry("id64")) orelse return error.TestUnexpectedResult;
    still_there.deinit(alloc);
}

test "resetForRepair wipes dead device row and unpairs" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();
    try cli.openStore(":memory:");
    try cli.setOwnJid("111:0@s.whatsapp.net");
    try cli.persistDevice();
    const old_noise = cli.noise.pub_key;
    try cli.resetForRepair();
    try std.testing.expect(cli.selfJid() == null);
    try std.testing.expect(!cli.paired);
    try std.testing.expect(!std.mem.eql(u8, &old_noise, &cli.noise.pub_key));
    // Dead row gone: same store no longer loads anything paired.
    try std.testing.expectError(error.NotPaired, cli.loadFromStore());
}

test "dropSession removes memory and store session" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();
    try cli.openStore(":memory:");
    try cli.setOwnJid("917019895010:58@s.whatsapp.net");
    try cli.persistDevice();

    const sid = "216638251077681";
    try cli.store.?.putSession(cli.paired_jid.?, sid, "fake-session-blob");
    const before = (try cli.store.?.getSession(cli.paired_jid.?, sid)) orelse return error.TestUnexpectedResult;
    alloc.free(before);

    cli.dropSession("216638251077681@lid");
    try std.testing.expect((try cli.store.?.getSession(cli.paired_jid.?, sid)) == null);
}

test "lookupInboundSender finds group participant" {
    const alloc = std.testing.allocator;
    var cli = Client.init(alloc);
    defer cli.deinit();
    rememberInbound(&cli, "MIDG", "120363425058847361@g.us", "216638251077681@lid", false);
    const got = lookupInboundSender(&cli, "120363425058847361@g.us", "MIDG") orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("216638251077681@lid", got);
    try std.testing.expect(lookupInboundSender(&cli, "120363425058847361@g.us", "NOPE") == null);

    rememberInbound(&cli, "OWN1", "19082673946862@lid", "917019895010:58@s.whatsapp.net", true);
    const own = lookupInbound(&cli, "19082673946862@lid", "OWN1") orelse return error.TestUnexpectedResult;
    defer alloc.free(own.sender);
    try std.testing.expect(own.from_me);
}

