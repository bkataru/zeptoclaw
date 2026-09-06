//! Model-driven presence: gateway only tracks whether Barvis is *invoked*
//! on a chat. Speak vs silent vs leave is decided by listen/leave tools.
const std = @import("std");

const MAX_CHATS: usize = 32;
const ID_CAP: usize = 128;

const Slot = struct {
    id: [ID_CAP]u8 = undefined,
    id_len: usize = 0,
    subscribed: bool = false,
};

var g_slots: [MAX_CHATS]Slot = [_]Slot{.{}} ** MAX_CHATS;

fn slotId(s: *const Slot) []const u8 {
    return s.id[0..s.id_len];
}

fn findSlot(chat_id: []const u8) ?*Slot {
    for (&g_slots) |*s| {
        if (s.id_len == 0) continue;
        if (std.mem.eql(u8, slotId(s), chat_id)) return s;
    }
    return null;
}

fn allocSlot(chat_id: []const u8) *Slot {
    if (findSlot(chat_id)) |s| return s;
    for (&g_slots) |*s| {
        if (s.id_len == 0) {
            const n = @min(chat_id.len, ID_CAP);
            @memcpy(s.id[0..n], chat_id[0..n]);
            s.id_len = n;
            return s;
        }
    }
    var s = &g_slots[0];
    const n = @min(chat_id.len, ID_CAP);
    @memcpy(s.id[0..n], chat_id[0..n]);
    s.id_len = n;
    s.subscribed = false;
    return s;
}

/// Wake / keep receiving model turns for this chat.
pub fn subscribe(chat_id: []const u8) void {
    allocSlot(chat_id).subscribed = true;
}

/// Stop model turns until the next trigger word. Inbound is still journaled.
pub fn unsubscribe(chat_id: []const u8) void {
    if (findSlot(chat_id)) |s| s.subscribed = false;
}

pub fn isSubscribed(chat_id: []const u8) bool {
    if (findSlot(chat_id)) |s| return s.subscribed;
    return false;
}

const jid = @import("native/jid.zig");

fn identityUser(id: []const u8) []const u8 {
    var s = id;
    if (s.len > 0 and s[0] == '+') s = s[1..];
    return jid.user(s);
}

/// True when `chat_id` is the operator talking to their own account (self-chat).
pub fn isSelfChat(chat_id: []const u8, identities: []const []const u8) bool {
    const chat_user = identityUser(chat_id);
    if (chat_user.len == 0) return false;
    for (identities) |id| {
        const u = identityUser(id);
        if (u.len > 0 and std.mem.eql(u8, u, chat_user)) return true;
    }
    return false;
}

/// Backlog guard: messages older than this never start a turn. Restarts and
/// reconnects deliver offline mail in a flood; answering a 20-minute-old
/// audio with "got it" reads as unprompted. Stale mail is still journaled.
pub const STALE_TURN_SEC: i64 = 600;

/// True when `sent_unix` (wire `t`, 0 when unset e.g. local replays) is older
/// than STALE_TURN_SEC relative to `now_unix`. Pure; pinned by tests.
pub fn isStaleInbound(sent_unix: i64, now_unix: i64) bool {
    if (sent_unix <= 0) return false;
    if (now_unix <= sent_unix) return false;
    return now_unix - sent_unix > STALE_TURN_SEC;
}

pub const TurnGate = enum { skip_peer_from_me, listening, run };

/// Presence lifecycle, one per chat. States: `idle` (unsubscribed) and
/// `active` (subscribed). Events: `wake` (barvis/mention/media-DM), `leave`
/// (leave tool, thanks/bye drift, peer-DM skip), and any inbound message.
/// The table below is the whole machine: `nextGate` maps (chat kind, speaker,
/// trigger, presence) to a gate, and `applyGate` owns the presence side
/// effects, so callers cannot subscribe in one place and forget to
/// unsubscribe in another.
pub const ChatKind = enum { dm_self, dm_peer, group };

pub const TurnInput = struct {
    kind: ChatKind,
    /// True for the operator's own messages (fromMe).
    from_me: bool = false,
    /// Wake word, @mention, or media DM.
    triggered: bool = false,
    /// Raw presence bit; `event_only` reactions/polls/revokes mask it.
    subscribed: bool = false,
    event_only: bool = false,
};

/// Pure transition function. Rules, pinned by tests:
/// - wake always runs, from anyone, in any chat;
/// - an active presence keeps DMs (either side) and group peer messages open;
/// - group own messages need an explicit wake, never leftover presence;
/// - untriggered, idle peer-DM own messages stay skipped (operator talking to
///   a person, not to Barvis).
pub fn nextGate(in: TurnInput) TurnGate {
    const active = in.subscribed and !in.event_only;
    switch (in.kind) {
        .dm_self => return if (in.triggered or active) .run else .listening,
        .dm_peer => {
            if (in.triggered or active) return .run;
            return if (in.from_me) .skip_peer_from_me else .listening;
        },
        .group => {
            if (in.from_me) return if (in.triggered) .run else .listening;
            return if (in.triggered or active) .run else .listening;
        },
    }
}

/// Presence side effects owned by the table: wake subscribes, peer-DM skip
/// unsubscribes, everything else leaves presence alone.
pub fn applyGate(chat_id: []const u8, gate: TurnGate, triggered: bool) void {
    switch (gate) {
        .run => if (triggered) subscribe(chat_id),
        .skip_peer_from_me => unsubscribe(chat_id),
        .listening => {},
    }
}

/// Current presence state for logs and debugging.
pub const Presence = enum { idle, active };
pub fn presenceOf(chat_id: []const u8) Presence {
    return if (isSubscribed(chat_id)) .active else .idle;
}

/// Legacy boolean-soup entry point; delegates to `nextGate`. `subscribed`
/// here is the effective bit (callers masked event_only themselves).
 pub fn decideTurn(is_dm: bool, from_me: bool, is_self_chat: bool, triggered: bool, subscribed: bool) TurnGate {
    // This wrapper predates event_only masking inside the table, so it
    // cannot reconstruct kind perfectly for groups; preserve exact legacy
    // behavior per branch instead of re-deriving.
    if (is_dm and from_me and !is_self_chat) return if (triggered or subscribed) .run else .skip_peer_from_me;
    if (from_me and !is_dm) {
        return if (triggered) .run else .listening;
    }
    if (triggered or subscribed) return .run;
    return .listening;
 }

pub const PRESENCE_INSTRUCTIONS =
    \\Presence (WhatsApp): You are in a live thread. History is recorded whether you talk or not.
    \\- To talk to the user, write a normal assistant message (no listen/leave tools).
    \\- If you are not being addressed, the topic moved on, or a reply would interrupt, call tool `listen` and do not send user-facing text.
    \\- If they are done with you (thanks/bye/moved on), call tool `leave`. You will not be invoked again until someone says "barvis".
    \\Prefer listening over talking over people. Do not narrate that you are listening.
;

/// Always appended by the gateway. UTF-8 U+26A1.
pub const SIGNATURE_MARK = "\xe2\x9a\xa1";

pub const LANGUAGE_INSTRUCTIONS =
    \\Language (WhatsApp): Write like Barvis: sharp, technically specific, dry wit when it fits. Plain sentences.
    \\- ASCII hyphen (-) not em dash. ASCII quotes.
    \\- No filler: "it's worth noting", "delve", "landscape", "tapestry", "robust", "serves as", "at its core".
    \\- No "not X, but Y" pivots. No slogan triads. No corporate warmth.
    \\- Keep code, paths, JIDs, and numbers exact.
    \\- Never print passwords, tokens, API keys, or other secrets in replies, even if the user just shared them. Use them via tools only. If a secret must change, say what to rotate without quoting it.
    \\Config lives at ~/.zeptoclaw/config.json. Persist allowFrom with exec (python3 or jq, then mv); apply with curl POST http://127.0.0.1:18789/reload and header X-Auth-Token from env GATEWAY_AUTH_TOKEN. Never systemctl restart from a turn.
    \\If WhatsApp is linked on the phone but inbound is silent, POST http://127.0.0.1:18789/whatsapp/heal with X-Auth-Token $GATEWAY_AUTH_TOKEN. Never delete ~/.zeptoclaw/sessions/whatsapp/native.sqlite. Never systemctl restart from a turn.
;

fn trimRightAsciiWs(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        const c = text[end - 1];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
            end -= 1;
            continue;
        }
        break;
    }
    return text[0..end];
}

pub fn alreadySigned(text: []const u8) bool {
    const t = trimRightAsciiWs(text);
    if (t.len < SIGNATURE_MARK.len) return false;
    return std.mem.endsWith(u8, t, SIGNATURE_MARK);
}

/// Memory: caller owns returned slice.
pub fn appendSignature(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (alreadySigned(text)) return alloc.dupe(u8, text);
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ text, SIGNATURE_MARK });
}

test "subscribe until leave" {
    subscribe("chat-a");
    try std.testing.expect(isSubscribed("chat-a"));
    unsubscribe("chat-a");
    try std.testing.expect(!isSubscribed("chat-a"));
}

test "appendSignature once" {
    const a = std.testing.allocator;
    const s = try appendSignature(a, "ping");
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "ping \xe2\x9a\xa1"));
    const twice = try appendSignature(a, s);
    defer a.free(twice);
    try std.testing.expect(std.mem.eql(u8, twice, s));
}

test "subscribe long id is truncated not overflow" {
    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    subscribe(&long);
    try std.testing.expect(isSubscribed(long[0..128]));
    unsubscribe(long[0..128]);
    try std.testing.expect(!isSubscribed(long[0..128]));
}

test "isSelfChat matches own LID PN and E164" {
    try std.testing.expect(isSelfChat("216638251077681@lid", &.{
        "917019895010",
        "917019895010:58@s.whatsapp.net",
        "216638251077681@lid",
    }));
    try std.testing.expect(isSelfChat("917019895010@s.whatsapp.net", &.{ "+917019895010" }));
    try std.testing.expect(!isSelfChat("19082673946862@lid", &.{
        "917019895010",
        "216638251077681@lid",
    }));
}

test "isStaleInbound guards backlog floods" {
    try std.testing.expect(!isStaleInbound(0, 1000000));
    try std.testing.expect(!isStaleInbound(1000000, 1000000));
    try std.testing.expect(!isStaleInbound(1000000, 999999));
    try std.testing.expect(!isStaleInbound(1000000, 1000000 + 600));
    try std.testing.expect(isStaleInbound(1000000, 1000000 + 601));
    try std.testing.expect(isStaleInbound(1000000, 1000000 + 3600));
}

test "decideTurn runs peer-DM fromMe on wake or subscription" {
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, true, false, true, true));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, true, false, true, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, true, false, false, true));
    try std.testing.expectEqual(TurnGate.skip_peer_from_me, decideTurn(true, true, false, false, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, true, true, true, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, false, false, false, true));
    try std.testing.expectEqual(TurnGate.listening, decideTurn(true, false, false, false, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(false, true, false, true, false));
    try std.testing.expectEqual(TurnGate.listening, decideTurn(false, true, false, false, true));
    try std.testing.expectEqual(TurnGate.run, decideTurn(false, false, false, false, true));
}
test "nextGate presence table" {
    // Wake always runs.
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_peer, .from_me = true, .triggered = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .group, .from_me = true, .triggered = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_self, .triggered = true }));
    // Active presence keeps DMs and group peer messages open.
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_peer, .from_me = true, .subscribed = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_peer, .subscribed = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .group, .subscribed = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_self, .subscribed = true }));
    // Group own messages need a wake, never leftover presence.
    try std.testing.expectEqual(TurnGate.listening, nextGate(.{ .kind = .group, .from_me = true, .subscribed = true }));
    // Idle peer-DM own messages stay skipped.
    try std.testing.expectEqual(TurnGate.skip_peer_from_me, nextGate(.{ .kind = .dm_peer, .from_me = true }));
    try std.testing.expectEqual(TurnGate.listening, nextGate(.{ .kind = .dm_peer }));
    try std.testing.expectEqual(TurnGate.listening, nextGate(.{ .kind = .dm_self }));
    // Reactions/polls/revokes mask presence.
    try std.testing.expectEqual(TurnGate.listening, nextGate(.{ .kind = .dm_peer, .subscribed = true, .event_only = true }));
    try std.testing.expectEqual(TurnGate.run, nextGate(.{ .kind = .dm_peer, .triggered = true, .subscribed = true, .event_only = true }));
}

test "applyGate owns presence side effects" {
    const id = "fsm-test-chat";
    unsubscribe(id);
    applyGate(id, .run, true);
    try std.testing.expect(isSubscribed(id));
    applyGate(id, .run, false);
    try std.testing.expect(isSubscribed(id));
    applyGate(id, .listening, false);
    try std.testing.expect(isSubscribed(id));
    applyGate(id, .skip_peer_from_me, false);
    try std.testing.expect(!isSubscribed(id));
}
