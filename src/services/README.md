# Services

## Overview

The `src/services` directory implements two local HTTP servers plus shared utilities: a read-only Shell2HTTP monitor (port 9001, Basic auth) and a webhook action server (port 9000, token auth). `http_utils.zig` holds response builders, auth helpers, command execution, request parsing, and secret loading used by both servers.

## Interface

### `http_utils.zig`

- `http_utils.zig:log` — scoped logger (`.http_server`).
- `http_utils.zig:HttpResponse` — HTTP response with status, content type, body, and `owned` flag for allocator cleanup.
- `http_utils.zig:AuthError` — auth failure errors (`MissingHeader`, `InvalidFormat`, `InvalidCredentials`, `InvalidToken`).
- `http_utils.zig:validateBasicAuth` — validates `Authorization: Basic …` against expected username and password.
- `http_utils.zig:validateWebhookToken` — constant-time compare of header value to expected webhook token.
- `http_utils.zig:CommandResult` — stdout, stderr, and exit code from a subprocess run.
- `http_utils.zig:executeCommand` — runs `argv[0]` as an absolute-path command with optional working directory and 1 MiB stdout/stderr limits.
- `http_utils.zig:executeCommandSimple` — runs a command and returns stdout, or stderr when exit is non-zero and stdout is empty.
- `http_utils.zig:HttpRequest` — parsed method, path, header map, and body.
- `http_utils.zig:parseHttpRequest` — parses a minimal HTTP/1.x request from raw bytes.
- `http_utils.zig:ServerConfig` — default host `127.0.0.1`, port `9000`, and `address()` parse helper.
- `http_utils.zig:loadWebhookSecret` — reads trimmed secret from `$HOME/.zeptoclaw/.webhook-secret`.

### `shell2http_endpoints.zig`

- `shell2http_endpoints.zig:EndpointContext` — allocator plus `HOME` and resolved workspace directory for handlers.
- `shell2http_endpoints.zig:health` — handler for `/health`.
- `shell2http_endpoints.zig:systemctlStatus` — handler for `/systemctl/status`.
- `shell2http_endpoints.zig:timers` — handler for `/timers`.
- `shell2http_endpoints.zig:journalGateway` — handler for `/journal/gateway`.
- `shell2http_endpoints.zig:journalWatchdog` — handler for `/journal/watchdog`.
- `shell2http_endpoints.zig:journalWebhook` — handler for `/journal/webhook`.
- `shell2http_endpoints.zig:gitStatus` — handler for `/git/status`.
- `shell2http_endpoints.zig:gitLog` — handler for `/git/log`.
- `shell2http_endpoints.zig:disk` — handler for `/disk`.
- `shell2http_endpoints.zig:memory` — handler for `/memory`.
- `shell2http_endpoints.zig:uptime` — handler for `/uptime`.
- `shell2http_endpoints.zig:date` — handler for `/date`.
- `shell2http_endpoints.zig:ollamaList` — handler for `/ollama/list`.
- `shell2http_endpoints.zig:ollamaPs` — handler for `/ollama/ps`.
- `shell2http_endpoints.zig:processOpenclaw` — handler for `/process/openclaw`.
- `shell2http_endpoints.zig:processAll` — handler for `/process/all`.
- `shell2http_endpoints.zig:workerState` — handler for `/worker/state`.
- `shell2http_endpoints.zig:workerHealth` — handler for `/worker/health`.
- `shell2http_endpoints.zig:workerIncidents` — handler for `/worker/incidents`.
- `shell2http_endpoints.zig:workerDiscoveries` — handler for `/worker/discoveries`.
- `shell2http_endpoints.zig:networkTest` — handler for `/network/test`.
- `shell2http_endpoints.zig:EndpointHandler` — function type for Shell2HTTP handlers.
- `shell2http_endpoints.zig:Endpoint` — path, handler, and description registry entry.
- `shell2http_endpoints.zig:endpoints` — slice of all Shell2HTTP routes (see Routes).
- `shell2http_endpoints.zig:getEndpoint` — lookup by exact path string.

### `shell2http_server.zig`

- `shell2http_server.zig:Config` — host, port, Basic auth username/password; `load` reads password from `loadWebhookSecret`.
- `shell2http_server.zig:Shell2HTTPServer` — TCP listener, endpoint context, accept loop, GET-only dispatch with Basic auth.
- `shell2http_server.zig:main` — loads config, initializes server, runs until stopped.

### `webhook_endpoints.zig`

- `webhook_endpoints.zig:EndpointContext` — allocator plus `HOME` and resolved workspace directory for handlers.
- `webhook_endpoints.zig:health` — webhook handler `health`.
- `webhook_endpoints.zig:gatewayRestart` — webhook handler `gateway-restart`.
- `webhook_endpoints.zig:gitPull` — webhook handler `git-pull`.
- `webhook_endpoints.zig:gitPush` — webhook handler `git-push`.
- `webhook_endpoints.zig:syncMemory` — webhook handler `sync-memory`.
- `webhook_endpoints.zig:deployWorker` — webhook handler `deploy-worker`.
- `webhook_endpoints.zig:runTests` — webhook handler `run-tests`.
- `webhook_endpoints.zig:ollamaRun` — webhook handler `ollama-run` (JSON body).
- `webhook_endpoints.zig:notify` — webhook handler `notify` (JSON body).
- `webhook_endpoints.zig:timerStatus` — webhook handler `timer-status`.
- `webhook_endpoints.zig:journalTail` — webhook handler `journal-tail`.
- `webhook_endpoints.zig:heartbeat` — webhook handler `heartbeat`.
- `webhook_endpoints.zig:EndpointHandler` — function type `(ctx, optional body) → HttpResponse`.
- `webhook_endpoints.zig:Endpoint` — name, handler, `requires_auth`, and HTTP method.
- `webhook_endpoints.zig:endpoints` — slice of all webhook endpoints (see Routes).
- `webhook_endpoints.zig:getEndpoint` — lookup by endpoint name (path segment after `/`).

### `webhook_server.zig`

- `webhook_server.zig:Config` — host, port, secret; `load` reads secret via `loadWebhookSecret`.
- `webhook_server.zig:WebhookServer` — TCP listener, endpoint context, method and `X-Webhook-Token` dispatch.
- `webhook_server.zig:main` — loads config, initializes server, runs until stopped.

## Routes

Routing is defined in endpoint registries and enforced in the server connection handlers (`shell2http_server.zig:Shell2HTTPServer`, `webhook_server.zig:WebhookServer`).

### Shell2HTTP (GET only, `Authorization: Basic`, default `127.0.0.1:9001`)

Paths from `shell2http_endpoints.zig:endpoints`:

| Path | Handler |
|------|---------|
| `/health` | `shell2http_endpoints.zig:health` |
| `/systemctl/status` | `shell2http_endpoints.zig:systemctlStatus` |
| `/timers` | `shell2http_endpoints.zig:timers` |
| `/journal/gateway` | `shell2http_endpoints.zig:journalGateway` |
| `/journal/watchdog` | `shell2http_endpoints.zig:journalWatchdog` |
| `/journal/webhook` | `shell2http_endpoints.zig:journalWebhook` |
| `/git/status` | `shell2http_endpoints.zig:gitStatus` |
| `/git/log` | `shell2http_endpoints.zig:gitLog` |
| `/disk` | `shell2http_endpoints.zig:disk` |
| `/memory` | `shell2http_endpoints.zig:memory` |
| `/uptime` | `shell2http_endpoints.zig:uptime` |
| `/date` | `shell2http_endpoints.zig:date` |
| `/ollama/list` | `shell2http_endpoints.zig:ollamaList` |
| `/ollama/ps` | `shell2http_endpoints.zig:ollamaPs` |
| `/process/openclaw` | `shell2http_endpoints.zig:processOpenclaw` |
| `/process/all` | `shell2http_endpoints.zig:processAll` |
| `/worker/state` | `shell2http_endpoints.zig:workerState` |
| `/worker/health` | `shell2http_endpoints.zig:workerHealth` |
| `/worker/incidents` | `shell2http_endpoints.zig:workerIncidents` |
| `/worker/discoveries` | `shell2http_endpoints.zig:workerDiscoveries` |
| `/network/test` | `shell2http_endpoints.zig:networkTest` |

### Webhook (path `/{name}` where `name` matches `webhook_endpoints.zig:Endpoint.name`, default `127.0.0.1:9000`)

| Path | Method | Auth (`X-Webhook-Token`) | Handler |
|------|--------|--------------------------|---------|
| `/health` | GET | no | `webhook_endpoints.zig:health` |
| `/gateway-restart` | POST | yes | `webhook_endpoints.zig:gatewayRestart` |
| `/git-pull` | POST | yes | `webhook_endpoints.zig:gitPull` |
| `/git-push` | POST | yes | `webhook_endpoints.zig:gitPush` |
| `/sync-memory` | POST | yes | `webhook_endpoints.zig:syncMemory` |
| `/deploy-worker` | POST | yes | `webhook_endpoints.zig:deployWorker` |
| `/run-tests` | POST | yes | `webhook_endpoints.zig:runTests` |
| `/ollama-run` | POST | yes | `webhook_endpoints.zig:ollamaRun` |
| `/notify` | POST | yes | `webhook_endpoints.zig:notify` |
| `/timer-status` | GET | no | `webhook_endpoints.zig:timerStatus` |
| `/journal-tail` | GET | no | `webhook_endpoints.zig:journalTail` |
| `/heartbeat` | POST | yes | `webhook_endpoints.zig:heartbeat` |

## Invariants

- `http_utils.zig:executeCommand` — `argv` must be non-empty and `argv[0]` must be an absolute path (`http_utils.zig:executeCommand`).
- `http_utils.zig:validateBasicAuth` — header must start with `Basic ` and decode to `username:password` matching expected values (`http_utils.zig:validateBasicAuth`).
- `http_utils.zig:validateWebhookToken` — missing header or token mismatch yields `AuthError` (`http_utils.zig:validateWebhookToken`).
- `http_utils.zig:loadWebhookSecret` — requires `HOME` and readable `$HOME/.zeptoclaw/.webhook-secret` (`http_utils.zig:loadWebhookSecret`).
- `shell2http_server.zig:Shell2HTTPServer` — only `GET` requests are accepted; other methods receive 405 (`shell2http_server.zig:Shell2HTTPServer`).
- `shell2http_server.zig:Config` — default username is `barvis`; password comes from webhook secret file on load (`shell2http_server.zig:Config`).
- `webhook_server.zig:WebhookServer` — request method must equal the endpoint’s `method` field; mismatch yields 405 (`webhook_server.zig:WebhookServer`, `webhook_endpoints.zig:Endpoint`).
- `webhook_server.zig:WebhookServer` — when `requires_auth` is true, `X-Webhook-Token` must match configured secret (`webhook_server.zig:WebhookServer`, `webhook_endpoints.zig:Endpoint`).

## Side Effects

- `http_utils.zig:executeCommand` — spawns subprocesses via `std.process.run` with up to 1 MiB captured stdout/stderr (`http_utils.zig:executeCommand`).
- `http_utils.zig:validateBasicAuth` — uses `page_allocator` for base64 decode buffer (`http_utils.zig:validateBasicAuth`).
- `http_utils.zig:loadWebhookSecret` — reads secret file from disk under `$HOME/.zeptoclaw/` (`http_utils.zig:loadWebhookSecret`).
- `shell2http_endpoints.zig` handlers — invoke `/usr/bin/systemctl`, `journalctl`, `git`, `df`, `free`, `uptime`, `date`, `ollama`, `pgrep`, `ps`, and `curl` (including HTTPS to `barvis-router.bkataru.workers.dev`) via `http_utils.zig:executeCommandSimple`.
- `webhook_endpoints.zig:gatewayRestart` — runs `systemctl --user restart zeptoclaw-gateway.service` (`webhook_endpoints.zig:gatewayRestart`).
- `webhook_endpoints.zig:gitPull` / `webhook_endpoints.zig:gitPush` — mutates/syncs git state in workspace (`webhook_endpoints.zig:gitPull`, `webhook_endpoints.zig:gitPush`).
- `webhook_endpoints.zig:syncMemory`, `deployWorker`, `runTests`, `ollamaRun`, `notify`, `journalTail` — execute scripts under `$HOME/.openclaw/scripts/` (`webhook_endpoints.zig` respective handlers).
- `webhook_endpoints.zig:heartbeat` — `curl` POST to `https://barvis-router.bkataru.workers.dev/heartbeat` (`webhook_endpoints.zig:heartbeat`).
- `shell2http_server.zig:Shell2HTTPServer` / `webhook_server.zig:WebhookServer` — bind TCP listeners, accept connections, write HTTP responses (`shell2http_server.zig:Shell2HTTPServer`, `webhook_server.zig:WebhookServer`).

## Verification

- Run: `zig build test`
