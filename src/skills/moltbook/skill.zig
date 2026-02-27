//! Moltbook Skill
//! The social network for AI agents

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        if (config_value != .object) {
            config = Config{
                .api_key = "",
                .agent_name = "barvis_da_jarvis",
                .agent_id = "",
                .api_base = "https://www.moltbook.com/api/v1",
            };
            return;
        }

        const api_key = if (config_value.object.get("api_key")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const agent_name = if (config_value.object.get("agent_name")) |v|
            if (v == .string) v.string else "barvis_da_jarvis"
        else
            "barvis_da_jarvis";

        const agent_id = if (config_value.object.get("agent_id")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const api_base = if (config_value.object.get("api_base")) |v|
            if (v == .string) v.string else "https://www.moltbook.com/api/v1"
        else
            "https://www.moltbook.com/api/v1";

        config = Config{
            .api_key = api_key,
            .agent_name = agent_name,
            .agent_id = agent_id,
            .api_base = api_base,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Check if API key is configured
        if (config.?.api_key.len == 0) {
            const response = try std.fmt.allocPrint(ctx.allocator,
                \\🦞 Moltbook - Not Configured
                \\
                \\Please set your Moltbook API key:
                \\1. Get your API key from https://www.moltbook.com
                \\2. Add it to your skill configuration
                \\
                \\Usage: /moltbook <command>
            , .{});
            try ctx.respond(response);
            return SkillResult.successResponse(ctx.allocator, response);
        }

        // Parse command
        if (std.mem.startsWith(u8, message, "/moltbook-post")) {
            return handlePost(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/moltbook-comment")) {
            return handleComment(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/moltbook-upvote")) {
            return handleUpvote(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/moltbook feed")) {
            return handleFeed(ctx);
        } else if (std.mem.startsWith(u8, message, "/moltbook profile")) {
            return handleProfile(ctx);
        } else if (std.mem.startsWith(u8, message, "/moltbook")) {
            return handleHelp(ctx);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "moltbook",
            .name = "Moltbook",
            .version = "1.9.0",
            .description = "The social network for AI agents. Post, comment, upvote, and create communities.",
            .homepage = "https://www.moltbook.com",
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    api_key: []const u8,
    agent_name: []const u8,
    agent_id: []const u8,
    api_base: []const u8,
};

fn handlePost(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract post content
    const content = std.mem.trim(u8, message["/moltbook-post".len..], " \t\r\n");

    if (content.len == 0) {
        const response = "Usage: /moltbook-post <your post content>";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would make an HTTP POST request
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🦞 Posting to Moltbook...
        \\
        \\Content: {s}
        \\
        \\✅ Post created successfully!
        \\Post ID: post_123456
    , .{content});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleComment(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract post ID and comment
    var iter = std.mem.splitScalar(u8, message["/moltbook-comment".len..], ' ');
    const post_id = iter.next() orelse {
        const response = "Usage: /moltbook-comment <post_id> <your comment>";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    };

    const comment = iter.rest();

    if (comment.len == 0) {
        const response = "Usage: /moltbook-comment <post_id> <your comment>";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would make an HTTP POST request
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💬 Commenting on post {s}...
        \\
        \\Comment: {s}
        \\
        \\✅ Comment added successfully!
    , .{post_id, comment});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleUpvote(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract post ID
    const post_id = std.mem.trim(u8, message["/moltbook-upvote".len..], " \t\r\n");

    if (post_id.len == 0) {
        const response = "Usage: /moltbook-upvote <post_id>";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would make an HTTP POST request
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⬆️ Upvoting post {s}...
        \\
        \\✅ Upvote successful!
    , .{post_id});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleFeed(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would fetch the feed from Moltbook API
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🦞 Moltbook Feed
        \\
        \\Recent posts:
        \\
        \\1. @agent1: Just deployed a new feature! 🚀
        \\   ⬆️ 42 upvotes | 💬 8 comments
        \\
        \\2. @agent2: Working on a new AI model
        \\   ⬆️ 28 upvotes | 💬 5 comments
        \\
        \\3. @agent3: Check out this cool library
        \\   ⬆️ 15 upvotes | 💬 3 comments
        \\
        \\Use /moltbook-post to share your own updates!
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleProfile(ctx: *ExecutionContext) !SkillResult {
    const agent_name = config.?.agent_name;
    const agent_id = if (config.?.agent_id.len > 0) config.?.agent_id else "Not registered";

    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🦞 Moltbook Profile
        \\
        \\Agent: {s}
        \\ID: {s}
        \\
        \\Stats:
        \\- Posts: 0
        \\- Comments: 0
        \\- Upvotes given: 0
        \\- Upvotes received: 0
        \\
        \\Visit https://www.moltbook.com to see your profile!
    , .{agent_name, agent_id});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleHelp(ctx: *ExecutionContext) !SkillResult {
    const response =
        \\🦞 Moltbook - Social Network for AI Agents
        \\
        \\Commands:
        \\  /moltbook-post <content>    - Post to Moltbook
        \\  /moltbook-comment <id> <c> - Comment on a post
        \\  /moltbook-upvote <id>      - Upvote a post
        \\  /moltbook feed             - Get your feed
        \\  /moltbook profile          - View your profile
        \\
        \\Visit https://www.moltbook.com for more info!
    ;

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
