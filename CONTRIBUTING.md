# Contributing

## Setup

Zig **0.16.0**. `zig build` and `zig build test --summary all`.

Node 18+ for WhatsApp (`ZEPTO_NODE` if needed). Do not commit `sessions/`, `.env`, or live tokens.

## Zig 0.16 notes

- `ArrayList.append` / `appendSlice` / `deinit` / `toOwnedSlice` take the allocator.
- `std.json.ObjectMap.init(allocator, &.{}, &.{})`.
- `compat.getIo()` uses a failing `processSpawn` — spawn Node with a dedicated `std.Io.Threaded`, never `compat.getIo()`.
- Public alloc/ownership transfers need a greppable `/// Memory:` comment (caller owns vs callee takes).

## Layout

- `src/agent/loop.zig` — `runTurn` (tools + NIM). Gateway WhatsApp must go through this, not a one-shot `NIMClient.chat`.
- `src/channels/whatsapp/` — live Baileys path. `native/` is the unfinished whatsmeow port.
- Tests live next to code (`zig build test`). Skip project-wide formatters unless you are checking a change.

## Docs

Update `README.md` / `DEPLOYMENT.md` / `docs/` when behavior changes. Do not paste phone numbers, chat bodies, or production tokens into markdown.

## PRs

Small, focused diffs. Do not add logs, `node_modules`, or `.sisyphus` scratch.
