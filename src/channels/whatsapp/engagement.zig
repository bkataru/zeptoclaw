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

test "subscribe until leave" {
    subscribe("chat-a");
    try std.testing.expect(isSubscribed("chat-a"));
    unsubscribe("chat-a");
    try std.testing.expect(!isSubscribed("chat-a"));
}
