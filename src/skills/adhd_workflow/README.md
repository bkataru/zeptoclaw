# adhd_workflow

## Overview

ZeptoClaw skill module that turns overwhelming tasks into short, actionable text responses. Commands dispatch on `ctx.command` (`breakdown`, `chunk`, `focus`, `simplify`, `help`); config JSON is parsed per run but most handlers ignore it today. Human-oriented usage notes live in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Skill struct exported to the loader; lifecycle and metadata hooks below.
- `skill.zig:init` — No-op; ignores allocator and config JSON.
- `skill.zig:execute` — Requires `ctx.command`; routes to breakdown/chunk, focus, simplify, or help; returns `SkillResult` with a formatted message (`data` always null) or `error.NoCommand` / `error.UnknownCommand` / `error.MissingArgument`.
- `skill.zig:deinit` — No-op; no owned global state.
- `skill.zig:getMetadata` — Returns `sdk.SkillMetadata` registering name `adhd-workflow`, version `1.0.0`, category `workflow`, and triggers: mention patterns (`adhd`, `overwhelmed`, `stuck`, `can't focus`), commands (`breakdown`, `chunk`, `focus`, `simplify`), and regex patterns for overwhelm/paralysis phrasing.

## Invariants

- `skill.zig:execute` — `breakdown` and `chunk` are equivalent; both require `ctx.args` as the task string.
- `skill.zig:execute` — `focus` and `simplify` require `ctx.args`; keyword substrings in the task (e.g. CI, deploy, test, document) select canned step lists.
- `skill.zig:execute` — Successful handlers return `SkillResult.success = true` with an allocator-owned `message` and `data = null`.
- `skill.zig:getMetadata` — Metadata description states ADHD-friendly task execution (break down, reduce friction, maintain focus).

## Side Effects

- `skill.zig:execute` — Allocates response strings via `ctx.allocator`; no filesystem or network I/O.
- `skill.zig:init` — None.
- `skill.zig:deinit` — None.

## Verification

- Run: `zig build test`
