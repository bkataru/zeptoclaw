# Gateway

## Overview

The `src/gateway` package implements ZeptoClaw’s HTTP/WebSocket gateway: token-authenticated request handling (`http_server.zig`), persisted session tracking (`session_store.zig`), optional control UI HTML (`control_ui.zig`), and a stuck-turn watchdog shared with WhatsApp turns (`turn_watch.zig`). The `gateway_server.zig` binary entry point loads config, wires WhatsApp and autonomous agents into `HttpServer`, registers signal handlers, and runs the accept loop.

Every handled connection requires a valid `X-Auth-Token` header (`http_server.zig:handleConnection`). Bind address `"lan"` maps to `0.0.0.0`, `"loopback"` to `127.0.0.1`, otherwise the bind string is parsed as an IP (`http_server.zig:init`).

### HTTP routes (`http_server.zig:routeRequest`)

All routes below require authentication unless noted. Methods and paths are exactly as routed in code.

| Method | Path | Handler |
|--------|------|---------|
| any | `/health` | `http_server.zig:handleHealth` — JSON from `health_extra_fn` if set, else `{"status":"healthy"}` |
| any | `/status` | `http_server.zig:handleStatus` — session stats + WebSocket client count |
| GET | `/sessions` | `http_server.zig:handleListSessions` |
| POST | `/sessions/:id/terminate` | `http_server.zig:handleTerminateSession` |
| GET | `/config` | `http_server.zig:handleGetConfig` |
| POST | `/config` | `http_server.zig:handleUpdateConfig` |
| any | `/logs` | `http_server.zig:handleStatus` (same response as `/status`) |
| any | `/ws` | `http_server.zig:handleWebSocketUpgrade` |
| GET | `/`, `/ui` | `http_server.zig:handleControlUI` if `control_ui_enabled`, else 403 |
| POST | `/autonomous/run` | `http_server.zig:handleAutonomousRun` |
| POST | `/autonomous/browse` | `http_server.zig:handleAutonomousBrowse` |
| POST | `/autonomous/search` | `http_server.zig:handleAutonomousSearch` |
| POST | `/autonomous/post` | `http_server.zig:handleAutonomousPost` |
| POST | `/autonomous/idea` | `http_server.zig:handleAutonomousIdea` |
| GET | `/discoveries` | `http_server.zig:handleGetDiscoveries` |
| POST | `/discoveries/clear` | `http_server.zig:handleClearDiscoveries` |
| POST | `/agent`, `/agent/wait` | `http_server.zig:handleAgentRun` |
| POST | `/exec/approve` | `http_server.zig:handleExecApprove` |
| POST | `/whatsapp/inject` | `http_server.zig:handleWhatsAppInject` (202 ack; work in detached thread) |
| POST | `/reload` | `http_server.zig:handleReload` — calls `reload_fn` when set |
| POST | `/whatsapp/heal` | `http_server.zig:handleWhatsAppHeal` — calls `heal_fn` when set |
| POST | `/heartbeat` | `http_server.zig:handleHeartbeat` |
| GET | `/state` | `http_server.zig:handleGetState` |
| POST | `/gateway/incident` | `http_server.zig:handleGatewayIncident` (stub, no response body written) |
| GET | `/gateway/incidents` | `http_server.zig:handleGetGatewayIncidents` |
| any | `/metrics` | `http_server.zig:handleMetrics` (Prometheus text) |
| other | — | 404 `http_server.zig:sendErrorResponse` |

At startup, `gateway_server.zig:main` assigns `reload_fn` to `reloadWhatsAppFromDisk`, `heal_fn` to `healWhatsAppSignal`, `health_extra_fn` to `whatsappHealthJson`, and `inject_fn` to `injectWhatsAppTurn` on the server instance.

### Shutdown and reload

- **Graceful stop:** `gateway_server.zig:sigHandler` on `SIGINT`/`SIGTERM` sets `HttpServer.shutdown_requested` and calls `server.stop()` (which also closes the listener so a blocked `accept` wakes), `whatsapp_channel.requestStop()` (async-signal-safe flag polled by the reader loop and `sleepInterruptible`), and `nim.setShutdown()` (checked by `sleepAfterFailure` and `postOnceWithDeadline`). Every wait returns within 5 s. After `start` returns, `gateway_server.zig:main` calls `whatsapp_channel.disconnect()` (full teardown/join) and attempts `autonomous_agent.state_store.save()` (`gateway_server.zig:main`).
- **Reload (no process restart):** `POST /reload` invokes `reload_fn`. The wired implementation `gateway_server.zig:reloadWhatsAppFromDisk` reloads `Config` from disk and updates WhatsApp `allow_from`, DM policy, and group policy on channel, session, inbound, and outbound configs under `g_whatsapp_mu` (`gateway_server.zig:reloadWhatsAppFromDisk`).

## Interface

- `control_ui.zig:ControlUI` — holds allocator, `enabled`, and `allow_insecure_auth`; provides `init`, `deinit`, and `generateHTML` (owned HTML slice for the rich control UI page).
- `gateway_server.zig:main` — gateway executable: config, auth, session store, WhatsApp, autonomous agent, HTTP server, stuck-turn watchdog thread, optional cron/memory threads, blocking `HttpServer.start`.
- `http_server.zig:HttpServer` — TCP listener, auth, session store, optional autonomous agent, callback slots (`reload_fn`, `heal_fn`, `health_extra_fn`, `inject_fn`); public `init`, `deinit`, `start`, `stop`.
- `session_store.zig:SessionStore` — in-memory sessions map with JSON persistence under `{sessions_dir}/sessions.json`; public session CRUD, listing, cleanup, and stats APIs on the store type.
- `token_auth.zig:TokenAuth` — main and workspace tokens, validation with rate limits, rotation, and token listing.
- `turn_watch.zig:DEFAULT_WARN_AFTER_S` — default slow-turn threshold (600 seconds); overridable via env in `Watch.loadWarnThreshold`.
- `turn_watch.zig:Stats` — snapshot fields `in_flight`, `oldest_age_s`, `slow`.
- `turn_watch.zig:Watch` — mutex-protected in-flight turn registry; `init`, `deinit`, `loadWarnThreshold`, `begin`, `end`, `sweep`, `stats`.
- `turn_watch.zig:run` — watchdog thread loop: sleep `interval_s`, then `Watch.sweep`.

## Invariants

- `http_server.zig:handleConnection` — requests without `X-Auth-Token` receive 401; invalid tokens receive 401 after `token_auth.zig:validate` returns false.
- `token_auth.zig:validate` — unknown, inactive, or expired tokens return false; rate limit over 100 requests per 60-second window returns `error.RateLimitExceeded` from `checkRateLimit` (propagates as validation failure).
- `session_store.zig:listActiveSessions` — only sessions with `status == .active` are returned.
- `session_store.zig:cleanupOldSessions` — removes terminated sessions whose `last_activity` is older than 24 hours.
- `turn_watch.zig:Watch` — all entry list mutations and stats go through `mu` (`turn_watch.zig:begin`, `turn_watch.zig:end`, `turn_watch.zig:sweep`, `turn_watch.zig:stats`).
- `turn_watch.zig:sweep` — logs at most once per threshold step per turn (`warned_step` vs `@divFloor(age, warn_after_s)`).
- `http_server.zig:handleReload` — returns 503 if `reload_fn` is null; 500 with error name if callback fails.
- `gateway_server.zig:reloadWhatsAppFromDisk` — returns `error.WhatsAppDisabled` when WhatsApp channel is not wired.

## Side Effects

- `session_store.zig:createSession`, `updateActivity`, `terminateSession`, `cleanupOldSessions` — rewrite `sessions_file` via `session_store.zig:save`.
- `session_store.zig:init` — creates sessions directory and calls `load` (`session_store.zig:init`).
- `http_server.zig:start` — accepts connections synchronously in the caller thread; prints listen address; closes connections after handling.
- `http_server.zig:handleWhatsAppInject` — spawns detached thread to run `inject_fn` after 202 response (`http_server.zig:handleWhatsAppInject`).
- `http_server.zig:handleExecApprove` — calls `core_tools.approveExec` with parsed command (`http_server.zig:handleExecApprove`).
- `http_server.zig:handleAutonomousIdea` — `agent.state_store.addPostIdea` (`http_server.zig:handleAutonomousIdea`).
- `http_server.zig:handleClearDiscoveries` — `agent.state_store.clearDiscoveries` (`http_server.zig:handleClearDiscoveries`).
- `http_server.zig:handleTerminateSession` — `session_store.zig:terminateSession`.
- `control_ui.zig:generateHTML` — allocates duplicated HTML via allocator (`control_ui.zig:generateHTML`).
- `token_auth.zig:rotateMainToken` — deactivates prior main token, registers new token, updates `main_token` field (`token_auth.zig:rotateMainToken`).
- `turn_watch.zig:run` — infinite loop with `nanosleep` and journal warnings from `sweep` (`turn_watch.zig:run`, `turn_watch.zig:sweep`).
- `gateway_server.zig:main` — SIGINT/SIGTERM handlers (flag + per-layer stop calls), WhatsApp connect/heal/reload side effects, stuck-turn watchdog thread spawn, optional cron/memory threads, channel disconnect and autonomous state save on shutdown path (`gateway_server.zig:main`).
- `gateway_server.zig:main` startup banner — prints tokens as "configured (redacted)", never the values.
- `gateway_server.zig:replayPendingTurns` — skips rows whose `at` is missing/future/≥600 s old (ack without a model call), runs young rows under a mutex-guarded in-flight id set (single-flight across reconnect threads), and acks only after a produced reply is sent.
- `gateway_server.zig:whatsappHealthJson` — allocates JSON including WhatsApp connection snapshot and `turn_watch.Watch.stats` (`gateway_server.zig:whatsappHealthJson`).

## Verification

- Run: `zig build test`
