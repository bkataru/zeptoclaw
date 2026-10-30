# dirmacs_docs

## Overview

ZeptoClaw skill for searching and listing a JSON documentation index for DirMacs projects. Commands read `memory/dirmacs-docs-index.json` (path overridable via config); `rebuild` is a stub success message. See [./SKILL.md](./SKILL.md) for narrative docs.

## Interface

- `skill.zig:skill` — Skill struct with command dispatch and metadata registration.
- `skill.zig:init` — No-op; config is parsed on each `execute`.
- `skill.zig:execute` — Dispatches `search`, `list`, `rebuild`, `tree`, or `help` from `ctx.command`; returns `SkillResult` text messages or command/argument errors.
- `skill.zig:deinit` — No-op.
- `skill.zig:getMetadata` — Returns `sdk.SkillMetadata` for name `dirmacs-docs`, version `1.0.0`, category `docs`, with command triggers `dirmacs` and `docs`.

## Invariants

- `skill.zig:execute` — Per-run config defaults: `index_path` `memory/dirmacs-docs-index.json`, `dirmacs_path` `~/dirmacs`, `auto_rebuild` false.
- `skill.zig:loadIndex` — Missing index file yields an empty in-memory index (not an error); invalid JSON shape returns parse errors.
- `skill.zig:handleSearch` — Substring match on document name or any topic; empty results still succeed with a “no matches” message.
- `skill.zig:handleRebuild` — Always reports success with `0` repositories (scan not implemented).

## Side Effects

- `skill.zig:loadIndex` — Reads expanded `index_path` from cwd via `compat.cwd().openFile` (up to 1 MiB).
- `skill.zig:handleRebuild` — No index write; only allocates a success message string.
- `skill.zig:init` — None.

## Verification

- Run: `zig build test`
