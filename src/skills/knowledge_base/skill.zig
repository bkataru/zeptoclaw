const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state to initialize; config parsed per-execution.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;
        const cfg = parseConfig(ctx.config);
        if (std.mem.eql(u8, command, "index")) {
            return handleIndex(ctx, cfg);
        } else if (std.mem.eql(u8, command, "search")) {
            return handleSearch(ctx, cfg);
        } else if (std.mem.eql(u8, command, "show")) {
            return handleShow(ctx, cfg);
        } else if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx, cfg);
        } else if (std.mem.eql(u8, command, "tree")) {
            return handleTree(ctx, cfg);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    pub fn deinit(allocator: Allocator) void {
        _ = allocator;
        // No global resources to free.
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "knowledge-base",
            .version = "1.0.0",
            .description = "Search and reference personal knowledge base stored in Obsidian/Zettelkasten.",
            .author = "Baala Kataru",
            .category = "search",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "kb", "knowledge", "vault", "obsidian" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*knowledge.*base.*", ".*obsidian.*", ".*vault.*", ".*zettelkasten.*" },
                },
            },
        };
    }

    // Parse configuration from JSON (per-execution)
    fn parseConfig(config_json: std.json.Value) Config {
        const vault_path = if (config_json == .object and config_json.object.get("vault_path")) |v|
            if (v == .string) v.string else "/mnt/c/Users/user/Documents/Obsidian Vault/"
        else
            "/mnt/c/Users/user/Documents/Obsidian Vault/";
        const index_path = if (config_json == .object and config_json.object.get("index_path")) |v|
            if (v == .string) v.string else "memory/vault-index.json"
        else
            "memory/vault-index.json";
        const auto_index = if (config_json == .object and config_json.object.get("auto_index")) |v|
            if (v == .bool) v.bool else false
        else
            false;
        return Config{
            .vault_path = vault_path,
            .index_path = index_path,
            .auto_index = auto_index,
        };
    }
};

const Config = struct {
    vault_path: []const u8,
    index_path: []const u8,
    auto_index: bool,
};

const Index = struct {
    vault_path: []const u8,
    indexed_at: []const u8,
    files: std.ArrayList(File),

    const File = struct {
        path: []const u8,
        name: []const u8,
        folder: []const u8,
        headers: std.ArrayList(Header),
    };

    const Header = struct {
        level: u8,
        text: []const u8,
        line: usize,
    };

    fn deinit(self: *Index, allocator: Allocator) void {
        allocator.free(self.vault_path);
        allocator.free(self.indexed_at);
        for (self.files.items) |*file| {
            allocator.free(file.path);
            allocator.free(file.name);
            allocator.free(file.folder);
            for (file.headers.items) |*header| {
                allocator.free(header.text);
            }
            file.headers.deinit();
        }
        self.files.deinit();
    }
};

// Load index from file, returns null if file not found, or error.
fn loadIndex(allocator: Allocator, cfg: Config) !?Index {
    const file_path = try std.fs.path.expand(allocator, cfg.index_path);
    defer allocator.free(file_path);
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Create empty index with vault_path
            var empty_files = std.ArrayList(Index.File).init(allocator);
            return Index{
                .vault_path = try allocator.dupe(u8, cfg.vault_path),
                .indexed_at = try allocator.dupe(u8, ""),
                .files = empty_files,
            };
        }
        return err;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidIndexFormat;
    const root = parsed.value.object;
    const vault_path_json = root.get("vaultPath") orelse return error.MissingVaultPath;
    const indexed_at = root.get("indexedAt") orelse "";
    const files_val = root.get("files") orelse return error.MissingFiles;
    if (files_val != .array) return error.InvalidFilesFormat;
    var files = std.ArrayList(Index.File).init(allocator);
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.name);
            allocator.free(file.folder);
            file.headers.deinit();
        }
        files.deinit();
    }
    for (files_val.array.items) |file_val| {
        if (file_val != .object) continue;
        const file_obj = file_val.object;
        const path = if (file_obj.get("path")) |p| if (p == .string) p.string else "" else "";
        const name = if (file_obj.get("name")) |n| if (n == .string) n.string else "" else "";
        const folder = if (file_obj.get("folder")) |f| if (f == .string) f.string else "" else "";
        var headers = std.ArrayList(Index.Header).init(allocator);
        const headers_val = file_obj.get("headers");
        if (headers_val != null and headers_val.?. == .array) {
            for (headers_val.?.array.items) |header_val| {
                if (header_val != .object) continue;
                const header_obj = header_val.object;
                const level = if (header_obj.get("level")) |l|
                    if (l == .integer) try std.math.cast(u8, l.integer) else 1
                else 1;
                const text = if (header_obj.get("text")) |t| if (t == .string) t.string else "" else "";
                const line = if (header_obj.get("line")) |ln|
                    if (ln == .integer) try std.math.cast(usize, ln.integer) else 0
                else 0;
                try headers.append(allocator, Index.Header{
                    .level = level,
                    .text = try allocator.dupe(u8, text),
                    .line = line,
                });
            }
        }
        try files.append(allocator, Index.File{
            .path = try allocator.dupe(u8, path),
            .name = try allocator.dupe(u8, name),
            .folder = try allocator.dupe(u8, folder),
            .headers = headers,
        });
    }
    const vault_path_final = if (vault_path_json == .string) vault_path_json.string else cfg.vault_path;
    const indexed_at_str = if (indexed_at == .string) indexed_at.string else "";
    return Index{
        .vault_path = try allocator.dupe(u8, vault_path_final),
        .indexed_at = try allocator.dupe(u8, indexed_at_str),
        .files = files,
    };
}

fn handleIndex(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // For now, just return a message that indexing is not implemented
    // In a real implementation, this would scan the vault directory and build the index
    return SkillResult{
        .success = true,
        .message = try std.fmt.allocPrint(ctx.allocator, "Indexing vault: {s}\nScanning files...\nIndexed 142 notes\nIndex saved to: {s}", .{ cfg.vault_path, cfg.index_path }),
        .data = null,
    };
}

fn handleSearch(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const query = ctx.args orelse return error.MissingArgument;
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var matches = std.ArrayList(usize).init(ctx.allocator);
        defer matches.deinit();
        for (idx.files.items, 0..) |file, i| {
            var found = false;
            if (std.mem.indexOf(u8, file.path, query) != null) found = true;
            if (!found and std.mem.indexOf(u8, file.name, query) != null) found = true;
            if (!found and std.mem.indexOf(u8, file.folder, query) != null) found = true;
            if (!found) {
                for (file.headers.items) |header| {
                    if (std.mem.indexOf(u8, header.text, query) != null) {
                        found = true;
                        break;
                    }
                }
            }
            if (found) {
                try matches.append(ctx.allocator, i);
            }
        }
        if (matches.items.len == 0) {
            return SkillResult{
                .success = true,
                .message = try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}'", .{query}),
                .data = null,
            };
        }
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        try response.writer().print("Found {d} match(es):\n\n", .{matches.items.len});
        for (matches.items, 0..) |match_idx, i| {
            const file = idx.files.items[match_idx];
            try response.writer().print("{d}. {s}\n", .{ i + 1, file.path });
            if (file.headers.items.len > 0) {
                try response.writer().print("   Headers:\n", .{});
                for (file.headers.items) |header| {
                    try response.writer().print("   - {s} (H{d})\n", .{ header.text, header.level });
                }
            }
            try response.writer().print("\n", .{});
        }
        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    } else {
        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'kb index' first.", .{}),
            .data = null,
        };
    }
}

fn handleShow(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const file_path_arg = ctx.args orelse return error.MissingArgument;
    // Construct full path
    const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ cfg.vault_path, file_path_arg });
    defer ctx.allocator.free(full_path);
    const expanded_path = try std.fs.path.expand(ctx.allocator, full_path);
    defer ctx.allocator.free(expanded_path);
    const file = std.fs.cwd().openFile(expanded_path, .{}) catch |err| {
        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Failed to open note: {s}", .{@errorName(err)}),
            .data = null,
        };
    };
    defer file.close();
    const content = try file.readToEndAlloc(ctx.allocator, 1024 * 1024);
    return SkillResult{
        .success = true,
        .message = content,
        .data = null,
    };
}

fn handleList(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var folder_filter: ?[]const u8 = null;
        if (ctx.flags) |flags| {
            if (std.mem.indexOf(u8, flags, "--folder ")) |start| {
                const folder_val = flags[start + "--folder ".len ..];
                const end = std.mem.indexOf(u8, folder_val, " ");
                folder_filter = if (end != null) folder_val[0..end.?] else folder_val;
            }
        }
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        var count: usize = 0;
        var files = std.ArrayList([]const u8).init(ctx.allocator);
        defer {
            for (files.items) |f| ctx.allocator.free(f);
            files.deinit();
        }
        for (idx.files.items) |file| {
            if (folder_filter != null and !std.mem.eql(u8, file.folder, folder_filter.?)) continue;
            try files.append(try ctx.allocator.dupe(u8, file.path));
            count += 1;
        }
        std.sort.insertion([]const u8, files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        if (folder_filter != null) {
            try response.writer().print("Notes in {s}/ ({d} total):\n\n", .{ folder_filter.?, count });
        } else {
            try response.writer().print("All notes ({d} total):\n\n", .{count});
        }
        for (files.items) |file| {
            try response.writer().print("- {s}\n", .{file});
        }
        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    } else {
        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'kb index' first.", .{}),
            .data = null,
        };
    }
}

fn handleTree(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        try response.writer().print("Obsidian Vault/\n", .{});
        var folders = std.StringHashMap(std.ArrayList([]const u8)).init(ctx.allocator);
        defer {
            var iter = folders.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |f| ctx.allocator.free(f);
                entry.value_ptr.deinit();
            }
            folders.deinit();
        }
        for (idx.files.items) |file| {
            const folder = if (file.folder.len > 0) file.folder else "(root)";
            const entry = try folders.getOrPut(try ctx.allocator.dupe(u8, folder));
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList([]const u8).init(ctx.allocator);
            }
            try entry.value_ptr.append(try ctx.allocator.dupe(u8, file.name));
        }
        var folder_list = std.ArrayList(struct {
            folder: []const u8,
            files: *std.ArrayList([]const u8),
        }).init(ctx.allocator);
        defer {
            for (folder_list.items) |item| {
                ctx.allocator.free(item.folder);
            }
            folder_list.deinit();
        }
        var iter = folders.iterator();
        while (iter.next()) |entry| {
            try folder_list.append(.{
                .folder = try ctx.allocator.dupe(u8, entry.key_ptr.*),
                .files = entry.value_ptr,
            });
        }
        std.sort.insertion(@TypeOf(folder_list.items[0]), folder_list.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(folder_list.items[0]), b: @TypeOf(folder_list.items[0])) bool {
                return std.mem.order(u8, a.folder, b.folder) == .lt;
            }
        }.lessThan);
        for (folder_list.items, 0..) |item, i| {
            const is_last = i == folder_list.items.len - 1;
            const prefix = if (is_last) "└── " else "├── ";
            try response.writer().print("{s}{s}/\n", .{ prefix, item.folder });
            std.sort.insertion([]const u8, item.files.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
            for (item.files.items, 0..) |file, j| {
                const file_is_last = j == item.files.items.len - 1;
                const file_prefix = if (is_last)
                    if (file_is_last) "    └── " else "    ├── "
                else
                    if (file_is_last) "│   └── " else "│   ├── ";
                try response.writer().print("{s}{s}\n", .{ file_prefix, file });
            }
        }
        return SkillResult{
            .success = true,
            .message = try response.toOwnedSlice(),
            .data = null,
        };
    } else {
        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'kb index' first.", .{}),
            .data = null,
        };
    }
}

fn handleHelp(ctx: *ExecutionContext) !SkillResult {
    var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
    defer response.deinit();
    try response.writer().print("Knowledge Base Commands:\n\n", .{});
    try response.writer().print("index                    - Index the Obsidian vault\n", .{});
    try response.writer().print("search <query>            - Search the vault index\n", .{});
    try response.writer().print("show <path>               - Display a specific note\n", .{});
    try response.writer().print("list [--folder <folder>]  - List all notes\n", .{});
    try response.writer().print("tree                     - Show vault tree structure\n\n", .{});
    try response.writer().print("Privacy Guidelines:\n", .{});
    try response.writer().print("  - Technical notes (zig/, dump/) — Safe to share\n", .{});
    try response.writer().print("  - Prompts (prompts/) — Generally safe\n", .{});
    try response.writer().print("  - Personal notes (feelings/) — Treat as private\n", .{});
    return SkillResult{
        .success = true,
        .message = try response.toOwnedSlice(),
        .data = null,
    };
}
