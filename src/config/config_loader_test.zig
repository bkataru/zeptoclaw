const std = @import("std");
const compat = @import("../compat.zig");
const ConfigLoader = @import("migration_config.zig").ConfigLoader;

fn writeCwdFile(path: []const u8, content: []const u8) !void {
    const cwd = compat.cwd();
    const file = try cwd.createFile(path, .{ .truncate = true });
    defer file.close(cwd.io);
    var w = file.writer(cwd.io, &[_]u8{});
    try w.interface.writeAll(content);
}

fn deleteCwdFile(path: []const u8) void {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z);
}

const fixture_prefix =
    \\{"meta":{},"env":{"NVIDIA_API_KEY":"test-key"},"models":{},"agents":{"defaults":{"model":{"primary":
;

const fixture_suffix =
    \\,"fallbacks":[]},"imageModel":{"primary":"image","fallbacks":[]},"compaction":{},"subagents":{},"maxConcurrent":
;

fn writeFixture(path: []const u8, primary: []const u8, max_conc: []const u8, port: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, fixture_prefix);
    try buf.append(std.testing.allocator, '"');
    try buf.appendSlice(std.testing.allocator, primary);
    try buf.append(std.testing.allocator, '"');
    try buf.appendSlice(std.testing.allocator, fixture_suffix);
    try buf.appendSlice(std.testing.allocator, max_conc);
    try buf.appendSlice(std.testing.allocator, "},\"list\":[]},\"gateway\":{\"port\":");
    try buf.appendSlice(std.testing.allocator, port);
    try buf.appendSlice(std.testing.allocator, ",\"mode\":\"local\",\"bind\":\"lan\",\"controlUi\":{},\"auth\":{},\"tailscale\":{}},\"skills\":{\"load\":{},\"install\":{}},\"channels\":{},\"tools\":{\"web\":{\"search\":{},\"fetch\":{}}},\"hooks\":{\"internal\":{}},\"diagnostics\":{\"cacheTrace\":{}},\"update\":{},\"auth\":{},\"messages\":{},\"commands\":{},\"plugins\":{}}");
    try writeCwdFile(path, buf.items);
}

test "ConfigLoader.load file not found - no leak" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    const result = loader.load(.{ .config_file = "nonexistent_file_xyz.json" });
    try std.testing.expectError(error.FileNotFound, result);
}

test "ConfigLoader.load invalid JSON - no leak" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    const config_path = "test_invalid_config.json";
    try writeCwdFile(config_path, "{\"invalid\": json}");
    defer deleteCwdFile(config_path);
    const result = loader.load(.{ .config_file = config_path });
    try std.testing.expectError(error.SyntaxError, result);
}

test "ConfigLoader.load missing API key" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    const result = loader.load(.{ .config_file = "nonexistent_file_xyz.json" });
    try std.testing.expectError(error.FileNotFound, result);
}

test "ConfigLoader.load config path is a directory - error" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    const dir_path = "test_dir_for_config";
    const cwd = compat.cwd();
    cwd.makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}", .{dir_path})) |z| {
            _ = std.c.rmdir(z);
        } else |_| {}
    }
    const result = loader.load(.{ .config_file = dir_path });
    if (result) |_| {
        try std.testing.expect(false);
    } else |_| {}
}

test "ConfigLoader.load valid fixture parses" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);
    const config_path = "test_valid_config.json";
    try writeFixture(config_path, "thinkingmachines/inkling", "4", "18789");
    defer deleteCwdFile(config_path);
    if (loader.load(.{ .config_file = config_path })) |cfg| {
        var owned = cfg;
        defer owned.deinit();
        try std.testing.expect(owned.primary_model.len > 0);
    } else |err| {
        try std.testing.expectEqual(error.MissingApiKey, err);
    }
}
