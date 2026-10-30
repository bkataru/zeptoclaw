# git_workflow

## Overview

ZeptoClaw skill that interprets chat messages starting with `/git-status`, `/git-commit`, `/git-push`, `/git-pull`, and `/git-branch`. Responses are canned git-style text (no real `git` subprocess yet). Config supplies default branch and safety flags per execution. See [./SKILL.md](./SKILL.md). Test-only code in `git_workflow_test.zig` is out of scope for this contract.

## Interface

- `skill.zig:skill` — Skill struct for git workflow slash commands.
- `skill.zig:init` — No-op.
- `skill.zig:execute` — Parses message content and config; handles known prefixes or returns empty success; uses `ctx.respond` plus `SkillResult` helpers.
- `skill.zig:deinit` — No-op.
- `skill.zig:getMetadata` — Registers `id` `git-workflow`, `name` `Git Workflow`, version `1.0.0`, `enabled` true, `metadata` null.

## Invariants

- `skill.zig:parseConfig` — Defaults: `default_branch` `main`, `enable_rebase` true, `force_push_protection` true; overridable from JSON object keys of the same names.
- `skill.zig:handlePush` — When `force_push_protection` and target equals `default_branch`, returns `SkillResult.stop` with a warning (does not simulate push).
- `skill.zig:execute` — Unrecognized messages still return `SkillResult.successResponse` with an empty string.

## Side Effects

- `skill.zig:execute` — Allocates formatted responses; frees some response buffers after building `SkillResult` in status/commit/push/pull/branch handlers.
- `skill.zig:execute` — No git CLI or network I/O in current implementation.

## Verification

- Run: `zig build test`
