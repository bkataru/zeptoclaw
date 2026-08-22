const std = @import("std");
const compat = @import("../compat.zig");
const input = @import("input.zig");
const cli_utils = @import("cli_utils.zig");

pub fn runInteractiveSession(agent: anytype) !void {
    const allocator = agent.allocator;
    const stdout_file = std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };

    // Show welcome message
    try stdout_file.writeStreamingAll(compat.getIo(), cli_utils.formatMessagePrefix(.system));
    try stdout_file.writeStreamingAll(compat.getIo(), "Zeptoclaw AI Agent - Type /help for commands\n\n");

    // Main REPL loop
    while (true) {
        // Show prompt
        try stdout_file.writeStreamingAll(compat.getIo(), "\x1b[32mZeptoclaw>\x1b[0m ");

        // Read input
        const user_input = input.readLine(allocator, "") catch |err| {
            if (err == error.EndOfStream) {
                // EOF - exit gracefully
                try stdout_file.writeStreamingAll(compat.getIo(), "\nGoodbye!\n");
                return;
            }
            return err;
        };
        defer allocator.free(user_input);

        // Trim whitespace
        const trimmed = std.mem.trim(u8, user_input, " \t\n\r");
        if (trimmed.len == 0) continue;

        // Handle commands
        // Handle built-in commands (starts with /)
        if (trimmed[0] == '/') {
            if (std.mem.eql(u8, trimmed, "/help") or std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/clear") or std.mem.eql(u8, trimmed, "/session") or std.mem.eql(u8, trimmed, "/new") or std.mem.eql(u8, trimmed, "/reset")) {
                const should_continue = try handleCommand(agent, trimmed, stdout_file);
                if (!should_continue) return;
                continue;
            }
            // Unknown command, fall through to agent.run
        }


        // Regular message - run through agent
        try stdout_file.writeStreamingAll(compat.getIo(), cli_utils.formatMessagePrefix(.user));
        try stdout_file.writeStreamingAll(compat.getIo(), trimmed);
        try stdout_file.writeStreamingAll(compat.getIo(), "\n");

        // Get response from agent (agent manages its own session)
        try stdout_file.writeStreamingAll(compat.getIo(), cli_utils.formatMessagePrefix(.assistant));
        const response = try agent.run(trimmed);
        defer allocator.free(response);

        // Display response
        try stdout_file.writeStreamingAll(compat.getIo(), response);
        try stdout_file.writeStreamingAll(compat.getIo(), "\n");
    }
}

fn handleCommand(agent: anytype, cmd: []const u8, writer: std.Io.File) !bool {
    if (std.mem.eql(u8, cmd, "/help")) {
        try writer.writeStreamingAll(compat.getIo(), "Available commands:\n");
        try writer.writeStreamingAll(compat.getIo(), "  /help - Show this help\n");
        try writer.writeStreamingAll(compat.getIo(), "  /exit - Exit the program\n");
        try writer.writeStreamingAll(compat.getIo(), "  /clear - Clear conversation history\n");
        try writer.writeStreamingAll(compat.getIo(), "  /session - Show session stats\n");
        try writer.writeStreamingAll(compat.getIo(), "  /new - Start a fresh session\n");
        try writer.writeStreamingAll(compat.getIo(), "  /reset - Alias for /new\n");
        try writer.writeStreamingAll(compat.getIo(), "\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/quit")) {
        try writer.writeStreamingAll(compat.getIo(), "Goodbye!\n");
        return false;
    }

    if (std.mem.eql(u8, cmd, "/clear") or std.mem.eql(u8, cmd, "/new") or std.mem.eql(u8, cmd, "/reset")) {
        agent.session.clear();
        try writer.writeStreamingAll(compat.getIo(), "Conversation cleared.\n\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "/session")) {
        try writer.writeStreamingAll(compat.getIo(), "Session stats:\n");
        try writer.writeStreamingAll(compat.getIo(), "  Messages: ");
        var buf: [32]u8 = undefined;
        const len = try std.fmt.bufPrint(&buf, "{d}", .{agent.session.message_count});
        try writer.writeStreamingAll(compat.getIo(), len);
        try writer.writeStreamingAll(compat.getIo(), "\n");
        try writer.writeStreamingAll(compat.getIo(), "  Max messages: ");
        const len2 = try std.fmt.bufPrint(&buf, "{d}", .{agent.session.max_messages});
        try writer.writeStreamingAll(compat.getIo(), len2);
        try writer.writeStreamingAll(compat.getIo(), "\n\n");
        return true;
    }

    // Unknown command
    try cli_utils.formatError("Unknown command. Type /help for help.", writer);
    return true;
}

pub fn showPrompt() !void {
    const stdout_file = std.Io.File.stdout();
    try stdout_file.writeStreamingAll(compat.getIo(), "Zeptoclaw> ");
}

test "CLI module loads" {
    _ = runInteractiveSession;
    _ = handleCommand;
    _ = showPrompt;
}
