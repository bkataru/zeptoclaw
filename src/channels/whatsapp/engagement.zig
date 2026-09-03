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

pub const TurnGate = enum { skip_peer_from_me, listening, run };

/// fromMe in a 1:1 with someone else is the operator talking to that person, not to Barvis.
/// Group fromMe only runs on an explicit wake/mention, not leftover subscription.
pub fn decideTurn(is_dm: bool, from_me: bool, is_self_chat: bool, triggered: bool, subscribed: bool) TurnGate {
    if (is_dm and from_me and !is_self_chat) return .skip_peer_from_me;
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
    \\- Do not add a lightning bolt. The gateway appends ⚡ after your text so the human can tell Barvis from Baala.
    \\Config lives at ~/.zeptoclaw/config.json. Persist allowFrom with exec (python3 or jq, then mv); apply with curl POST http://127.0.0.1:18789/reload and header X-Auth-Token from env GATEWAY_AUTH_TOKEN. Never systemctl restart from a turn.
    \\If WhatsApp is linked on the phone but inbound is silent, POST http://127.0.0.1:18789/whatsapp/heal with X-Auth-Token $GATEWAY_AUTH_TOKEN. Never delete ~/.zeptoclaw/sessions/whatsapp/creds.json. Never systemctl restart from a turn.
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

test "decideTurn skips fromMe peer DMs even when subscribed or wake word" {
    try std.testing.expectEqual(TurnGate.skip_peer_from_me, decideTurn(true, true, false, true, true));
    try std.testing.expectEqual(TurnGate.skip_peer_from_me, decideTurn(true, true, false, false, true));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, true, true, true, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(true, false, false, false, true));
    try std.testing.expectEqual(TurnGate.listening, decideTurn(true, false, false, false, false));
    try std.testing.expectEqual(TurnGate.run, decideTurn(false, true, false, true, false));
    try std.testing.expectEqual(TurnGate.listening, decideTurn(false, true, false, false, true));
    try std.testing.expectEqual(TurnGate.run, decideTurn(false, false, false, false, true));
}
