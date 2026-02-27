const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    var config: Config = .{};
    var data: ?Data = null;

    const Config = struct {
        data_file: []const u8 = "memory/interesting-finds.json",
        max_finds: usize = 100,
        auto_share_threshold: ?usize = null,
    };

    const Data = struct {
        finds: std.ArrayList(Find),
        config: DataConfig,

        const Find = struct {
            id: []const u8,
            type: []const u8,
            title: []const u8,
            url: []const u8,
            description: []const u8,
            tags: std.ArrayList([]const u8),
            found_at: []const u8,
            source: []const u8,
            shared: bool,
            shared_at: ?[]const u8,
        };

        const DataConfig = struct {
            max_finds: usize,
            auto_share_threshold: ?usize,
        };
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        if (config_value == .object) {
            if (config_value.object.get("data_file")) |v| {
                if (v == .string) {
                    config.data_file = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("max_finds")) |v| {
                if (v == .integer) {
                    config.max_finds = @intCast(v.integer);
                }
            }
            if (config_value.object.get("auto_share_threshold")) |v| {
                if (v == .integer) {
                    config.auto_share_threshold = @intCast(v.integer);
                } else if (v == .null) {
                    config.auto_share_threshold = null;
                }
            }
        }

        // Load data
        try loadData(allocator);
    }

    fn loadData(allocator: Allocator) !void {
        const file_path = try std.fs.path.expand(allocator, config.data_file);
        defer allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Data file doesn't exist yet, create empty data
                data = Data{
                    .finds = std.ArrayList(Data.Find).initCapacity(allocator, 0) catch unreachable,
                    .config = Data.DataConfig{
                        .max_finds = config.max_finds,
                        .auto_share_threshold = config.auto_share_threshold,
                    },
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

        if (parsed.value != .object) return error.InvalidDataFormat;

        const root = parsed.value.object;

        const finds_val = root.get("finds") orelse return error.MissingFinds;
        const config_val = root.get("config") orelse return error.MissingConfig;

        if (finds_val != .array or config_val != .object) return error.InvalidDataFormat;

        var finds = std.ArrayList(Data.Find).initCapacity(allocator, 0) catch unreachable;

        for (finds_val.array.items) |find_val| {
            if (find_val != .object) continue;

            const find_obj = find_val.object;

            const id = if (find_obj.get("id")) |v| if (v == .string) v.string else "" else "";
            const type_val = if (find_obj.get("type")) |v| if (v == .string) v.string else "other" else "other";
            const title = if (find_obj.get("title")) |v| if (v == .string) v.string else "" else "";
            const url = if (find_obj.get("url")) |v| if (v == .string) v.string else "" else "";
            const description = if (find_obj.get("description")) |v| if (v == .string) v.string else "" else "";
            const found_at = if (find_obj.get("foundAt")) |v| if (v == .string) v.string else "" else "";
            const source = if (find_obj.get("source")) |v| if (v == .string) v.string else "manual" else "manual";
            const shared = if (find_obj.get("shared")) |v| if (v == .bool) v.bool else false else false;
            const shared_at = if (find_obj.get("sharedAt")) |v|
                if (v == .string) v.string else null
            else
                null;

            var tags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
            const tags_val = find_obj.get("tags");
            if (tags_val != null and tags_val.?. == .array) {
                for (tags_val.?.array.items) |tag| {
                    if (tag == .string) {
                        try tags.append(try allocator.dupe(u8, tag.string));
                    }
                }
            }

            try finds.append(Data.Find{
                .id = try allocator.dupe(u8, id),
                .type = try allocator.dupe(u8, type_val),
                .title = try allocator.dupe(u8, title),
                .url = try allocator.dupe(u8, url),
                .description = try allocator.dupe(u8, description),
                .tags = tags,
                .found_at = try allocator.dupe(u8, found_at),
                .source = try allocator.dupe(u8, source),
                .shared = shared,
                .shared_at = if (shared_at) |s| try allocator.dupe(u8, s) else null,
            });
        }

        const config_obj = config_val.object;
        const max_finds = if (config_obj.get("maxFinds")) |v|
            if (v == .integer) @intCast(v.integer) else config.max_finds
        else
            config.max_finds;
        const auto_share_threshold = if (config_obj.get("autoShareThreshold")) |v|
            if (v == .integer) @intCast(v.integer) else null
        else
            config.auto_share_threshold;

        data = Data{
            .finds = finds,
            .config = Data.DataConfig{
                .max_finds = max_finds,
                .auto_share_threshold = auto_share_threshold,
            },
        };
    }

    fn saveData(allocator: Allocator) !void {
        if (data == null) return;

        const file_path = try std.fs.path.expand(allocator, config.data_file);
        defer allocator.free(file_path);

        const dir = std.fs.path.dirname(file_path) orelse ".";
        try std.fs.cwd().makePath(dir);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("{\n  \"finds\": [\n");

        for (data.?.finds.items, 0..) |find, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.print("      \"id\": \"{s}\",\n", .{find.id});
            try writer.print("      \"type\": \"{s}\",\n", .{find.type});
            try writer.print("      \"title\": \"{s}\",\n", .{find.title});
            try writer.print("      \"url\": \"{s}\",\n", .{find.url});
            try writer.print("      \"description\": \"{s}\",\n", .{find.description});
            try writer.writeAll("      \"tags\": [");
            for (find.tags.items, 0..) |tag, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{tag});
            }
            try writer.writeAll("],\n");
            try writer.print("      \"foundAt\": \"{s}\",\n", .{find.found_at});
            try writer.print("      \"source\": \"{s}\",\n", .{find.source});
            try writer.print("      \"shared\": {s},\n", .{if (find.shared) "true" else "false"});
            if (find.shared_at) |sa| {
                try writer.print("      \"sharedAt\": \"{s}\"\n", .{sa});
            } else {
                try writer.writeAll("      \"sharedAt\": null\n");
            }
            try writer.writeAll("    }");
        }

        try writer.writeAll("\n  ],\n  \"config\": {\n");
        try writer.print("    \"maxFinds\": {d},\n", .{data.?.config.max_finds});
        if (data.?.config.auto_share_threshold) |threshold| {
            try writer.print("    \"autoShareThreshold\": {d}\n", .{threshold});
        } else {
            try writer.writeAll("    \"autoShareThreshold\": null\n");
        }
        try writer.writeAll("  }\n}\n");
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "add")) {
            return handleAdd(ctx);
        } else if (std.mem.eql(u8, command, "list")) {
            return handleList(ctx);
        } else if (std.mem.eql(u8, command, "search")) {
            return handleSearch(ctx);
        } else if (std.mem.eql(u8, command, "mark-shared")) {
            return handleMarkShared(ctx);
        } else if (std.mem.eql(u8, command, "delete")) {
            return handleDelete(ctx);
        } else if (std.mem.eql(u8, command, "stats")) {
            return handleStats(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleAdd(ctx: *ExecutionContext) !SkillResult {
        const title = ctx.args orelse return error.MissingArgument;

        // Parse flags from args (simplified - in real implementation would use proper flag parsing)
        var url: []const u8 = "";
        var type_val: []const u8 = "other";
        var tags_str: []const u8 = "";
        var why: []const u8 = "";

        // Simple parsing - look for --url, --type, --tags, --why
        var iter = std.mem.splitScalar(u8, title, ' ');
        const actual_title = iter.next() orelse return error.MissingArgument;

        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--url")) {
                url = iter.next() orelse "";
            } else if (std.mem.eql(u8, arg, "--type")) {
                type_val = iter.next() orelse "other";
            } else if (std.mem.eql(u8, arg, "--tags")) {
                tags_str = iter.next() orelse "";
            } else if (std.mem.eql(u8, arg, "--why")) {
                why = iter.next() orelse "";
            }
        }

        // Generate UUID (simplified)
        const uuid = try generateUuid(ctx.allocator);

        // Parse tags
        var tags = std.ArrayList([]const u8).initCapacity(ctx.allocator, 0) catch unreachable;
        var tag_iter = std.mem.splitScalar(u8, tags_str, ',');
        while (tag_iter.next()) |tag| {
            const trimmed = std.mem.trim(u8, tag, " ");
            if (trimmed.len > 0) {
                try tags.append(try ctx.allocator.dupe(u8, trimmed));
            }
        }

        // Get current timestamp
        const timestamp = try getTimestamp(ctx.allocator);

        // Add find
        try data.?.finds.append(Data.Find{
            .id = uuid,
            .type = try ctx.allocator.dupe(u8, type_val),
            .title = try ctx.allocator.dupe(u8, actual_title),
            .url = try ctx.allocator.dupe(u8, url),
            .description = try ctx.allocator.dupe(u8, why),
            .tags = tags,
            .found_at = timestamp,
            .source = try ctx.allocator.dupe(u8, "manual"),
            .shared = false,
            .shared_at = null,
        });

        // Prune if over limit
        while (data.?.finds.items.len > data.?.config.max_finds) {
            const removed = data.?.finds.orderedRemove(0);
            ctx.allocator.free(removed.id);
            ctx.allocator.free(removed.type);
            ctx.allocator.free(removed.title);
            ctx.allocator.free(removed.url);
            ctx.allocator.free(removed.description);
            for (removed.tags.items) |tag| {
                ctx.allocator.free(tag);
            }
            removed.tags.deinit();
            ctx.allocator.free(removed.found_at);
            ctx.allocator.free(removed.source);
            if (removed.shared_at) |sa| {
                ctx.allocator.free(sa);
            }
        }

        // Save
        try saveData(ctx.allocator);

        return SkillResult{
            .success = true,
            .message = try std.fmt.allocPrint(ctx.allocator, "Added discovery: {s}\nID: {s}", .{ actual_title, uuid }),
            .data = null,
        };
    }

    fn handleList(ctx: *ExecutionContext) !SkillResult {
        const unshared_only = ctx.flags != null and std.mem.indexOf(u8, ctx.flags.?, "unshared") != null;

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        var count: usize = 0;
        for (data.?.finds.items) |find| {
            if (unshared_only and find.shared) continue;
            count += 1;
        }

        try response.writer().print("Recent discoveries ({d} total):\n\n", .{count});

        var idx: usize = 0;
        for (data.?.finds.items) |find| {
            if (unshared_only and find.shared) continue;

            idx += 1;
            try response.writer().print("{d}. {s} [{s}]\n", .{ idx, find.title, find.type });
            try response.writer().print("   URL: {s}\n", .{find.url});
            try response.writer().print("   Tags: ", .{});
            for (find.tags.items, 0..) |tag, j| {
                if (j > 0) try response.writer().print(", ", .{});
                try response.writer().print("{s}", .{tag});
            }
            try response.writer().print("\n", .{});
            try response.writer().print("   Found: {s}\n", .{find.found_at});
            try response.writer().print("   Source: {s}\n", .{find.source});
            try response.writer().print("   Why: {s}\n", .{find.description});
            try response.writer().print("   Shared: {s}\n\n", .{if (find.shared) "Yes" else "No"});
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleSearch(ctx: *ExecutionContext) !SkillResult {
        const query = ctx.args orelse return error.MissingArgument;

        var matches = std.ArrayList(usize).initCapacity(ctx.allocator, 0) catch unreachable;

        for (data.?.finds.items, 0..) |find, i| {
            var found = false;
            if (std.mem.indexOf(u8, find.title, query) != null) found = true;
            if (std.mem.indexOf(u8, find.description, query) != null) found = true;
            for (find.tags.items) |tag| {
                if (std.mem.indexOf(u8, tag, query) != null) {
                    found = true;
                    break;
                }
            }
            if (found) try matches.append(i);
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
            const find = data.?.finds.items[idx];
            try response.writer().print("{d}. {s} [{s}]\n", .{ i + 1, find.title, find.type });
            try response.writer().print("   Tags: ", .{});
            for (find.tags.items, 0..) |tag, j| {
                if (j > 0) try response.writer().print(", ", .{});
                try response.writer().print("{s}", .{tag});
            }
            try response.writer().print("\n", .{});
            try response.writer().print("   Why: {s}\n\n", .{find.description});
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleMarkShared(ctx: *ExecutionContext) !SkillResult {
        const id = ctx.args orelse return error.MissingArgument;

        for (data.?.finds.items) |*find| {
            if (std.mem.eql(u8, find.id, id)) {
                find.shared = true;
                const timestamp = try getTimestamp(ctx.allocator);
                find.shared_at = timestamp;

                try saveData(ctx.allocator);

                return SkillResult{
                    .success = true,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Marked as shared: {s}", .{find.title}),
                    .data = null,
                };
            }
        }

        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Find not found: {s}", .{id}),
            .data = null,
        };
    }

    fn handleDelete(ctx: *ExecutionContext) !SkillResult {
        const id = ctx.args orelse return error.MissingArgument;

        for (data.?.finds.items, 0..) |find, i| {
            if (std.mem.eql(u8, find.id, id)) {
                const removed = data.?.finds.orderedRemove(i);

                ctx.allocator.free(removed.id);
                ctx.allocator.free(removed.type);
                ctx.allocator.free(removed.title);
                ctx.allocator.free(removed.url);
                ctx.allocator.free(removed.description);
                for (removed.tags.items) |tag| {
                    ctx.allocator.free(tag);
                }
                removed.tags.deinit();
                ctx.allocator.free(removed.found_at);
                ctx.allocator.free(removed.source);
                if (removed.shared_at) |sa| {
                    ctx.allocator.free(sa);
                }

                try saveData(ctx.allocator);

                return SkillResult{
                    .success = true,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Deleted: {s}", .{removed.title}),
                    .data = null,
                };
            }
        }

        return SkillResult{
            .success = false,
            .message = try std.fmt.allocPrint(ctx.allocator, "Find not found: {s}", .{id}),
            .data = null,
        };
    }

    fn handleStats(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        var total: usize = data.?.finds.items.len;
        var unshared: usize = 0;
        var shared: usize = 0;

        var type_counts = std.StringHashMap(usize).init(ctx.allocator);
        defer {
            var iter = type_counts.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
            }
            type_counts.deinit();
        }

        var source_counts = std.StringHashMap(usize).init(ctx.allocator);
        defer {
            var iter = source_counts.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
            }
            source_counts.deinit();
        }

        var tag_counts = std.StringHashMap(usize).init(ctx.allocator);
        defer {
            var iter = tag_counts.iterator();
            while (iter.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
            }
            tag_counts.deinit();
        }

        for (data.?.finds.items) |find| {
            if (find.shared) {
                shared += 1;
            } else {
                unshared += 1;
            }

            const type_count = try type_counts.getOrPut(try ctx.allocator.dupe(u8, find.type));
            if (!type_count.found_existing) {
                type_count.value_ptr.* = 0;
            }
            type_count.value_ptr.* += 1;

            const source_count = try source_counts.getOrPut(try ctx.allocator.dupe(u8, find.source));
            if (!source_count.found_existing) {
                source_count.value_ptr.* = 0;
            }
            source_count.value_ptr.* += 1;

            for (find.tags.items) |tag| {
                const tag_count = try tag_counts.getOrPut(try ctx.allocator.dupe(u8, tag));
                if (!tag_count.found_existing) {
                    tag_count.value_ptr.* = 0;
                }
                tag_count.value_ptr.* += 1;
            }
        }

        try response.writer().print("Discovery Statistics:\n", .{});
        try response.writer().print("  Total finds: {d}\n", .{total});
        try response.writer().print("  Unshared: {d}\n", .{unshared});
        try response.writer().print("  Shared: {d}\n\n", .{shared});

        try response.writer().print("  By type:\n", .{});
        var type_iter = type_counts.iterator();
        while (type_iter.next()) |entry| {
            try response.writer().print("    {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try response.writer().print("\n  By source:\n", .{});
        var source_iter = source_counts.iterator();
        while (source_iter.next()) |entry| {
            try response.writer().print("    {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try response.writer().print("\n  Top tags:\n", .{});
        var tag_list = std.ArrayList(struct {
            tag: []const u8,
            count: usize,
        }).init(ctx.allocator);
        defer {
            for (tag_list.items) |item| {
                ctx.allocator.free(item.tag);
            }
            tag_list.deinit();
        }

        var tag_iter = tag_counts.iterator();
        while (tag_iter.next()) |entry| {
            try tag_list.append(.{
                .tag = try ctx.allocator.dupe(u8, entry.key_ptr.*),
                .count = entry.value_ptr.*,
            });
        }

        // Sort by count
        std.sort.insertion(struct { tag: []const u8, count: usize }, tag_list.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(tag_list.items[0]), b: @TypeOf(tag_list.items[0])) bool {
                return a.count > b.count;
            }
        }.lessThan);

        for (tag_list.items, 0..) |item, i| {
            if (i >= 5) break;
            try response.writer().print("    {s}: {d}\n", .{ item.tag, item.count });
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

        try response.writer().print("Discovery Commands:\n\n", .{});
        try response.writer().print("add <title> --url <url> --type <type> --tags <tags> --why <desc>  - Add a discovery\n", .{});
        try response.writer().print("list [--unshared]                                            - List discoveries\n", .{});
        try response.writer().print("search <query>                                              - Search discoveries\n", .{});
        try response.writer().print("mark-shared <id>                                           - Mark as shared\n", .{});
        try response.writer().print("delete <id>                                                - Delete a discovery\n", .{});
        try response.writer().print("stats                                                      - Show statistics\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn generateUuid(allocator: Allocator) ![]const u8 {
        // Simple UUID v4 generation
        var uuid: [36]u8 = undefined;
        const hex_chars = "0123456789abcdef";

        var i: usize = 0;
        while (i < 36) : (i += 1) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                uuid[i] = '-';
            } else {
                const byte = std.crypto.random.intRangeAtMost(u8, 0, 15);
                uuid[i] = hex_chars[byte];
            }
        }

        return allocator.dupe(u8, &uuid);
    }

    fn getTimestamp(allocator: Allocator) ![]const u8 {
        const now = std.time.timestamp();
        const datetime = std.time.epoch.EpochSeconds{ .secs = now };
        const year = datetime.getEpochYear();
        const month = datetime.getMonth();
        const day = datetime.getDayOfMonth();
        const hour = datetime.getHoursIntoDay();
        const minute = datetime.getMinutesIntoHour();
        const second = datetime.getSecondsIntoMinute();

        return std.fmt.allocPrint(allocator, "{d:04}-{d:02}-{d:02}T{d:02}:{d:02}:{d:02}Z", .{
            year, @intFromEnum(month), day, hour, minute, second,
        });
    }

    pub fn deinit(allocator: Allocator) void {
        if (data) |*d| {
            for (d.finds.items) |find| {
                allocator.free(find.id);
                allocator.free(find.type);
                allocator.free(find.title);
                allocator.free(find.url);
                allocator.free(find.description);
                for (find.tags.items) |tag| {
                    allocator.free(tag);
                }
                find.tags.deinit();
                allocator.free(find.found_at);
                allocator.free(find.source);
                if (find.shared_at) |sa| {
                    allocator.free(sa);
                }
            }
            d.finds.deinit();
        }

        if (!std.mem.eql(u8, config.data_file, "memory/interesting-finds.json")) {
            allocator.free(config.data_file);
        }
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "discovery",
            .version = "1.0.0",
            .description = "Interesting finds aggregation — track repos, articles, tools discovered during heartbeats, browsing, or conversations.",
            .author = "Baala Kataru",
            .category = "productivity",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "discovery", "finds", "interesting" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*interesting.*", ".*found.*", ".*discovered.*" },
                },
            },
        };
    }
};
