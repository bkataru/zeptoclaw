const std = @import("std");
const cli_utils = @import("cli_utils.zig");

pub fn StreamHandler(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8),
        writer: WriterType,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, writer: WriterType) Self {
            return .{
                .allocator = allocator,
                .buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
                .writer = writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn handleChunk(self: *Self, chunk: []const u8) !void {
            // Accumulate in buffer
            try self.buffer.appendSlice(chunk);

            // Display with streaming effect
            try cli_utils.formatStreamingToken(chunk, self.writer);
        }

        pub fn finalize(self: *Self) ![]const u8 {
            // Write final newline
            try self.writer.writeAll("\n");

            // Return copy of buffer
            return try self.allocator.dupe(u8, self.buffer.items);
        }

        pub fn getFullResponse(self: *Self) []const u8 {
            return self.buffer.items;
        }
    };
}

pub fn handleStream(
    client: anytype,
    request: anytype,
    allocator: std.mem.Allocator,
    writer: anytype,
) ![]const u8 {
    const Handler = StreamHandler(@TypeOf(writer));
    var handler = Handler.init(allocator, writer);
    defer handler.deinit();

    try client.streamCompletion(request, handler.handleChunk);
    return try handler.finalize();
}

test "StreamHandler accumulation" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit();

    const Handler = StreamHandler(@TypeOf(output.writer()));
    var handler = Handler.init(allocator, output.writer());
    defer handler.deinit();

    try handler.handleChunk("Hello");
    try handler.handleChunk(", ");
    try handler.handleChunk("world!");

    try std.testing.expectEqualStrings("Hello, world!", handler.getFullResponse());
}

test "StreamHandler final newline" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit();

    const Handler = StreamHandler(@TypeOf(output.writer()));
    var handler = Handler.init(allocator, output.writer());
    defer handler.deinit();

    try handler.handleChunk("test");
    _ = try handler.finalize();

    try std.testing.expect(std.mem.endsWith(u8, output.items, "\n"));
}
