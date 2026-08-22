# Contributing

## Setup

Zig **0.16.0**. `zig build` and `zig build test --summary all`.

Node 18+ for WhatsApp (`ZEPTO_NODE` if needed). Do not commit `sessions/`, `.env`, or live tokens.

## Zig 0.16 notes

- `ArrayList.append` / `appendSlice` / `deinit` / `toOwnedSlice` take the allocator.
- `std.json.ObjectMap.init(allocator, &.{}, &.{})`.
- `compat.getIo()` uses a failing `processSpawn` — spawn Node (and memory children) with a dedicated `std.Io.Threaded`, never `compat.getIo()`.
- Public alloc/ownership transfers need a greppable `/// Memory:` comment (caller owns vs callee takes).

## Layout

- Agent loop — WhatsApp and CLI must go through it, not a one-shot NIM chat.
- WhatsApp — live Baileys path under `src/channels/whatsapp/`. `native/` is the unfinished stack.
- Memory — daily journals vs ingest (`memory update`) vs compact (`memory compact`). See `docs/memory.md`.
- Tests live next to code (`zig build test`). Skip project-wide formatters unless you are checking a change.

## Docs

Update `README.md` / `CHANGELOG.md` / `DEPLOYMENT.md` / `docs/` when behavior changes. Do not paste phone numbers, chat bodies, or production tokens into markdown.

## PRs

Small, focused diffs. Do not add logs, `node_modules`, or `.sisyphus` scratch.
