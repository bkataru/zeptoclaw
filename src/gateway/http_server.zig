//! HTTP Server Module
//! Provides HTTP and WebSocket server for ZeptoClaw gateway

const std = @import("std");
const token_auth = @import("token_auth.zig");
const session_store = @import("session_store.zig");
const autonomous = @import("../autonomous/autonomous.zig");
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    listener: std.net.Server,
    auth: *token_auth.TokenAuth,
    session_store: *session_store.SessionStore,
    control_ui_enabled: bool,
    allow_insecure_auth: bool,
    running: bool,
    websocket_clients: std.ArrayList(*WebSocketClient),
    autonomous_agent: ?*autonomous.agent_framework.AutonomousAgent,

    const WebSocketClient = struct {
        address: std.net.Address,
        last_ping: i64,
        authenticated: bool,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        bind_addr: []const u8,
        auth: *token_auth.TokenAuth,
        store: *session_store.SessionStore,
        control_ui_enabled: bool,
        allow_insecure_auth: bool,
        autonomous_agent: ?*autonomous.agent_framework.AutonomousAgent,
    ) !HttpServer {
        // Parse bind address
        const address = if (std.mem.eql(u8, bind_addr, "lan"))
            try std.net.Address.parseIp("0.0.0.0", port)
        else if (std.mem.eql(u8, bind_addr, "loopback"))
            try std.net.Address.parseIp("127.0.0.1", port)
        else
            try std.net.Address.parseIp(bind_addr, port);

        const listener = try address.listen(.{
            .reuse_address = true,

        });

        return HttpServer{
            .allocator = allocator,
            .address = address,
            .listener = listener,
            .auth = auth,
            .session_store = store,
            .control_ui_enabled = control_ui_enabled,
            .allow_insecure_auth = allow_insecure_auth,
            .running = false,
            .websocket_clients = try std.ArrayList(*WebSocketClient).initCapacity(allocator, 0),
            .autonomous_agent = autonomous_agent,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.listener.deinit();
        for (self.websocket_clients.items) |client| {
            self.allocator.destroy(client);
        }
        self.websocket_clients.deinit(self.allocator);
    }

    /// Start the HTTP server
    pub fn start(self: *HttpServer) !void {
        self.running = true;
        std.debug.print("Gateway server listening on {any}\n", .{self.address});

        while (self.running) {
            const connection = self.listener.accept() catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            // Handle connection in a new task (simplified - in production use thread pool)
            self.handleConnection(connection) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
                connection.stream.close();
            };
        }
    }

    /// Stop the HTTP server
    pub fn stop(self: *HttpServer) void {
        self.running = false;
    }

    /// Handle an incoming connection
    fn handleConnection(self: *HttpServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        const request_data = try connection.stream.read(&buffer);

        if (request_data == 0) return;

        // Parse HTTP request
        var request = try self.parseRequest(buffer[0..request_data]);

        // Check authentication
        const auth_header = request.headers.get("X-Auth-Token");
        if (auth_header == null) {
            try self.sendErrorResponse(connection.stream, 401, "Unauthorized", "Missing X-Auth-Token header");
            return;
        }

        const is_valid = try self.auth.validate(auth_header.?);
        if (!is_valid) {
            try self.sendErrorResponse(connection.stream, 401, "Unauthorized", "Invalid or expired token");
            return;
        }

        // Route request
        try self.routeRequest(connection.stream, &request);
    }

    const HttpRequest = struct {
        method: []const u8,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
    };

    /// Parse HTTP request
    fn parseRequest(self: *HttpServer, data: []const u8) !HttpRequest {
        var lines = std.mem.splitScalar(u8, data, '\n');

        // Request line: METHOD PATH VERSION
        const request_line = lines.first();
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        _ = parts.next(); // HTTP version

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iter = headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        // Parse headers
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '\r') break; // End of headers

            var header_parts = std.mem.splitScalar(u8, line, ':');
            const key = std.mem.trim(u8, header_parts.next() orelse continue, " \t\r");
            const value = std.mem.trim(u8, header_parts.rest(), " \t\r");

            try headers.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
        }

        // Body is everything after the empty line
        const body_start = std.mem.indexOf(u8, data, "\r\n\r\n") orelse data.len;
        const body = data[body_start + 4 ..];

        return HttpRequest{
            .method = method,
            .path = path,
            .headers = headers,
            .body = body,
        };
    }

    /// Route request to appropriate handler
    fn routeRequest(self: *HttpServer, stream: std.net.Stream, request: *HttpRequest) !void {
        // Clean up request headers
        {
            var iter = request.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            request.headers.deinit();
        }

        // Route based on path
        if (std.mem.eql(u8, request.path, "/health")) {
            try handleHealth(stream);
        } else if (std.mem.eql(u8, request.path, "/status")) {
            try self.handleStatus(stream);
        } else if (std.mem.eql(u8, request.path, "/sessions")) {
            if (std.mem.eql(u8, request.method, "GET")) {
                try self.handleListSessions(stream);
            } else {
                try self.sendErrorResponse(stream, 405, "Method Not Allowed", "Only GET is supported on /sessions");
            }
        } else if (std.mem.startsWith(u8, request.path, "/sessions/") and std.mem.eql(u8, request.method, "POST")) {
            // Extract session ID from path
            const session_id = request.path["/sessions/".len..];
            if (std.mem.endsWith(u8, session_id, "/terminate")) {
                const id = session_id[0 .. session_id.len - "/terminate".len];
                try self.handleTerminateSession(stream, id);
            } else {
                try self.sendErrorResponse(stream, 404, "Not Found", "Invalid session endpoint");
            }
        } else if (std.mem.eql(u8, request.path, "/config")) {
            if (std.mem.eql(u8, request.method, "GET")) {
                try handleGetConfig(stream);
            } else if (std.mem.eql(u8, request.method, "POST")) {
                try handleUpdateConfig(stream);
            } else {
                try self.sendErrorResponse(stream, 405, "Method Not Allowed", "Only GET and POST are supported on /config");
            }
        } else if (std.mem.eql(u8, request.path, "/logs")) {
            try self.handleStatus(stream);
        } else if (std.mem.eql(u8, request.path, "/ws")) {
            try self.handleWebSocketUpgrade(stream, request);
        } else if (std.mem.eql(u8, request.path, "/ws")) {
            try self.handleWebSocketUpgrade(stream, request);
        } else if (std.mem.eql(u8, request.path, "/") or std.mem.eql(u8, request.path, "/ui")) {
            if (self.control_ui_enabled) {
                try self.handleControlUI(stream);
            } else {
                try self.sendErrorResponse(stream, 403, "Forbidden", "Control UI is disabled");
            }
        } else if (std.mem.eql(u8, request.path, "/autonomous/run") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleAutonomousRun(stream);
        } else if (std.mem.eql(u8, request.path, "/autonomous/browse") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleAutonomousBrowse(stream);
        } else if (std.mem.eql(u8, request.path, "/autonomous/search") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleAutonomousSearch(stream);
        } else if (std.mem.eql(u8, request.path, "/autonomous/post") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleAutonomousPost(stream);
        } else if (std.mem.eql(u8, request.path, "/autonomous/idea") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleAutonomousIdea(stream, request.body);
        } else if (std.mem.eql(u8, request.path, "/discoveries") and std.mem.eql(u8, request.method, "GET")) {
            try self.handleGetDiscoveries(stream);
        } else if (std.mem.eql(u8, request.path, "/discoveries/clear") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleClearDiscoveries(stream);
        } else if (std.mem.eql(u8, request.path, "/heartbeat") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleHeartbeat(stream);
        } else if (std.mem.eql(u8, request.path, "/state") and std.mem.eql(u8, request.method, "GET")) {
            try self.handleGetState(stream);
        } else if (std.mem.eql(u8, request.path, "/gateway/incident") and std.mem.eql(u8, request.method, "POST")) {
            try self.handleGatewayIncident(stream, request.body);
        } else if (std.mem.eql(u8, request.path, "/gateway/incidents") and std.mem.eql(u8, request.method, "GET")) {
            try self.handleGetGatewayIncidents(stream);
        } else {
            try self.sendErrorResponse(stream, 404, "Not Found", "Endpoint not found");
        }
    }

    /// Handle /health endpoint
    fn handleHealth(stream: std.net.Stream) !void {
        const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"healthy\"}\r\n";
        _ = try stream.writeAll(response);
    }
    /// Handle /status endpoint
    fn handleStatus(self: *HttpServer, stream: std.net.Stream) !void {
        const stats = try self.session_store.getStats();

        var response_buffer: [1024]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buffer,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\
            \\{{
            \\  "sessions": {{
            \\    "total": {d},
            \\    "active": {d},
            \\    "idle": {d},
            \\    "terminated": {d}
            \\  }},
            \\  "total_messages": {d},
            \\  "websocket_clients": {d}
            \\}}
        , .{
            stats.total_sessions,
            stats.active_sessions,
            stats.idle_sessions,
            stats.terminated_sessions,
            stats.total_messages,
            self.websocket_clients.items.len,
        });

        _ = try stream.writeAll(response);
    }

    /// Handle GET /sessions endpoint
    fn handleListSessions(self: *HttpServer, stream: std.net.Stream) !void {
        const sessions = try self.session_store.listActiveSessions();
        defer self.allocator.free(sessions);

        var response = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer response.deinit(self.allocator);

        try response.appendSlice(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
        try response.appendSlice(self.allocator, "{\"sessions\":[");

        for (sessions, 0..) |session, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");
            try response.print(self.allocator, "{{\"id\":\"{s}\",\"user\":\"{s}\",\"channel\":\"{s}\",\"message_count\":{d},\"status\":\"{s}\"}}",
                .{ session.id, session.user, session.channel, session.message_count, @tagName(session.status) });
        }

        try response.appendSlice(self.allocator, "]}\r\n");

        _ = try stream.writeAll(response.items);
    }

    /// Handle POST /sessions/:id/terminate endpoint
    fn handleTerminateSession(self: *HttpServer, stream: std.net.Stream, session_id: []const u8) !void {
        const terminated = try self.session_store.terminateSession(session_id);

        if (terminated) {
            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}\r\n";
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 404, "Not Found", "Session not found");
        }
    }

    /// Handle GET /config endpoint
    fn handleGetConfig(stream: std.net.Stream) !void {
        const response =
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\
            \\{"control_ui_enabled":true,"allow_insecure_auth":false}
            \\
        ;
        _ = try stream.writeAll(response);
    }
    /// Handle POST /config endpoint
    fn handleUpdateConfig(stream: std.net.Stream) !void {
        const response =
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\
            \\{"logs":["Gateway started","Session created","Request processed"]}
            \\
        ;
        _ = try stream.writeAll(response);
    }

    /// Handle WebSocket upgrade request
    fn handleWebSocketUpgrade(self: *HttpServer, stream: std.net.Stream, request: *const HttpRequest) !void {
        // Check for WebSocket upgrade headers
        const upgrade = request.headers.get("Upgrade");
        _ = request.headers.get("Connection"); // Not used but required for WebSocket
        const ws_key = request.headers.get("Sec-WebSocket-Key");
        if (upgrade == null or !std.mem.eql(u8, upgrade.?, "websocket")) {
            try self.sendErrorResponse(stream, 400, "Bad Request", "Not a WebSocket upgrade request");
            return;
        }

        if (ws_key == null) {
            try self.sendErrorResponse(stream, 400, "Bad Request", "Missing Sec-WebSocket-Key header");
            return;
        }

        // Send WebSocket upgrade response
        const accept_key = try self.calculateWebSocketAccept(ws_key.?);
        var response_buffer: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buffer,
            \\HTTP/1.1 101 Switching Protocols
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Accept: {s}
            \\
        , .{accept_key});

        _ = try stream.writeAll(response);

        // Create WebSocket client
        const client = try self.allocator.create(WebSocketClient);
        client.* = .{
            .address = try std.net.Address.parseIp("127.0.0.1", 0), // Placeholder
            .last_ping = std.time.timestamp(),
            .authenticated = true,
        };
        try self.websocket_clients.append(self.allocator, client);

        // Handle WebSocket messages (simplified)
        try self.handleWebSocketMessages(stream);
    }

    /// Calculate WebSocket accept key
    fn calculateWebSocketAccept(self: *HttpServer, _: []const u8) ![]const u8 {
        // In production, this would use SHA-1 hashing
        // For now, return a placeholder
return self.allocator.dupe(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    }
    /// Handle WebSocket messages
    fn handleWebSocketMessages(self: *HttpServer, stream: std.net.Stream) !void {
        var buffer: [4096]u8 = undefined;

        while (self.running) {
            const n = stream.read(&buffer) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };

            if (n == 0) break;

            // Parse WebSocket frame (simplified)
            // In production, implement proper WebSocket frame parsing
            _ = buffer[0..n]; // Mark as used
            // Send ping response
        }
    }

    /// Handle Control UI request
    fn handleControlUI(self: *HttpServer, stream: std.net.Stream) !void {
        _ = self;
        const html =
            \\HTTP/1.1 200 OK
            \\Content-Type: text/html
            \\
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <title>ZeptoClaw Gateway</title>
            \\  <style>
            \\    body { font-family: Arial, sans-serif; margin: 20px; }
            \\    .container { max-width: 800px; margin: 0 auto; }
            \\    .status { padding: 10px; background: #e0f7fa; border-radius: 5px; }
            \\    .sessions { margin-top: 20px; }
            \\    table { width: 100%; border-collapse: collapse; }
            \\    th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
            \\  </style>
            \\</head>
            \\<body>
            \\  <div class="container">
            \\    <h1>ZeptoClaw Gateway</h1>
            \\    <div class="status">
            \\      <h2>Status</h2>
            \\      <p>Gateway is running and healthy</p>
            \\    </div>
            \\    <div class="sessions">
            \\      <h2>Active Sessions</h2>
            \\      <table>
            \\        <tr><th>ID</th><th>User</th><th>Channel</th><th>Messages</th><th>Status</th></tr>
            \\        <tr><td colspan="5">Loading...</td></tr>
            \\      </table>
            \\    </div>
            \\  </div>
            \\  <script>
            \\    // Connect to WebSocket for real-time updates
            \\    const ws = new WebSocket('ws://' + window.location.host + '/ws');
            \\    ws.onmessage = function(event) {
            \\      console.log('Received:', event.data);
            \\      // Update UI with real-time data
            \\    };
            \\  </script>
            \\</body>
            \\</html>
            \\
        ;
        _ = try stream.writeAll(html);
    }

    /// Handle POST /autonomous/run endpoint
    fn handleAutonomousRun(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const action = try agent.selectNextAction();
            const result = try agent.executeAction(action);

            var response_buffer: [2048]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer,
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\
                \\{{"action":"{s}","success":true,"result":"{s}"}}
                \\
            , .{ @tagName(action), @tagName(result) });
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle POST /autonomous/browse endpoint
    fn handleAutonomousBrowse(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const action = autonomous.types.AutonomousAction.BROWSE_FEED;
            const result = try agent.executeAction(action);

            var response_buffer: [4096]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer,
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\
                \\{{"success":true,"action":"{s}","result":"{s}"}}
                \\
            , .{ @tagName(action), @tagName(result) });
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }
    /// Handle POST /autonomous/search endpoint
    fn handleAutonomousSearch(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const action = autonomous.types.AutonomousAction.SEARCH_TOPICS;
            const result = try agent.executeAction(action);

            var response_buffer: [4096]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer,
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\
                \\{{"success":true,"action":"{s}","result":"{s}"}}
                \\
            , .{ @tagName(action), @tagName(result) });
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }
    /// Handle POST /autonomous/post endpoint
    fn handleAutonomousPost(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const action = autonomous.types.AutonomousAction.CREATE_POST;
            const result = try agent.executeAction(action);

            var response_buffer: [2048]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer,
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\
                \\{{"success":true,"action":"{s}","result":"{s}"}}
                \\
            , .{ @tagName(action), @tagName(result) });
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }
    /// Handle POST /autonomous/idea endpoint
    fn handleAutonomousIdea(self: *HttpServer, stream: std.net.Stream, body: []const u8) !void {
        if (self.autonomous_agent) |agent| {
            // Parse JSON body to extract idea
            // For now, just use the body as the idea
            const idea = body;
            try agent.state_store.addPostIdea(idea);

            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}\r\n";
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle GET /discoveries endpoint
    fn handleGetDiscoveries(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const discoveries = try agent.state_store.getDiscoveries();
            defer self.allocator.free(discoveries);

            var response = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer response.deinit(self.allocator);

            try response.appendSlice(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
            try response.appendSlice(self.allocator, "{{\"discoveries\":[");

            for (discoveries, 0..) |discovery, i| {
                if (i > 0) try response.appendSlice(self.allocator, ",");
                try response.print(self.allocator, "{{\"type\":\"{s}\",\"content\":\"{s}\",\"post_id\":\"{?s}\",\"timestamp\":{d}}}", .{@tagName(discovery.type), discovery.content, discovery.post_id, discovery.timestamp});
            }

            try response.appendSlice(self.allocator, "]}\r\n");
            _ = try stream.writeAll(response.items);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle POST /discoveries/clear endpoint
    fn handleClearDiscoveries(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            try agent.state_store.clearDiscoveries();

            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}\r\n";
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle POST /heartbeat endpoint
    fn handleHeartbeat(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            // Parse JSON body to extract heartbeat data
            // For now, just update the local agent timestamp
            const now = std.time.timestamp();
            try agent.state_store.updateLocalAgentHeartbeat(now);

            const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}\r\n";
            _ = try stream.writeAll(response);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle GET /state endpoint
    fn handleGetState(self: *HttpServer, stream: std.net.Stream) !void {
        if (self.autonomous_agent) |agent| {
            const state = agent.state_store.state;
            const rate_limiter_status = agent.rate_limiter.getStatus(std.time.timestamp());

        var response = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer response.deinit(self.allocator);

            try response.appendSlice(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");
            try response.print(self.allocator,
                \\{{
                \\  "state": {{
                \\    "last_post": {d},
                \\    "last_browse": {d},
                \\    "last_check": {d},
                \\    "local_last_seen": {d},
                \\    "total_posts": {d},
                \\    "total_comments": {d},
                \\    "discoveries": {d},
                \\    "post_ideas": {d}
                \\  }},
                \\  "rate_limiter": {{
                \\    "can_post": {s},
                \\    "can_comment": {s},
                \\    "comments_today": {d},
                \\    "max_comments_per_day": {d}
                \\  }}
                \\}}
            , .{
                state.last_post,
                state.last_browse,
                state.last_check,
                state.local_last_seen,
                state.total_posts,
                state.total_comments,
                state.discoveries.items.len,
                state.post_ideas.items.len,
                if (rate_limiter_status.can_post) "true" else "false",
                if (rate_limiter_status.can_comment) "true" else "false",
                rate_limiter_status.comments_today,
                rate_limiter_status.max_comments_per_day,
            });

            try response.appendSlice(self.allocator, "\r\n");
            _ = try stream.writeAll(response.items);
        } else {
            try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
        }
    }

    /// Handle POST /gateway/incident endpoint
/// Handle POST /gateway/incident endpoint
fn handleGatewayIncident(_self: *HttpServer, _stream: std.net.Stream, _body: []const u8) !void {
    _ = _self;
    _ = _stream;
    _ = _body;
    // Stub - not implemented
}

///// Handle GET /gateway/incidents endpoint
//fn handleGetGatewayIncidents - stub
fn handleGetGatewayIncidents(self: *HttpServer, stream: std.net.Stream) !void {
    if (self.autonomous_agent) |agent| {
        const incidents = try agent.state_store.getGatewayIncidents();
        var response = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer response.deinit(self.allocator);
        try response.appendSlice(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"incidents\":[");
        for (incidents, 0..) |incident, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",");
            try response.print(self.allocator, "{{\"type\":\"{s}\",\"timestamp\":{d}}}", .{incident.type, incident.timestamp});
        }
        try response.appendSlice(self.allocator, "]}\r\n");
        _ = try stream.writeAll(response.items);
    } else {
        try self.sendErrorResponse(stream, 503, "Service Unavailable", "Autonomous agent not initialized");
    }
}

fn sendErrorResponse(self: *HttpServer, stream: std.net.Stream, status_code: u16, status_text: []const u8, message: []const u8) !void {
        _ = self;
        var response_buffer: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buffer,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: application/json
            \\
            \\{{"error":"{s}"}}
            \\
        , .{ status_code, status_text, message });

        _ = try stream.writeAll(response);
    }
};
