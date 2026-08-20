//! Webhook Server
//! HTTP server on port 9000 with HMAC token validation
//! Implements all 12 webhook endpoints from OpenClaw

const std = @import("std");
const zeptoclaw = @import("zeptoclaw");
const compat = zeptoclaw.compat;
const http = @import("http_utils.zig");
const endpoints = @import("webhook_endpoints.zig");

const log = std.log.scoped(.webhook_server);

// ============================================================================
// Server Configuration
// ============================================================================

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,
    secret: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const secret = try http.loadWebhookSecret(allocator);
        return .{
            .secret = secret,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.secret);
    }
};

// ============================================================================
// Webhook Server
// ============================================================================

pub const WebhookServer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    endpoint_ctx: endpoints.EndpointContext,
    listener: std.Io.net.Server,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, config: Config) !WebhookServer {
        const address = try std.Io.net.IpAddress.parse(config.host, config.port);
        const listener = try address.listen(compat.getIo(), .{ .reuse_address = true });

        const endpoint_ctx = try endpoints.EndpointContext.init(allocator);

        return .{
            .allocator = allocator,
            .config = config,
            .endpoint_ctx = endpoint_ctx,
            .listener = listener,
            .running = false,
        };
    }

    pub fn deinit(self: *WebhookServer) void {
        self.endpoint_ctx.deinit();
        self.listener.deinit(compat.getIo());
    }

    pub fn run(self: *WebhookServer) !void {
        self.running = true;
        log.info("Webhook server listening on {s}:{}\n", .{ self.config.host, self.config.port });

        while (self.running) {
            const connection = self.listener.accept(compat.getIo()) catch |err| {
                log.err("Failed to accept connection: {}\n", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                log.err("Error handling connection: {}\n", .{err});
            };
        }
    }

    pub fn stop(self: *WebhookServer) void {
        self.running = false;
    }

    fn handleConnection(self: *WebhookServer, connection: std.Io.net.Stream) !void {
        defer connection.close(compat.getIo());

        // Read request
        var buffer: [8192]u8 = undefined;
        var stream_reader = connection.reader(compat.getIo(), &buffer);
        const n = stream_reader.interface.readSliceShort(buffer[1..]) catch |err| {
            log.err("Failed to read request: {}\n", .{err});
            return;
        };

        if (n == 0) return;

        const request_data = buffer[0..n];

        // Parse request
        var request = http.parseHttpRequest(self.allocator, request_data) catch |err| {
            log.err("Failed to parse request: {}\n", .{err});
            try self.sendErrorResponse(connection, 400, "Bad Request");
            return;
        };
        defer request.deinit(self.allocator);

        // Extract endpoint name from path
        const endpoint_name = if (std.mem.startsWith(u8, request.path, "/"))
            request.path[1..]
        else
            request.path;

        // Find endpoint
        const endpoint = endpoints.getEndpoint(endpoint_name) orelse {
            try self.sendErrorResponse(connection, 404, "Not Found");
            return;
        };

        // Validate method
        if (!std.mem.eql(u8, request.method, endpoint.method)) {
            try self.sendErrorResponse(connection, 405, "Method Not Allowed");
            return;
        }

        // Validate auth if required
        if (endpoint.requires_auth) {
            const token = request.getHeader("X-Webhook-Token");
            http.validateWebhookToken(token, self.config.secret) catch |err| {
                log.warn("Auth failed for endpoint {s}: {}\n", .{ endpoint.name, err });
                try self.sendErrorResponse(connection, 401, "Unauthorized");
                return;
            };
        }

        // Execute endpoint
        const response = endpoint.handler(&self.endpoint_ctx, if (request.body.len > 0) request.body else null) catch |err| {
            log.err("Error executing endpoint {s}: {}\n", .{ endpoint.name, err });
            try self.sendErrorResponse(connection, 500, "Internal Server Error");
            return;
        };

        // Send response
        try self.sendResponse(connection, response);
    }

    fn sendResponse(self: *WebhookServer, stream: std.Io.net.Stream, response: http.HttpResponse) !void {
        const status_line = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} OK\r\n", .{response.status});
        defer self.allocator.free(status_line);

        const content_type_header = try std.fmt.allocPrint(self.allocator, "Content-Type: {s}\r\n", .{response.content_type});
        defer self.allocator.free(content_type_header);

        const content_length_header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n", .{response.body.len});
        defer self.allocator.free(content_length_header);

        // Write the body directly (no need to dupe)
        try compat.streamWriteAll(stream, status_line);
        try compat.streamWriteAll(stream, content_type_header);
        try compat.streamWriteAll(stream, content_length_header);
        try compat.streamWriteAll(stream, "\r\n");
        try compat.streamWriteAll(stream, response.body);

        // Free the body if it's owned
        response.deinit(self.allocator);
    }

    fn sendErrorResponse(self: *WebhookServer, stream: std.Io.net.Stream, status: u16, message: []const u8) !void {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message});
        defer self.allocator.free(body);

        const response = http.HttpResponse{
            .status = status,
            .content_type = "application/json",
            .body = body,
        };

        try self.sendResponse(stream, response);
    }
};

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var config = try Config.load(allocator);
    defer config.deinit(allocator);

    // Initialize server
    var server = try WebhookServer.init(allocator, config);
    defer server.deinit();

    // Run server
    try server.run();
}
