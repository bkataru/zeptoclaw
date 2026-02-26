const std = @import("std");
const input = @import("input.zig");
const cli_utils = @import("cli_utils.zig");

pub fn runInteractiveSession(agent: anytype) !void {
    const allocator = agent.allocator;
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Show welcome message
    try stdout_file.writeAll(cli_utils.formatMessagePrefix(.system));
    try stdout_file.writeAll("Zeptoclaw AI Agent - Type /help for commands\n\n");

    // Main REPL loop
    while (true) {
        // Show prompt
        try stdout_file.writeAll("\x1b[32mZeptoclaw>\x1b[0m ");

        // Read input
        const user_input = input.readLine(allocator, "") catch |err| {
            if (err == error.EndOfStream) {
                // EOF - exit gracefully
                try stdout_file.writeAll("\nGoodbye!\n");
                return;
            }
            return err;
        };
        defer allocator.free(user_input);

        // Trim whitespace
        const trimmed = std.mem.trim(u8, user_input, " \t\n\r");
        if (trimmed.len == 0) continue;

        // Handle commands
        if (trimmed[0] == '/') {
            const should_continue = try handleCommand(agent, trimmed, stdout_file);
            if (!should_continue) return;
            continue;
        }

        // Regular message - run through agent
        try stdout_file.writeAll(cli_utils.formatMessagePrefix(.user));
        try stdout_file.writeAll(trimmed);
        try stdout_file.writeAll("\n");

        // Get response from agent (agent manages its own session)
        try stdout_file.writeAll(cli_utils.formatMessagePrefix(.assistant));
        const response = try agent.run(trimmed);
        defer allocator.free(response);

        // Display response
        try stdout_file.writeAll(response);
        try stdout_file.writeAll("\n");
    }
}

fn handleCommand(agent: anytype, cmd: []const u8, writer: std.fs.File) !bool {
    if (std.mem.eql(u8, cmd, "/help")) {
        try writer.writeAll("Available commands:\n");
        try writer.writeAll("  /help - Show this help\n");
        try writer.writeAll("  /exit - Exit the program\n");
        try writer.writeAll("  /clear - Clear conversation history\n");
        try writer.writeAll("  /session - Show session stats\n");
        try writer.writeAll("\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/quit")) {
        try writer.writeAll("Goodbye!\n");
        return false;
    }

    if (std.mem.eql(u8, cmd, "/clear")) {
        // Clear the agent's session
        agent.session.clear();
        try writer.writeAll("Conversation cleared.\n\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "/session")) {
        try writer.writeAll("Session stats:\n");
        try writer.writeAll("  Messages: ");
        var buf: [32]u8 = undefined;
        const len = try std.fmt.bufPrint(&buf, "{d}", .{agent.session.message_count});
        try writer.writeAll(len);
        try writer.writeAll("\n");
        try writer.writeAll("  Max messages: ");
        const len2 = try std.fmt.bufPrint(&buf, "{d}", .{agent.session.max_messages});
        try writer.writeAll(len2);
        try writer.writeAll("\n\n");
        return true;
    }

    // Unknown command
    try cli_utils.formatError("Unknown command. Type /help for help.", writer);
    return true;
}

pub fn showPrompt() !void {
    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll("Zeptoclaw> ");
}

test "CLI module loads" {
    _ = runInteractiveSession;
    _ = handleCommand;
    _ = showPrompt;
}
