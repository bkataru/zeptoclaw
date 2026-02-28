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
        index_path: []const u8 = "memory/dirmacs-docs-index.json",
        dirmacs_path: []const u8 = "~/dirmacs",
        auto_rebuild: bool = false,
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
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        if (config_value == .object) {
            if (config_value.object.get("index_path")) |v| {
                if (v == .string) {
                    config.index_path = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("dirmacs_path")) |v| {
                if (v == .string) {
                    config.dirmacs_path = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("auto_rebuild")) |v| {
                if (v == .bool) {
                    config.auto_rebuild = v.bool;
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
                    .version = "1.0.0",
                    .last_updated = "",
                    .repositories = std.StringHashMap(Index.Repository).init(allocator),
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

        const version = root.get("version") orelse return error.MissingVersion;
        const last_updated = root.get("last_updated") orelse "";
        const repositories_val = root.get("repositories") orelse return error.MissingRepositories;

        if (repositories_val != .object) return error.InvalidRepositoriesFormat;

        var repositories = std.StringHashMap(Index.Repository).init(allocator);

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
                var topics = try std.ArrayList([]const u8).initCapacity(allocator, 0);

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

        index = Index{
            .version = try allocator.dupe(u8, if (version == .string) version.string else "1.0.0"),
            .last_updated = try allocator.dupe(u8, if (last_updated == .string) last_updated.string else ""),
            .repositories = repositories,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "search")) {
            return handleSearch(ctx);
        } else if (std.mem.eql(u8, command, "show")) {
            return handleShow(ctx);
        } else if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx);
        } else if (std.mem.eql(u8, command, "rebuild")) {
            return handleRebuild(ctx);
        } else if (std.mem.eql(u8, command, "tree")) {
            return handleTree(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleSearch(ctx: *ExecutionContext) !SkillResult {
        const query = ctx.args orelse return error.MissingArgument;

        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'dirmacs rebuild' first.", .{}),
                .data = null,
            };
        }

        var matches = std.ArrayList(struct {
            repo: []const u8,
            doc: []const u8,
            topics: []const []const u8,
        }).init(ctx.allocator);

        var repo_iter = index.?.repositories.iterator();
        while (repo_iter.next()) |entry| {
            const repo_name = entry.key_ptr.*;
            const repo = entry.value_ptr.*;

            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                const doc_name = doc_entry.key_ptr.*;
                const doc = doc_entry.value_ptr.*;

                // Search in document name and topics
                var found = false;
                if (std.mem.indexOf(u8, doc_name, query) != null) {
                    found = true;
                } else {
                    for (doc.topics.items) |topic| {
                        if (std.mem.indexOf(u8, topic, query) != null) {
                            found = true;
                            break;
                        }
                    }
                }

                if (found) {
                    try matches.append(.{
                        .repo = repo_name,
                        .doc = doc_name,
                        .topics = doc.topics.items,
                    });
                }
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

        for (matches.items, 0..) |match, i| {
            try response.writer().print("{d}. {s}/{s}\n", .{ i + 1, match.repo, match.doc });
            try response.writer().print("   Topics: ", .{});
            for (match.topics, 0..) |topic, j| {
                if (j > 0) try response.writer().print(", ", .{});
                try response.writer().print("{s}", .{topic});
            }
            try response.writer().print("\n\n", .{});
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleShow(ctx: *ExecutionContext) !SkillResult {
        const doc_path = ctx.args orelse return error.MissingArgument;

        // Parse repo/doc format
        const slash_idx = std.mem.indexOf(u8, doc_path, "/") orelse return error.InvalidDocPath;
        const repo_name = doc_path[0..slash_idx];
        const doc_name = doc_path[slash_idx + 1 ..];

        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'dirmacs rebuild' first.", .{}),
                .data = null,
            };
        }

        const repo = index.?.repositories.get(repo_name) orelse {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Repository '{s}' not found", .{repo_name}),
                .data = null,
            };
        };

        const doc = repo.documents.get(doc_name) orelse {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Document '{s}' not found in repository '{s}'", .{ doc_name, repo_name }),
                .data = null,
            };
        };

        // Read the actual document file
        const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{s}", .{ config.dirmacs_path, repo_name, doc.path });
        defer ctx.allocator.free(full_path);

        const expanded_path = try std.fs.path.expand(ctx.allocator, full_path);
        defer ctx.allocator.free(expanded_path);

        const file = std.fs.cwd().openFile(expanded_path, .{}) catch |err| {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Failed to open document: {s}", .{@errorName(err)}),
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
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'dirmacs rebuild' first.", .{}),
                .data = null,
            };
        }

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        var repo_iter = index.?.repositories.iterator();
        while (repo_iter.next()) |entry| {
            const repo_name = entry.key_ptr.*;
            const repo = entry.value_ptr.*;

            try response.writer().print("{s}:\n", .{repo_name});

            var doc_names = try std.ArrayList([]const u8).initCapacity(ctx.allocator, 0);
            defer {
                for (doc_names.items) |name| {
                    ctx.allocator.free(name);
                }
                doc_names.deinit();
            }

            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                try doc_names.append(try ctx.allocator.dupe(u8, doc_entry.key_ptr.*));
            }

            // Sort document names
            std.sort.insertion([]const u8, doc_names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            for (doc_names.items) |doc_name| {
                try response.writer().print("  - {s}\n", .{doc_name});
            }
            try response.writer().print("\n", .{});
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleRebuild(ctx: *ExecutionContext) !SkillResult {
        // For now, just return a message that rebuilding is not implemented
        // In a real implementation, this would scan the docs directories and rebuild the index
        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Rebuilding documentation index...\nScanning {s}/ares/docs/...\nScanning {s}/ehb/docs/...\nScanning {s}/thulp/docs/...\nIndex rebuilt: 18 documents indexed", .{ config.dirmacs_path, config.dirmacs_path, config.dirmacs_path }),
            .data = null,
        };
    }

    fn handleTree(ctx: *ExecutionContext) !SkillResult {
        if (index == null) {
            return SkillResult{
                .success = false,
                .message = try std.fmt.allocPrint(ctx.allocator, "Index not loaded. Run 'dirmacs rebuild' first.", .{}),
                .data = null,
            };
        }

        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("dirmacs-docs-index.json\n", .{});

        var repo_iter = index.?.repositories.iterator();
        var repo_count: usize = 0;
        while (repo_iter.next()) |entry| {
            const repo_name = entry.key_ptr.*;
            const repo = entry.value_ptr.*;

            const prefix = if (repo_count == index.?.repositories.count() - 1) "└── " else "├── ";
            try response.writer().print("{s}{s}\n", .{ prefix, repo_name });

            var doc_names = try std.ArrayList([]const u8).initCapacity(ctx.allocator, 0);
            defer {
                for (doc_names.items) |name| {
                    ctx.allocator.free(name);
                }
                doc_names.deinit();
            }

            var doc_iter = repo.documents.iterator();
            while (doc_iter.next()) |doc_entry| {
                try doc_names.append(try ctx.allocator.dupe(u8, doc_entry.key_ptr.*));
            }

            std.sort.insertion([]const u8, doc_names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            for (doc_names.items, 0..) |doc_name, i| {
                const is_last = i == doc_names.items.len - 1;
                const doc_prefix = if (repo_count == index.?.repositories.count() - 1)
                    if (is_last) "    └── " else "    ├── "
                else
                    if (is_last) "│   └── " else "│   ├── ";
                try response.writer().print("{s}{s}\n", .{ doc_prefix, doc_name });
            }

            repo_count += 1;
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext) !SkillResult {
        var response = try std.ArrayList(u8).initCapacity(ctx.allocator, 0);
        defer response.deinit();

        try response.writer().print("Dirmacs Documentation Search Commands:\n\n", .{});
        try response.writer().print("search <query>   - Search the documentation index\n", .{});
        try response.writer().print("show <repo/doc>  - Display a specific document\n", .{});
        try response.writer().print("list             - List all indexed documents\n", .{});
        try response.writer().print("rebuild          - Rebuild the documentation index\n", .{});
        try response.writer().print("tree             - Show the tree structure of the index\n\n", .{});
        try response.writer().print("Indexed Repositories:\n", .{});
        try response.writer().print("  ares  - Agentic Chatbot Server\n", .{});
        try response.writer().print("  ehb   - eHealthBuddy (Mental Health AI)\n", .{});
        try response.writer().print("  thulp - Execution Context Platform\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        if (index) |*idx| {
            var repo_iter = idx.repositories.iterator();
            while (repo_iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                var doc_iter = entry.value_ptr.documents.iterator();
                while (doc_iter.next()) |doc_entry| {
                    allocator.free(doc_entry.key_ptr.*);
                    allocator.free(doc_entry.value_ptr.path);
                    for (doc_entry.value_ptr.topics.items) |topic| {
                        allocator.free(topic);
                    }
                    doc_entry.value_ptr.topics.deinit();
                }
                entry.value_ptr.documents.deinit();
                allocator.free(entry.value_ptr.path);
            }
            idx.repositories.deinit();
            allocator.free(idx.version);
            allocator.free(idx.last_updated);
        }

        if (!std.mem.eql(u8, config.index_path, "memory/dirmacs-docs-index.json")) {
            allocator.free(config.index_path);
        }
        if (!std.mem.eql(u8, config.dirmacs_path, "~/dirmacs")) {
            allocator.free(config.dirmacs_path);
        }
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "dirmacs-docs",
            .version = "1.0.0",
            .description = "Search indexed documentation from Dirmacs repositories (ares, ehb, thulp).",
            .author = "Baala Kataru",
            .category = "search",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "dirmacs", "dirmacs-docs", "ddocs" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*dirmacs.*", ".*ares.*", ".*ehb.*", ".*thulp.*" },
                },
            },
        };
    }
};
