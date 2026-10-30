# gateway_watchdog

## Overview

ZeptoClaw skill that answers slash-style messages about gateway session health (status, check, logs, threshold). It uses message content prefixes rather than `ctx.command`, calls `ctx.respond`, and returns `execution_context.SkillResult` helpers. Stuck-session detection and log reads are stubbed. See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Skill struct for gateway watchdog messaging.
- `skill.zig:init` — No-op; config uses fixed defaults in `parseConfig`.
- `skill.zig:execute` — Requires `ctx.getMessageContent()`; matches `/gateway-watchdog …`, `/watchdog-status`, `/watchdog-check`, or falls through to help; responds via `ctx.respond` and returns success/error/stop results.
- `skill.zig:deinit` — No-op.
- `skill.zig:getMetadata` — Returns metadata with `id` `gateway-watchdog`, `name` `Gateway Watchdog`, version `1.0.0`, `enabled` true, and empty-ish `metadata` object map.

## Invariants

- `skill.zig:parseConfig` — Ignores incoming JSON; `stuck_threshold_minutes` 10, log under home `.zeptoclaw/logs/gateway-watchdog.log`, service `zeptoclaw-gateway.service`, `enable_auto_restart` true.
- `skill.zig:handleThreshold` — Parsed minute values do not change config; response notes runtime changes unsupported.
- `skill.zig:handleCheck` — Always reports no stuck sessions (placeholder implementation).

## Side Effects

- `skill.zig:parseConfig` — `log_path` uses `compat.homeJoin` with `page_allocator` (leaked path string for process lifetime).
- `skill.zig:execute` — Sends user-visible responses through `ctx.respond`; no systemd or filesystem access in current handlers.

## Verification

- Run: `zig build test`
