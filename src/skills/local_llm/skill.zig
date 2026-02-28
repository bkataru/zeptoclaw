const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    const Config = struct {
        ollama_host: []const u8 = "http://localhost:11434",
        default_model: []const u8 = "qwen3:4b",
        num_threads: usize = 6,
        num_ctx: usize = 4096,
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;
        const cfg = try parseConfig(ctx.config);

        if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx, cfg);
        } else if (std.mem.eql(u8, command, "run")) {
            return handleRun(ctx, cfg);
        } else if (std.mem.eql(u8, command, "chat")) {
            return handleChat(ctx, cfg);
        } else if (std.mem.eql(u8, command, "pull")) {
            return handlePull(ctx, cfg);
        } else if (std.mem.eql(u8, command, "recommend")) {
            return handleRecommend(ctx, cfg);
        } else if (std.mem.eql(u8, command, "estimate")) {
            return handleEstimate(ctx, cfg);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx, cfg);
        } else {
            return error.UnknownCommand;
        }
    }

    fn parseConfig(config_json: std.json.Value) anyerror!Config {
        var cfg: Config = .{};
        if (config_json == .object) {
            if (config_json.object.get("ollama_host")) |v| {
                if (v == .string) cfg.ollama_host = v.string;
            }
            if (config_json.object.get("default_model")) |v| {
                if (v == .string) cfg.default_model = v.string;
            }
            if (config_json.object.get("num_threads")) |v| {
                if (v == .integer) cfg.num_threads = try std.math.cast(usize, v.integer);
            }
            if (config_json.object.get("num_ctx")) |v| {
                if (v == .integer) cfg.num_ctx = try std.math.cast(usize, v.integer);
            }
        }
        return cfg;
    }

    fn handleList(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        _ = cfg; // unused
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Available models:\n\n", .{});
        try response.writer().print("Chat:\n", .{});
        try response.writer().print("  qwen3:0.6b (0.6B)\n", .{});
        try response.writer().print("  qwen3:1.7b (1.7B)\n", .{});
        try response.writer().print("  qwen3:4b (4.0B)\n", .{});
        try response.writer().print("  gemma3:270m (270M)\n", .{});
        try response.writer().print("  phi4-mini (3.8B)\n\n", .{});
        try response.writer().print("Embeddings:\n", .{});
        try response.writer().print("  qwen3-embedding:8b (8.0B)\n", .{});
        try response.writer().print("  nomic-embed-text-v2-moe (1.1B)\n\n", .{});
        try response.writer().print("Vision:\n", .{});
        try response.writer().print("  qwen3-vl:2b (2.0B)\n", .{});
        try response.writer().print("  granite3.2-vision (3.0B)\n", .{});

        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleRun(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        const args = ctx.args orelse return error.MissingArgument;

        var iter = std.mem.splitScalar(u8, args, ' ');
        const model = iter.next() orelse cfg.default_model;
        const prompt = iter.rest();

        if (prompt.len == 0) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Usage: llm run <model> <prompt>", .{}),
                .data = null,
            };
        }

        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Running model '{s}' with prompt: \"{s}\"\n\n[In a real implementation, this would call the Ollama API at {s}/api/generate]", .{ model, prompt, cfg.ollama_host }),
            .data = null,
        };
    }

    fn handleChat(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        const model = ctx.args orelse cfg.default_model;

        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Starting interactive chat with model '{s}'...\n\n[In a real implementation, this would start an interactive session with the Ollama API]", .{model}),
            .data = null,
        };
    }

    fn handlePull(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        _ = cfg; // unused
        const model = ctx.args orelse return error.MissingArgument;

        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Pulling model '{s}' from Ollama registry...\n\n[In a real implementation, this would call: ollama pull {s}]", .{ model, model }),
            .data = null,
        };
    }

    fn handleRecommend(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        _ = cfg; // unused
        var ram: ?usize = null;
        var task: ?[]const u8 = null;

        if (ctx.flags != null) {
            const ram_start = std.mem.indexOf(u8, ctx.flags.?, "--ram ");
            if (ram_start != null) {
                const ram_val = ctx.flags.?[ram_start.? + "--ram ".len ..];
                const ram_end = std.mem.indexOf(u8, ram_val, " ");
                const ram_str = if (ram_end != null) ram_val[0..ram_end.?] else ram_val;
                ram = std.fmt.parseInt(usize, ram_str, 10) catch null;
            }

            const task_start = std.mem.indexOf(u8, ctx.flags.?, "--task ");
            if (task_start != null) {
                const task_val = ctx.flags.?[task_start.? + "--task ".len ..];
                const task_end = std.mem.indexOf(u8, task_val, " ");
                task = if (task_end != null) task_val[0..task_end.?] else task_val;
            }
        }

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        if (ram) |r| {
            try response.writer().print("Recommended models for {d}GB RAM:\n\n", .{r});

            if (r <= 4) {
                try response.writer().print("- qwen3:0.6b (0.6B) - Minimal, ~0.5GB RAM\n", .{});
                try response.writer().print("- gemma3:270m (270M) - Tiny, ~0.2GB RAM\n", .{});
                try response.writer().print("\nBest choice: qwen3:0.6b\n", .{});
            } else if (r <= 8) {
                try response.writer().print("- qwen3:1.7b (1.7B) - Fast chat, ~1GB RAM\n", .{});
                try response.writer().print("- gemma3:1b (1.0B) - Balanced, ~0.6GB RAM\n", .{});
                try response.writer().print("- phi4-mini (3.8B) - Good quality, ~2GB RAM\n", .{});
                try response.writer().print("\nBest choice: qwen3:1.7b\n", .{});
            } else if (r <= 16) {
                try response.writer().print("- qwen3:4b (4.0B) - Fast chat, ~3GB RAM\n", .{});
                try response.writer().print("- llama3.2:3b (3.0B) - Balanced, ~2.5GB RAM\n", .{});
                try response.writer().print("- deepseek-r1:8b (8.0B) - Reasoning, ~5GB RAM\n", .{});
                try response.writer().print("\nBest choice: qwen3:4b\n", .{});
            } else if (r <= 32) {
                try response.writer().print("- qwen3:8b (8.0B) - High quality, ~5GB RAM\n", .{});
                try response.writer().print("- llama3.2:7b (7.0B) - Excellent, ~4.5GB RAM\n", .{});
                try response.writer().print("- mistral:7b (7.0B) - Great, ~4.5GB RAM\n", .{});
                try response.writer().print("\nBest choice: qwen3:8b\n", .{});
            } else {
                try response.writer().print("- qwen3-coder:30b (30B) - Coding, ~18GB RAM\n", .{});
                try response.writer().print("- mixtral:8x7b (47B) - MoE, ~22GB RAM\n", .{});
                try response.writer().print("- llama3:70b (70B) - Best quality, ~40GB RAM\n", .{});
                try response.writer().print("\nBest choice: qwen3-coder:30b\n", .{});
            }
        } else if (task) |t| {
            try response.writer().print("Recommended models for task '{s}':\n\n", .{t});

            if (std.mem.indexOf(u8, t, "chat") != null or std.mem.indexOf(u8, t, "fast") != null) {
                try response.writer().print("- qwen3:4b - Fast chat, 15+ tok/s\n", .{});
                try response.writer().print("- phi4-mini - Compact, good quality\n", .{});
            } else if (std.mem.indexOf(u8, t, "code") != null or std.mem.indexOf(u8, t, "coding") != null) {
                try response.writer().print("- qwen3-coder:30b - Best for coding\n", .{});
                try response.writer().print("- deepseek-coder - Good alternative\n", .{});
            } else if (std.mem.indexOf(u8, t, "reason") != null or std.mem.indexOf(u8, t, "think") != null) {
                try response.writer().print("- deepseek-r1:8b - Chain of thought\n", .{});
                try response.writer().print("- qwen3:4b-thinking - Good reasoning\n", .{});
            } else if (std.mem.indexOf(u8, t, "vision") != null or std.mem.indexOf(u8, t, "image") != null) {
                try response.writer().print("- qwen3-vl:2b - Vision-language\n", .{});
                try response.writer().print("- llava - Popular VL model\n", .{});
            } else if (std.mem.indexOf(u8, t, "embed") != null) {
                try response.writer().print("- nomic-embed-text - Good embeddings\n", .{});
                try response.writer().print("- qwen3-embedding:8b - High quality\n", .{});
            } else {
                try response.writer().print("- qwen3:4b - Good all-rounder\n", .{});
                try response.writer().print("- llama3.2:3b - Balanced choice\n", .{});
            }
        } else {
            try response.writer().print("Usage: llm recommend --ram <GB> or --task <task>\n\n", .{});
            try response.writer().print("Examples:\n", .{});
            try response.writer().print("  llm recommend --ram 16\n", .{});
            try response.writer().print("  llm recommend --task coding\n", .{});
        }

        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleEstimate(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        const args = ctx.args orelse return error.MissingArgument;

        var iter = std.mem.splitScalar(u8, args, ' ');
        const model = iter.next() orelse return error.MissingArgument;

        var ctx_tokens: usize = cfg.num_ctx;
        const ctx_flag = iter.rest();
        if (std.mem.indexOf(u8, ctx_flag, "--ctx") != null) {
            const ctx_start = std.mem.indexOf(u8, ctx_flag, "--ctx ") orelse return error.InvalidFlag;
            const ctx_val = ctx_flag[ctx_start + "--ctx ".len ..];
            const ctx_end = std.mem.indexOf(u8, ctx_val, " ");
            const ctx_str = if (ctx_end != null) ctx_val[0..ctx_end.?] else ctx_val;
            ctx_tokens = std.fmt.parseInt(usize, ctx_str, 10) catch cfg.num_ctx;
        }

        // Estimate model size based on model name
        var params: f64 = 0;
        if (std.mem.indexOf(u8, model, "0.6b") != null) {
            params = 0.6;
        } else if (std.mem.indexOf(u8, model, "1.7b") != null) {
            params = 1.7;
        } else if (std.mem.indexOf(u8, model, "4b") != null) {
            params = 4.0;
        } else if (std.mem.indexOf(u8, model, "8b") != null) {
            params = 8.0;
        } else if (std.mem.indexOf(u8, model, "7b") != null) {
            params = 7.0;
        } else if (std.mem.indexOf(u8, model, "30b") != null) {
            params = 30.0;
        } else if (std.mem.indexOf(u8, model, "70b") != null) {
            params = 70.0;
        } else {
            params = 4.0; // Default
        }

        // Q4_K_M is ~45% of FP16
        const model_size_gb = (params * 2.0 * 0.45);
        const ctx_overhead_mb = @as(f64, @floatFromInt(ctx_tokens)) * 2.0 / 1024.0;
        const total_gb = model_size_gb + (ctx_overhead_mb / 1024.0);

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("RAM estimation for {s}:\n\n", .{model});
        try response.writer().print("Model size (Q4_K_M): ~{d:.1}GB\n", .{model_size_gb});
        try response.writer().print("Context overhead ({d} tokens): ~{d:.1}MB\n", .{ ctx_tokens, ctx_overhead_mb });
        try response.writer().print("Total: ~{d:.1}GB\n\n", .{total_gb});
        try response.writer().print("Recommended: {d:.0}GB+ RAM available\n", .{total_gb * 1.5});

        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext, cfg: Config) !SkillResult {
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Local LLM Commands:\n\n", .{});
        try response.writer().print("list                              - List available models\n", .{});
        try response.writer().print("run <model> <prompt>              - Run a model with prompt\n", .{});
        try response.writer().print("chat <model>                      - Start interactive chat\n", .{});
        try response.writer().print("pull <model>                      - Pull a model from registry\n", .{});
        try response.writer().print("recommend --ram <GB>              - Recommend by RAM\n", .{});
        try response.writer().print("recommend --task <task>           - Recommend by task\n", .{});
        try response.writer().print("estimate <model> [--ctx <tokens>] - Estimate RAM usage\n\n", .{});

        try response.writer().print("Configuration:\n", .{});
        try response.writer().print("  ollama_host: {s}\n", .{cfg.ollama_host});
        try response.writer().print("  default_model: {s}\n", .{cfg.default_model});
        try response.writer().print("  num_threads: {d}\n", .{cfg.num_threads});
        try response.writer().print("  num_ctx: {d}\n", .{cfg.num_ctx});

        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        _ = allocator;
        // No owned resources.
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "local-llm",
            .version = "1.0.0",
            .description = "Local LLM inference — Ollama, GGUF models, quantization, hardware matching, igllama.",
            .author = "Baala Kataru",
            .category = "ai",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "llm", "ollama", "local-llm" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*ollama.*", ".*local.*llm.*", ".*gguf.*", ".*quantiz.*" },
                },
            },
        };
    }
};
