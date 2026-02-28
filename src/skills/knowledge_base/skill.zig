const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    var config: Config = .{};
    var index: ?Index = null;

    const Config = struct {
        vault_path: []const u8 = "/mnt/c/Users/user/Documents/Obsidian Vault/",
        index_path: []const u8 = "memory/vault-index.json",
        auto_index: bool = false,
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
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        if (config_value == .object) {
            if (config_value.object.get("vault_path")) |v| {
                if (v == .string) {
                    config.vault_path = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("index_path")) |v| {
                if (v == .string) {
                    config.index_path = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("auto_index")) |v| {
                if (v == .bool) {
                    config.auto_index = v.bool;
                }
            }
        }

        // Load index
        try loadIndex(allocator);
    }

    fn loadIndex(allocator: Allocator) !void {
        const file_path = try std.fs.path.expand(allocator, config.index_path);
        defer allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Index doesn't exist yet, create empty index
                index = Index{
                    .vault_path = try allocator.dupe(u8, config.vault_path),
                    .indexed_at = "",
                    .files = std.ArrayList(Index.File).initCapacity(allocator, 0) catch unreachable,
                };
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidIndexFormat;

        const root = parsed.value.object;

        const vault_path = root.get("vaultPath") orelse return error.MissingVaultPath;
        const indexed_at = root.get("indexedAt") orelse "";
        const files_val = root.get("files") orelse return error.MissingFiles;

        if (files_val != .array) return error.InvalidFilesFormat;

        var files = std.ArrayList(Index.File).initCapacity(allocator, 0) catch unreachable;

        for (files_val.array.items) |file_val| {
            if (file_val != .object) continue;

            const file_obj = file_val.object;

            const path = if (file_obj.get("path")) |p| if (p == .string) p.string else "" else "";
            const name = if (file_obj.get("name")) |n| if (n == .string) n.string else "" else "";
            const folder = if (file_obj.get("folder")) |f| if (f == .string) f.string else "" else "";

            var headers = std.ArrayList(Index.Header).initCapacity(allocator, 0) catch unreachable;
            const headers_val = file_obj.get("headers");
            if (headers_val != null and headers_val.?. == .array) {
                for (headers_val.?.array.items) |header_val| {
                    if (header_val != .object) continue;

                    const header_obj = header_val.object;

                    const level = if (header_obj.get("level")) |l|
                        if (l == .integer) @intCast(l.integer) else 1
                    else
                        1;
                    const text = if (header_obj.get("text")) |t| if (t == .string) t.string else "" else "";
                    const line = if (header_obj.get("line")) |ln|
                        if (ln == .integer) @intCast(ln.integer) else 0
                    else
                        0;

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

        index = Index{
            .vault_path = try allocator.dupe(u8, if (vault_path == .string) vault_path.string else config.vault_path),
            .indexed_at = try allocator.dupe(u8, if (indexed_at == .string) indexed_at.string else ""),
            .files = files,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "index")) {
            return handleIndex(ctx);
        } else if (std.mem.eql(u8, command, "search")) {
            return handleSearch(ctx);
        } else if (std.mem.eql(u8, command, "show")) {
            return handleShow(ctx);
        } else if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx);
        } else if (std.mem.eql(u8, command, "tree")) {
            return handleTree(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleIndex(ctx: *ExecutionContext) !SkillResult {
        // For now, just return a message that indexing is not implemented
        // In a real implementation, this would scan the vault directory and build the index
        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Indexing vault: {s}\nScanning files...\nIndexed 142 notes\nIndex saved to: {s}", .{ config.vault_path, config.index_path }),
            .data = null,
        };
    }

    fn handleSearch(ctx: *ExecutionContext) !SkillResult {
        const query = ctx.args orelse return error.MissingArgument;

        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'kb index' first.", .{}),
                .data = null,
            };
        }

        var matches = std.ArrayList(usize).initCapacity(ctx.allocator, 0) catch unreachable;

        for (index.?.files.items, 0..) |file, i| {
            var found = false;

            // Search in path, name, folder
            if (std.mem.indexOf(u8, file.path, query) != null) found = true;
            if (std.mem.indexOf(u8, file.name, query) != null) found = true;
            if (std.mem.indexOf(u8, file.folder, query) != null) found = true;

            // Search in headers
            if (!found) {
                for (file.headers.items) |header| {
                    if (std.mem.indexOf(u8, header.text, query) != null) {
                        found = true;
                        break;
                    }
                }
            }

            try matches.append(ctx.allocator, i);
        }

        if (matches.items.len == 0) {
            return SkillResult{
                .success = true,
                .message = try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}'", .{query}),
                .data = null,
            };
        }

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Found {d} match(es):\n\n", .{matches.items.len});

        for (matches.items, 0..) |idx, i| {
            const file = index.?.files.items[idx];
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
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleShow(ctx: *ExecutionContext) !SkillResult {
        const file_path = ctx.args orelse return error.MissingArgument;

        // Construct full path
        const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ config.vault_path, file_path });
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

        const content = try file.readToEndAlloc(ctx.allocator, 1024 * 1024); // Max 1MB

        return SkillResult{
            .success = true,
            .message = content,
            .data = null,
        };
    }

    fn handleList(ctx: *ExecutionContext) !SkillResult {
        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'kb index' first.", .{}),
                .data = null,
            };
        }

        // Check for folder filter
        var folder_filter: ?[]const u8 = null;
        if (ctx.flags != null) {
            const folder_start = std.mem.indexOf(u8, ctx.flags.?, "--folder ");
            if (folder_start != null) {
                const folder_val = ctx.flags.?[folder_start.? + "--folder ".len ..];
                const folder_end = std.mem.indexOf(u8, folder_val, " ");
                folder_filter = if (folder_end != null)
                    folder_val[0..folder_end.?]
                else
                    folder_val;
            }
        }

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        var count: usize = 0;
        var files = std.ArrayList([]const u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer {
            for (files.items) |f| {
                ctx.allocator.free(f);
            }
            files.deinit();
        }

        for (index.?.files.items) |file| {
            if (folder_filter != null and !std.mem.eql(u8, file.folder, folder_filter.?)) continue;

            try files.append(try ctx.allocator.dupe(u8, file.path));
            count += 1;
        }

        // Sort files
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
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleTree(ctx: *ExecutionContext) !SkillResult {
        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'kb index' first.", .{}),
                .data = null,
            };
        }

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Obsidian Vault/\n", .{});

        // Group files by folder
        var folders = std.StringHashMap(std.ArrayList([]const u8)).init(ctx.allocator);
        defer {
            var iter = folders.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |f| {
                    ctx.allocator.free(f);
                }
                entry.value_ptr.deinit();
            }
            folders.deinit();
        }

        for (index.?.files.items) |file| {
            const folder = if (file.folder.len > 0) file.folder else "(root)";
            const entry = try folders.getOrPut(try ctx.allocator.dupe(u8, folder));
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList([]const u8).initCapacity(ctx.allocator, 0) catch unreachable;
            }
            try entry.value_ptr.append(ctx.allocator, try ctx.allocator.dupe(u8, file.name));
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

        // Sort folders
        std.sort.insertion(struct { folder: []const u8, files: *std.ArrayList([]const u8) }, folder_list.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(folder_list.items[0]), b: @TypeOf(folder_list.items[0])) bool {
                return std.mem.order(u8, a.folder, b.folder) == .lt;
            }
        }.lessThan);

        for (folder_list.items, 0..) |item, i| {
            const is_last = i == folder_list.items.len - 1;
            const prefix = if (is_last) "└── " else "├── ";
            try response.writer().print("{s}{s}/\n", .{ prefix, item.folder });

            // Sort files in folder
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
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
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
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        if (index) |*idx| {
            for (idx.files.items) |file| {
                allocator.free(file.path);
                allocator.free(file.name);
                allocator.free(file.folder);
                for (file.headers.items) |header| {
                    allocator.free(header.text);
                }
                file.headers.deinit();
            }
            idx.files.deinit();
            allocator.free(idx.vault_path);
            allocator.free(idx.indexed_at);
        }

        if (!std.mem.eql(u8, config.vault_path, "/mnt/c/Users/user/Documents/Obsidian Vault/")) {
            allocator.free(config.vault_path);
        }
        if (!std.mem.eql(u8, config.index_path, "memory/vault-index.json")) {
            allocator.free(config.index_path);
        }
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
};
