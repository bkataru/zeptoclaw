# Contributing

## Setup

Zig **0.16.0**. `zig build` and `zig build test --summary all`.

Do not commit `sessions/`, `.env`, or live tokens.

## Zig 0.16 notes

- `ArrayList.append` / `appendSlice` / `deinit` / `toOwnedSlice` take the allocator.
- `std.json.ObjectMap.init(allocator, &.{}, &.{})`.
- `compat.getIo()` uses a failing `processSpawn`. Spawn `zeptoclaw memory update` children with a dedicated `std.Io.Threaded`, never `compat.getIo()`.
- Public alloc/ownership transfers need a greppable `/// Memory:` comment (caller owns vs callee takes).

## Layout

- `src/agent/loop.zig` - `runTurn` (tools + NIM). Gateway WhatsApp must go through this, not a one-shot `NIMClient.chat`.
- `src/channels/whatsapp/` - live native multi-device client (`native/`). Pair with `zeptoclaw whatsapp pair`. Session store: `{auth_dir}/native.sqlite`.
- `src/agent/memory.zig` - `journalAppend`, extractive fallback compact.
- `src/agent/memory_update.zig` - ingest (`zeptoclaw memory update`).
- `src/agent/memory_compact.zig` - densify (`zeptoclaw memory compact`).
- Tests live next to code (`zig build test`). Skip project-wide formatters unless you are checking a change.

## Docs

Update `README.md` / `CHANGELOG.md` / `DEPLOYMENT.md` / `docs/` when behavior changes. Do not paste phone numbers, chat bodies, or production tokens into markdown.

## PRs

Small, focused diffs. Do not add logs, `node_modules`, or `.sisyphus` scratch.

## Fuzzing

`std.testing.fuzz` tests live next to parsers (inbound JSON, journal JID, pending jsonl, tool hydrate, memory decide). Corpus runs in `zig build test`. `zig build test --fuzz` is broken on Zig 0.16.0 (`test_runner` StackTrace). Extra mutations: `src/fuzz_mutate.zig` (400 in `zig build test`). Longer: `zeptoclaw fuzz 50000` or `contrib/systemd/zeptoclaw-fuzz.timer`. See `docs/fuzz.md`.
