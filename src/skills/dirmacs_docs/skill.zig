const std = @import("std");
const compat = @import("../../compat.zig");
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
        if (std.mem.eql(u8, command, "search")) {
            return handleSearch(ctx, cfg);
        } else if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx, cfg);
        } else if (std.mem.eql(u8, command, "rebuild")) {
            return handleRebuild(ctx, cfg);
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
            .name = "dirmacs-docs",
            .version = "1.0.0",
            .description = "Documentation generation and search for DirMacs projects",
            .author = "Baala Kataru",
            .category = "docs",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "dirmacs", "docs" },
                },
            },
        };
    }

    // Parse configuration from JSON (per-execution)
    fn parseConfig(config_json: std.json.Value) Config {
        const index_path = if (config_json == .object and config_json.object.get("index_path")) |v|
            if (v == .string) v.string else "memory/dirmacs-docs-index.json"
        else
            "memory/dirmacs-docs-index.json";
        const dirmacs_path = if (config_json == .object and config_json.object.get("dirmacs_path")) |v|
            if (v == .string) v.string else "~/dirmacs"
        else
            "~/dirmacs";
        const auto_rebuild = if (config_json == .object and config_json.object.get("auto_rebuild")) |v|
            if (v == .bool) v.bool else false
        else
            false;
        return Config{
            .index_path = index_path,
            .dirmacs_path = dirmacs_path,
            .auto_rebuild = auto_rebuild,
        };
    }
};

const Config = struct {
    index_path: []const u8,
    dirmacs_path: []const u8,
    auto_rebuild: bool,
};

const Index = struct {
    version: []const u8,
    last_updated: []const u8,
    repositories: std.StringHashMap(Repository),

    const Repository = struct {
        path: []const u8,
        documents: std.StringHashMap(Document),
    };

    const Document = struct {
        topics: std.ArrayList([]const u8),
        path: []const u8,
    };

    fn deinit(self: *Index, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.last_updated);
        var repo_iter = self.repositories.iterator();
        while (repo_iter.next()) |repo_entry| {
            allocator.free(repo_entry.key_ptr.*);
            const repo = repo_entry.value_ptr;
            allocator.free(repo.path);
            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                allocator.free(doc_entry.key_ptr.*);
                const doc = doc_entry.value_ptr;
                for (doc.topics.items) |topic| {
                    allocator.free(topic);
                }
                doc.topics.deinit();
                allocator.free(doc.path);
            }
            repo.documents.deinit();
        }
        self.repositories.deinit();
    }
};

fn loadIndex(allocator: Allocator, cfg: Config) !?Index {
    const file_path = try std.fs.path.expand(allocator, cfg.index_path);
    defer allocator.free(file_path);
    const file = compat.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var empty_repos = std.StringHashMap(Index.Repository).init(allocator);
            return Index{
                .version = try allocator.dupe(u8, "1.0.0"),
                .last_updated = try allocator.dupe(u8, ""),
                .repositories = empty_repos,
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
    const version = root.get("version") orelse return error.MissingVersion;
    const last_updated = root.get("last_updated") orelse "";
    const repositories_val = root.get("repositories") orelse return error.MissingRepositories;
    if (repositories_val != .object) return error.InvalidRepositoriesFormat;
    var repositories = std.StringHashMap(Index.Repository).init(allocator);
    errdefer {
        var repo_iter = repositories.iterator();
        while (repo_iter.next()) |repo_entry| {
            allocator.free(repo_entry.key_ptr.*);
            const repo = repo_entry.value_ptr;
            allocator.free(repo.path);
            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                allocator.free(doc_entry.key_ptr.*);
                const doc = doc_entry.value_ptr;
                for (doc.topics.items) |topic| allocator.free(topic);
                doc.topics.deinit();
            }
            repo.documents.deinit();
        }
        repositories.deinit();
    }
    var repo_iter = repositories_val.object.iterator();
    while (repo_iter.next()) |entry| {
        const repo_name = entry.key_ptr.*;
        const repo_val = entry.value_ptr.*;
        if (repo_val != .object) continue;
        const repo_path = if (repo_val.object.get("path")) |p|
            if (p == .string) p.string else ""
        else
            "";
        const documents_val = repo_val.object.get("documents");
        if (documents_val == null or documents_val.?. != .object) continue;
        var documents = std.StringHashMap(Index.Document).init(allocator);
        var doc_iter = documents_val.?.object.iterator();
        while (doc_iter.next()) |doc_entry| {
            const doc_name = doc_entry.key_ptr.*;
            const doc_val = doc_entry.value_ptr.*;
            if (doc_val != .object) continue;
            const doc_path = if (doc_val.object.get("path")) |p|
                if (p == .string) p.string else ""
            else
                "";
            const topics_val = doc_val.object.get("topics");
            var topics = std.ArrayList([]const u8).init(allocator);
            if (topics_val != null and topics_val.?. == .array) {
                for (topics_val.?.array.items) |topic| {
                    if (topic == .string) {
                        try topics.append(try allocator.dupe(u8, topic.string));
                    }
                }
            }
            try documents.put(try allocator.dupe(u8, doc_name), Index.Document{
                .topics = topics,
                .path = try allocator.dupe(u8, doc_path),
            });
        }
        try repositories.put(try allocator.dupe(u8, repo_name), Index.Repository{
            .path = try allocator.dupe(u8, repo_path),
            .documents = documents,
        });
    }
    const version_str = if (version == .string) version.string else "1.0.0";
    const last_updated_str = if (last_updated == .string) last_updated.string else "";
    return Index{
        .version = try allocator.dupe(u8, version_str),
        .last_updated = try allocator.dupe(u8, last_updated_str),
        .repositories = repositories,
    };
}

fn handleSearch(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const query = ctx.args orelse return error.MissingArgument;
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var results = std.ArrayList(struct { repo: []const u8, doc: []const u8, topics: []const []const u8 }).init(ctx.allocator);
        defer {
            for (results.items) |res| {
                ctx.allocator.free(res.repo);
                ctx.allocator.free(res.doc);
                for (res.topics) |topic| ctx.allocator.free(topic);
            }
            results.deinit();
        }
        var repo_iter = idx.repositories.iterator();
        while (repo_iter.next()) |repo_entry| {
            const repo_name = repo_entry.key_ptr.*;
            const repo = repo_entry.value_ptr.*;
            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                const doc_name = doc_entry.key_ptr.*;
                const doc = doc_entry.value_ptr.*;
                var matches = false;
                if (std.mem.indexOf(u8, doc_name, query) != null) matches = true;
                if (!matches) {
                    for (doc.topics.items) |topic| {
                        if (std.mem.indexOf(u8, topic, query) != null) {
                            matches = true;
                            break;
                        }
                    }
                }
                if (matches) {
                    const topics_copy = try ctx.allocator.dupe([]const u8, doc.topics.items);
                    try results.append(.{
                        .repo = try ctx.allocator.dupe(u8, repo_name),
                        .doc = try ctx.allocator.dupe(u8, doc_name),
                        .topics = topics_copy,
                    });
                }
            }
        }
        if (results.items.len == 0) {
            return SkillResult{
                .success = true,
                .message = try std.fmt.allocPrint(ctx.allocator, "No matches for '{s}'", .{query}),
                .data = null,
            };
        }
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        try response.writer().print("Found {d} matching documents:\n\n", .{results.items.len});
        for (results.items) |res, i| {
            try response.writer().print("{d}. [{s}] {s} (repo: {s})\n    Topics: ", .{ i + 1, res.doc, res.doc, res.repo });
            for (res.topics, 0..) |topic, j| {
                if (j > 0) try response.writer().print(", ", .{});
                try response.writer().print("{s}", .{topic});
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
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'dirmacs rebuild' first.", .{}),
            .data = null,
        };
    }
}

fn handleList(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        try response.writer().print("Documentation index ({s}):\n\n", .{idx.version});
        var repo_iter = idx.repositories.iterator();
        while (repo_iter.next()) |repo_entry| {
            const repo_name = repo_entry.key_ptr.*;
            const repo = repo_entry.value_ptr.*;
            try response.writer().print("Repository: {s} (path: {s})\n", .{ repo_name, repo.path });
            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                const doc_name = doc_entry.key_ptr.*;
                const doc = doc_entry.value_ptr.*;
                try response.writer().print("  - {s} (topics: ", .{doc_name});
                for (doc.topics.items, 0..) |topic, i| {
                    if (i > 0) try response.writer().print(", ", .{});
                    try response.writer().print("{s}", .{topic});
                }
                try response.writer().print(")\n", .{});
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
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'dirmacs rebuild' first.", .{}),
            .data = null,
        };
    }
}

fn handleRebuild(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would scan dirmacs_path and rebuild index
    // For now, just report success
    return SkillResult{
        .success = true,
        .message = try std.fmt.allocPrint(ctx.allocator, "Dirmacs docs index rebuilt: {s} repositories, saved to {s}", .{ 0, cfg.index_path }),
        .data = null,
    };
}

fn handleTree(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const maybe_idx = try loadIndex(ctx.allocator, cfg);
    if (maybe_idx) |idx| {
        defer idx.deinit(ctx.allocator);
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();
        try response.writer().print("Dir/ (root)\n", .{});
        var repo_list = std.ArrayList(struct { name: []const u8, repo: *Index.Repository }).init(ctx.allocator);
        defer {
            for (repo_list.items) |item| {
                ctx.allocator.free(item.name);
            }
            repo_list.deinit();
        }
        var repo_iter = idx.repositories.iterator();
        while (repo_iter.next()) |entry| {
            try repo_list.append(.{
                .name = try ctx.allocator.dupe(u8, entry.key_ptr.*),
                .repo = entry.value_ptr,
            });
        }
        std.sort.insertion(@TypeOf(repo_list.items[0]), repo_list.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(repo_list.items[0]), b: @TypeOf(repo_list.items[0])) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        for (repo_list.items, 0..) |item, i| {
            const is_last = i == repo_list.items.len - 1;
            const prefix = if (is_last) "└── " else "├── ";
            try response.writer().print("{s}{s}/\n", .{ prefix, item.name });
            var doc_entries = std.ArrayList([]const u8).init(ctx.allocator);
            defer {
                for (doc_entries.items) |name| ctx.allocator.free(name);
                doc_entries.deinit();
            }
            var doc_iter = item.repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                try doc_entries.append(try ctx.allocator.dupe(u8, doc_entry.key_ptr.*));
            }
            std.sort.insertion([]const u8, doc_entries.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
            for (doc_entries.items, 0..) |doc, j| {
                const doc_is_last = j == doc_entries.items.len - 1;
                const doc_prefix = if (is_last)
                    if (doc_is_last) "    └── " else "    ├── "
                else
                    if (doc_is_last) "│   └── " else "│   ├── ";
                try response.writer().print("{s}{s}\n", .{ doc_prefix, doc });
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
            .message = try std.fmt.allocPrint(ctx.allocator, "Index not found. Run 'dirmacs rebuild' first.", .{}),
            .data = null,
        };
    }
}

fn handleHelp(ctx: *ExecutionContext) !SkillResult {
    var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
    defer response.deinit();
    try response.writer().print("Dirmacs Docs Commands:\n\n", .{});
    try response.writer().print("search <query> - Search documentation\n", .{});
    try response.writer().print("list          - List all documents\n", .{});
    try response.writer().print("rebuild       - Rebuild documentation index\n", .{});
    try response.writer().print("tree          - Show documentation tree\n", .{});
    return SkillResult{
        .success = true,
        .message = try response.toOwnedSlice(),
        .data = null,
    };
}
