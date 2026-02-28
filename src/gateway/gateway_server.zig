//! Gateway Server Entry Point
//! Main executable for the ZeptoClaw HTTP gateway server

const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

const TokenAuth = zeptoclaw.gateway.token_auth.TokenAuth;
const SessionStore = zeptoclaw.gateway.session_store.SessionStore;
const HttpServer = zeptoclaw.gateway.http_server.HttpServer;
const ControlUI = zeptoclaw.gateway.control_ui.ControlUI;
const Config = zeptoclaw.config.Config;
const AutonomousAgent = zeptoclaw.autonomous.agent_framework.AutonomousAgent;
const StateStore = zeptoclaw.autonomous.state_store.StateStore;
const MoltbookClient = zeptoclaw.autonomous.moltbook_client.MoltbookClient;
const RateLimiter = zeptoclaw.autonomous.rate_limiter.RateLimiter;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var cfg = Config.load(allocator) catch {
        std.debug.print("Error: Failed to load configuration\n", .{});
        std.debug.print("Please ensure NVIDIA_API_KEY is set and config file exists\n", .{});
        return error.ConfigLoadFailed;
    };
    defer cfg.deinit();

    // Initialize token authentication
    const main_token = cfg.gateway_auth_token orelse "317ef50c19fa20b485b377785d3ccb8d6af318dd1534b2a4";
    const workspace_token = "df95d386c47ca68bf705ce7d22432752df25c3ad24eefb49";

    var auth = try TokenAuth.init(allocator, main_token, workspace_token);
    defer auth.deinit();

    // Initialize session store
    const sessions_dir = "/home/user/zeptoclaw/sessions";
    var session_store = try SessionStore.init(allocator, sessions_dir);
    defer session_store.deinit();

    // Initialize control UI
    var control_ui = ControlUI.init(allocator, cfg.gateway_control_ui_enabled, cfg.gateway_allow_insecure_auth);
    defer control_ui.deinit();

    // Initialize autonomous agent components
    const state_file_path = "/home/user/zeptoclaw/.zeptoclaw_state.json";
    var autonomous_state_store = try StateStore.init(allocator, state_file_path);
    defer autonomous_state_store.deinit();

    // Load Moltbook configuration from environment
    const moltbook_api_key = std.process.getEnvVarOwned(allocator, "MOLTBOOK_API_KEY") catch {
        std.debug.print("Error: MOLTBOOK_API_KEY environment variable not set\n", .{});
        return error.MissingMoltbookConfig;
    };
    defer allocator.free(moltbook_api_key);

    const moltbook_agent_id = std.process.getEnvVarOwned(allocator, "MOLTBOOK_AGENT_ID") catch {
        std.debug.print("Error: MOLTBOOK_AGENT_ID environment variable not set\n", .{});
        return error.MissingMoltbookConfig;
    };
    defer allocator.free(moltbook_agent_id);

    const moltbook_agent_name = std.process.getEnvVarOwned(allocator, "MOLTBOOK_AGENT_NAME") catch {
        std.debug.print("Error: MOLTBOOK_AGENT_NAME environment variable not set\n", .{});
        return error.MissingMoltbookConfig;
    };
    defer allocator.free(moltbook_agent_name);

    // Initialize Moltbook client with empty monitored posts list
    var moltbook_client = try MoltbookClient.init(
        allocator,
        moltbook_api_key,
        moltbook_agent_id,
        moltbook_agent_name,
        &[_][]const u8{},
    );
    defer moltbook_client.deinit();

    var rate_limiter = RateLimiter.init(allocator);
    defer rate_limiter.deinit();

    const autonomous_agent = try allocator.create(AutonomousAgent);
    autonomous_agent.* = AutonomousAgent.init(allocator, &autonomous_state_store, &moltbook_client, &rate_limiter);
    defer allocator.destroy(autonomous_agent);
    // Initialize HTTP server
    var server = try HttpServer.init(
        allocator,
        std.math.cast(u16, cfg.gateway_port) orelse return error.InvalidPort,
        cfg.gateway_bind,
        &auth,
        &session_store,
        cfg.gateway_control_ui_enabled,
        cfg.gateway_allow_insecure_auth,
        autonomous_agent,
    );
    defer server.deinit();

    // Print startup information
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         ZeptoClaw Gateway Server v1.0.0                   ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Port: {d}\n", .{cfg.gateway_port});
    std.debug.print("  Bind: {s}\n", .{cfg.gateway_bind});
    std.debug.print("  Control UI: {s}\n", .{if (cfg.gateway_control_ui_enabled) "enabled" else "disabled"});
    std.debug.print("  Allow Insecure Auth: {s}\n", .{if (cfg.gateway_allow_insecure_auth) "true" else "false"});
    std.debug.print("  Sessions Directory: {s}\n", .{sessions_dir});
    std.debug.print("\n", .{});
    std.debug.print("API Endpoints:\n", .{});
    std.debug.print("  GET  /health          - Health check\n", .{});
    std.debug.print("  GET  /status          - Gateway status\n", .{});
    std.debug.print("  GET  /sessions        - List active sessions\n", .{});
    std.debug.print("  POST /sessions/:id/terminate - Terminate a session\n", .{});
    std.debug.print("  GET  /config          - Get configuration\n", .{});
    std.debug.print("  POST /config          - Update configuration\n", .{});
    std.debug.print("  GET  /logs            - Recent logs\n", .{});
    std.debug.print("  WS   /ws              - WebSocket for real-time updates\n", .{});
    std.debug.print("  GET  /                - Control UI (if enabled)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Autonomous Endpoints:\n", .{});
    std.debug.print("  POST /autonomous/run  - Execute next autonomous action\n", .{});
    std.debug.print("  POST /autonomous/browse - Browse feed and engage\n", .{});
    std.debug.print("  POST /autonomous/search - Search topics of interest\n", .{});
    std.debug.print("  POST /autonomous/post - Create an autonomous post\n", .{});
    std.debug.print("  POST /autonomous/idea - Add post idea to queue\n", .{});
    std.debug.print("  GET  /discoveries     - View recent discoveries\n", .{});
    std.debug.print("  POST /discoveries/clear - Clear discoveries\n", .{});
    std.debug.print("  POST /heartbeat       - Local agent health report\n", .{});
    std.debug.print("  GET  /state           - Full state + health metrics\n", .{});
    std.debug.print("  POST /gateway/incident - Report gateway incident\n", .{});
    std.debug.print("  GET  /gateway/incidents - View recent incidents\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Authentication:\n", .{});
    std.debug.print("  Main Token: {s}\n", .{main_token});
    std.debug.print("  Workspace Token: {s}\n", .{workspace_token});
    std.debug.print("\n", .{});
    std.debug.print("Use X-Auth-Token header for authentication\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Press Ctrl+C to stop the server\n", .{});
    std.debug.print("\n", .{});

    // Start the server
    try server.start();
}

test "gateway server main" {
    _ = main;
}
