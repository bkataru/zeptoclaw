# GitHub Stars Search

## Overview

ZeptoClaw skill that exposes slash commands to search, summarize, and sync a local index of GitHub starred repositories. Configuration is parsed on each execution; there is no global skill state. Agent-facing usage details live in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Exported skill module struct registered with the skill SDK.
- `skill.zig:skill.init` — No-op initializer; ignores allocator and config (config is parsed per execution in `execute`).
- `skill.zig:skill.execute` — Reads message content and config; dispatches `/stars-search`, `/stars-stats`, or `/stars-sync`; otherwise returns an empty success response.
- `skill.zig:skill.deinit` — No-op; no global resources to free.
- `skill.zig:skill.getMetadata` — Returns metadata (`id` `github-stars`, name, version `1.0.0`, description, enabled).

## Invariants

- `skill.zig:skill.execute` — Returns `SkillResult.errorResponse` with `"No message content"` when `ctx.getMessageContent()` is null.
- `skill.zig:skill.execute` — `/stars-search` with an empty query after the prefix responds with usage text and returns an error result.
- `skill.zig:parseConfig` — Default `index_path` is `~/.zeptoclaw/workspace/memory/github-stars-index.json` (via `compat.homeJoin`); default `sync_interval_hours` is 24; default `max_results` is 10.
- `skill.zig:handleSearch` — Response is formatted placeholder output (comments note a real implementation would search the local index).
- `skill.zig:handleStats` — Response is formatted placeholder statistics tied to `cfg.index_path`.
- `skill.zig:handleSync` — Response is formatted placeholder sync progress tied to `cfg.index_path`.

## Side Effects

- `skill.zig:skill.execute` — Calls `ctx.respond` for matched slash commands with allocated formatted strings.
- `skill.zig:leakedHome` — May allocate path strings via `std.heap.page_allocator` when resolving default index paths (same pattern as other home-relative defaults in this file).

## Verification

- Run: `zig build test`
