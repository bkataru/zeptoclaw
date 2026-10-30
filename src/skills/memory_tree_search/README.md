# Memory Tree Search

## Overview

ZeptoClaw skill for vectorless, tree-oriented search over agent memory files (`MEMORY.md`, dated notes, relationships JSON). Commands build or query a conceptual tree index and summarize old transcripts via placeholder output. See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Exported skill module struct.
- `skill.zig:skill.init` — No-op initializer.
- `skill.zig:skill.execute` — Dispatches `memory-index`, `memory-search`, `memory-tree`, `summarize-transcripts`, `help`; unknown command returns `error.UnknownCommand`.
- `skill.zig:skill.deinit` — No-op.
- `skill.zig:skill.getMetadata` — Metadata name `memory-tree-search`, category `search`, mention/command/pattern triggers for memory recall phrasing.

## Invariants

- `skill.zig:parseConfig` — Defaults: `index_path` `memory/.tree-index.json`, `memory_files` includes `MEMORY.md`, `memory/*.md`, `memory/relationships.json`, `auto_reindex` false; `index_path` and `auto_reindex` overridable from JSON.
- `skill.zig:handleIndex` — Returns fixed placeholder indexing transcript referencing `cfg.index_path`.
- `skill.zig:handleSearch` — Requires `ctx.args`; if query contains `nufast` or `skill`, returns canned section content; otherwise suggests example queries.
- `skill.zig:handleTree` — Returns static ASCII tree of example sections (does not read index file in handler).
- `skill.zig:handleSummarize` — Returns static example session summary block.
- `skill.zig:handleHelp` — Lists commands and stated benefits (fast, accurate, explainable, no vector DB).

## Side Effects

- `skill.zig:skill.execute` — Allocates formatted messages on `ctx.allocator` only; handlers do not read or write index files in the current implementation.

## Verification

- Run: `zig build test`
