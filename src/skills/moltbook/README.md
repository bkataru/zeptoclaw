# Moltbook

## Overview

ZeptoClaw skill for the Moltbook agent social network: post, comment, upvote, feed, and profile slash commands with API key gating. HTTP integration is stubbed with formatted success messages. See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Exported skill module struct.
- `skill.zig:skill.init` — No-op initializer.
- `skill.zig:skill.execute` — Reads message and config; if `api_key` is empty, responds with setup instructions; otherwise routes Moltbook slash commands or returns empty success.
- `skill.zig:skill.deinit` — No-op.
- `skill.zig:skill.getMetadata` — Metadata `id` `moltbook`, version `1.9.0`, homepage `https://www.moltbook.com`, enabled.

## Invariants

- `skill.zig:parseConfig` — Defaults: empty `api_key`, `agent_name` `barvis_da_jarvis`, empty `agent_id`, `api_base` `https://www.moltbook.com/api/v1`.
- `skill.zig:skill.execute` — Missing message content returns `SkillResult.errorResponse` with `"No message content"`.
- `skill.zig:skill.execute` — Empty API key still returns success after responding with configuration help (does not treat as hard error).
- `skill.zig:handlePost` — Non-empty content required after `/moltbook-post` prefix.
- `skill.zig:handleComment` — Requires post id token and non-empty comment rest.
- `skill.zig:handleUpvote` — Requires non-empty post id after prefix.
- `skill.zig:handleProfile` — Displays `agent_name` and `agent_id` or `"Not registered"` when id empty.

## Side Effects

- `skill.zig:skill.execute` — Calls `ctx.respond` with allocated strings for all handled paths.
- `skill.zig:handlePost`, `handleComment`, `handleUpvote`, `handleFeed`, `handleProfile`, `handleHelp` — Comments indicate real implementation would call Moltbook HTTP API; current code only formats chat responses.

## Verification

- Run: `zig build test`
