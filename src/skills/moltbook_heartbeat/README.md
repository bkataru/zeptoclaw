# Moltbook Heartbeat

## Overview

ZeptoClaw skill module for automated Moltbook engagement: scheduled heartbeats, comment checks, Cloudflare worker pings, and slash-command diagnostics. Execution is message-driven via `ExecutionContext`; configuration is parsed per run with no global state. Agent-facing usage notes live in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — exported skill struct registered by the skills loader.
- `skill.zig:skill.init` — no-op; ignores allocator and config JSON (config parsed on each `execute`).
- `skill.zig:skill.execute` — requires message content; dispatches `/heartbeat-status`, `/heartbeat-check`, `/heartbeat-ping`, or runs `performHeartbeat` for other messages; returns `SkillResult.errorResponse` when content is missing.
- `skill.zig:skill.deinit` — no-op; no global resources.
- `skill.zig:skill.getMetadata` — returns `SkillMetadata` with id `moltbook-heartbeat`, name, version `1.0.0`, description, empty metadata object, `enabled = true`.

## Invariants

- `skill.zig:skill.init` — does not retain allocator or config; heartbeats do not persist last-run timestamps (`skill.zig:handleStatus` reports stateless mode).
- `skill.zig:skill.execute` — command routing uses `std.mem.startsWith` on message prefixes for the three `/heartbeat-*` commands.
- `skill.zig:parseConfig` — non-object config yields empty strings and defaults `check_interval_minutes = 30`, `reply_threshold_hours = 24`.
- `skill.zig:performHeartbeat` — response always claims 0 new comment replies regardless of config API keys.
- `skill.zig:formatTimestamp` — returns fixed string `"2026-02-26 19:00:00"` (does not format the passed timestamp).

## Side Effects

- `skill.zig:skill.execute` — allocates formatted responses and calls `ctx.respond` on success paths; no HTTP calls to Moltbook or Cloudflare worker in this implementation (stub messages only).
- `skill.zig:skill.getMetadata` — initializes metadata hash map with `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
