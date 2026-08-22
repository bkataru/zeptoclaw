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
