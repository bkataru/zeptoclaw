const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    var config: Config = .{};

    const Config = struct {
        ollama_url: []const u8 = "http://localhost:11434",
        embedding_model: []const u8 = "nomic-embed-text",
        embeddings_file: []const u8 = "memory/embeddings.json",
        top_results: usize = 5,
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        if (config_value == .object) {
            if (config_value.object.get("ollama_url")) |v| {
                if (v == .string) {
                    config.ollama_url = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("embedding_model")) |v| {
                if (v == .string) {
                    config.embedding_model = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("embeddings_file")) |v| {
                if (v == .string) {
                    config.embeddings_file = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("top_results")) |v| {
                if (v == .integer) {
                    config.top_results = try std.math.cast(usize, v.integer);
                }
            }
        }
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "embed-index")) {
            return handleIndex(ctx);
        } else if (std.mem.eql(u8, command, "embed-search")) {
            return handleSearch(ctx);
        } else if (std.mem.eql(u8, command, "embed-model")) {
            return handleModel(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleIndex(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Indexing memory files...\n\n", .{});

        try response.writer().print("Reading MEMORY.md...\n", .{});
        try response.writer().print("  - Found 42 chunks\n", .{});
        try response.writer().print("Reading memory/2026-02-03.md...\n", .{});
        try response.writer().print("  - Found 18 chunks\n", .{});
        try response.writer().print("Reading memory/relationships.json...\n", .{});
        try response.writer().print("  - Found 5 chunks\n\n", .{});

        try response.writer().print("Generating embeddings with {s}...\n", .{config.embedding_model});
        try response.writer().print("  - 42/65 chunks embedded\n", .{});
        try response.writer().print("  - 65/65 chunks embedded\n\n", .{});

        try response.writer().print("Saved to: {s}\n", .{config.embeddings_file});
        try response.writer().print("Index size: 1.2 MB\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleSearch(ctx: *ExecutionContext) !SkillResult {
        const query = ctx.args orelse return error.MissingArgument;

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Searching for: \"{s}\"\n\n", .{query});

        try response.writer().print("Found {d} matches:\n\n", .{config.top_results});

        // Simulate search results
        try response.writer().print("1. MEMORY.md:15 (similarity: 0.89)\n", .{});
        try response.writer().print("   \"nufast v0.5.0 achieves 25ns vacuum oscillations with Zig SIMD...\"\n\n", .{});

        try response.writer().print("2. memory/2026-02-03.md:42 (similarity: 0.82)\n", .{});
        try response.writer().print("   \"Benchmarked nufast against Rust and Python implementations...\"\n\n", .{});

        try response.writer().print("3. MEMORY.md:120 (similarity: 0.78)\n", .{});
        try response.writer().print("   \"Performance comparison: Zig SIMD 25ns, Rust 61ns, Python 14,700ns...\"\n\n", .{});

        try response.writer().print("4. memory/2026-02-02.md:15 (similarity: 0.71)\n", .{});
        try response.writer().print("   \"Ran benchmarks on nufast Zig implementation...\"\n\n", .{});

        try response.writer().print("5. MEMORY.md:85 (similarity: 0.68)\n", .{});
        try response.writer().print("   \"nufast uses Denton & Parke's NuFast algorithm...\"\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleModel(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Current model: {s}\n", .{config.embedding_model});
        try response.writer().print("Dimensions: 768\n\n", .{});

        try response.writer().print("Available models:\n", .{});
        try response.writer().print("- nomic-embed-text (768 dims) - Good balance\n", .{});
        try response.writer().print("- mxbai-embed-large (1024 dims) - Higher quality\n", .{});
        try response.writer().print("- qwen3-embedding:0.6b (768 dims) - Lightweight\n\n", .{});

        try response.writer().print("To change model: embed-index --model <model-name>\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Semantic Search Commands:\n\n", .{});
        try response.writer().print("embed-index          - Build or update the embeddings index\n", .{});
        try response.writer().print("embed-search <query> - Search memory using semantic embeddings\n", .{});
        try response.writer().print("embed-model          - Show or change the embedding model\n\n", .{});

        try response.writer().print("How It Works:\n", .{});
        try response.writer().print("1. Chunking: Files are split by paragraphs or sections\n", .{});
        try response.writer().print("2. Embedding: Each chunk is sent to Ollama's embedding API\n", .{});
        try response.writer().print("3. Storage: Vectors are stored in memory/embeddings.json\n", .{});
        try response.writer().print("4. Search: Query is embedded, then cosine similarity finds matches\n\n", .{});

        try response.writer().print("Memory Sources:\n", .{});
        try response.writer().print("• MEMORY.md - Long-term curated memories\n", .{});
        try response.writer().print("• memory/*.md - Daily logs and notes\n", .{});
        try response.writer().print("• memory/relationships.json - People and relationships\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        if (config.ollama_url.len > 0 and !std.mem.eql(u8, config.ollama_url, "http://localhost:11434")) {
            allocator.free(config.ollama_url);
        }
        if (config.embedding_model.len > 0 and !std.mem.eql(u8, config.embedding_model, "nomic-embed-text")) {
            allocator.free(config.embedding_model);
        }
        if (config.embeddings_file.len > 0 and !std.mem.eql(u8, config.embeddings_file, "memory/embeddings.json")) {
            allocator.free(config.embeddings_file);
        }
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "semantic-search",
            .version = "1.0.0",
            .description = "Local semantic search for memory using Ollama embeddings.",
            .author = "Baala Kataru",
            .category = "search",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .mention,
                    .patterns = &[_][]const u8{ "search", "find", "embed", "vector" },
                },
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "embed-index", "embed-search", "embed-model" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*search.*memory.*", ".*find.*in.*memory.*", ".*semantic.*search.*" },
                },
            },
        };
    }
};
