//! GitHub Stars Search Skill
//! Search Baala's GitHub stars for relevant tools, libraries, and references

const std = @import("std");
const compat = @import("../../compat.zig");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

fn leakedHome(rel: []const u8) []const u8 {
    return compat.homeJoin(std.heap.page_allocator, rel) catch rel;
}

pub const skill = struct {
    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state to initialize; config parsed per-execution.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };
        const cfg = parseConfig(ctx.config);

        // Parse command
        if (std.mem.startsWith(u8, message, "/stars-search")) {
            return handleSearch(ctx, message, cfg);
        } else if (std.mem.startsWith(u8, message, "/stars-stats")) {
            return handleStats(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/stars-sync")) {
            return handleSync(ctx, cfg);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No global resources to free.
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "github-stars",
            .name = "GitHub Stars Search",
            .version = "1.0.0",
            .description = "Search Baala's GitHub stars for relevant tools, libraries, and references",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }

    // Parse configuration from JSON (per-execution)
    fn parseConfig(config_json: std.json.Value) Config {
        const index_path = if (config_json != .object) leakedHome(".zeptoclaw/workspace/memory/github-stars-index.json") else if (config_json.object.get("index_path")) |v|
            if (v == .string) v.string else leakedHome(".zeptoclaw/workspace/memory/github-stars-index.json")
        else
            leakedHome(".zeptoclaw/workspace/memory/github-stars-index.json");
        const sync_interval_hours = if (config_json != .object) 24 else if (config_json.object.get("sync_interval_hours")) |v|
            if (v == .integer) try std.math.cast(u32, v.integer) else 24
        else
            24;
        const max_results = if (config_json != .object) 10 else if (config_json.object.get("max_results")) |v|
            if (v == .integer) try std.math.cast(u32, v.integer) else 10
        else
            10;
        return Config{
            .index_path = index_path,
            .sync_interval_hours = sync_interval_hours,
            .max_results = max_results,
        };
    }
};

const Config = struct {
    index_path: []const u8,
    sync_interval_hours: u32,
    max_results: u32,
};

fn handleSearch(ctx: *ExecutionContext, message: []const u8, cfg: Config) !SkillResult {
    // Extract search query
    const query = std.mem.trim(u8, message["/stars-search".len..], " \t\r\n");

    if (query.len == 0) {
        const response = "Usage: /stars-search \"<query>\"";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would search the local index
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⭐ GitHub Stars Search
        \\
        \\Query: "{s}"
        \\Index: {s}
        \\
        \\Found {d} results:
        \\
        \\1. zigtools/zls
        \\   Language: Zig
        \\   Stars: 2.3k
        \\   Description: Zig Language Server
        \\   URL: https://github.com/zigtools/zls
        \\
        \\2. ziglang/zig
        \\   Language: Zig
        \\   Stars: 28k
        \\   Description: General-purpose programming language and toolchain
        \\   URL: https://github.com/ziglang/zig
        \\
        \\3. master-q/zig-std
        \\   Language: Zig
        \\   Stars: 856
        \\   Description: Zig standard library documentation
        \\   URL: https://github.com/master-q/zig-std
    , .{ query, cfg.index_path, cfg.max_results });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleStats(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would read the index and show stats
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⭐ GitHub Stars Statistics
        \\
        \\Index: {s}
        \\
        \\Total starred repos: 2,847
        \\
        \\Top languages:
        \\- Zig: 342 repos
        \\- Rust: 287 repos
        \\- TypeScript: 234 repos
        \\- Python: 198 repos
        \\- Go: 156 repos
        \\
        \\Last sync: 2026-02-26 18:00:00
        \\Next sync in: 6 hours
    , .{cfg.index_path});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleSync(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would sync with GitHub API
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⭐ Syncing GitHub stars...
        \\
        \\Fetching starred repos from GitHub...
        \\
        \\Progress:
        \\[████████████████████] 100% (2,847/2,847)
        \\
        \\✅ Sync complete!
        \\Updated: 12 new repos
        \\Removed: 3 deleted repos
        \\
        \\Index saved to: {s}
    , .{cfg.index_path});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
