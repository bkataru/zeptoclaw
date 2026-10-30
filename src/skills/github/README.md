# github

## Overview

ZeptoClaw skill for GitHub-themed slash commands (`/gh-issue`, `/gh-pr`, `/gh-repo`, `/gh-release`) when a `github_token` is present in config. Without a token it returns setup instructions. Handlers return illustrative API outcomes (no live HTTP in this file). See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Skill struct for GitHub integration messages.
- `skill.zig:init` — No-op.
- `skill.zig:execute` — Reads message content and config; if `github_token` is empty, responds with not-configured help; otherwise dispatches issue/PR/repo/release handlers or empty success.
- `skill.zig:deinit` — No-op.
- `skill.zig:getMetadata` — Registers `id` `github`, `name` `GitHub Integration`, version `1.0.0`, `enabled` true, with a `metadata` string hash map initialized on the page allocator.

## Invariants

- `skill.zig:parseConfig` — Missing or non-object config yields empty `github_token`, `default_owner`, and `default_repo`.
- `skill.zig:execute` — Token check is length-based; empty token skips command handlers.
- `skill.zig:handleIssue` / `handlePR` / `handleRelease` — Only `create` and `list` subcommands are implemented; others yield unknown subcommand errors.

## Side Effects

- `skill.zig:execute` — `ctx.respond` with allocated or static strings; no GitHub API calls in current code.
- `skill.zig:getMetadata` — Initializes `std.StringHashMap(std.json.Value)` on `page_allocator` for metadata bag (not populated in `getMetadata` body).

## Verification

- Run: `zig build test`
