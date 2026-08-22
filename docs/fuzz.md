# Fuzzing

Unit tests call `std.testing.fuzz` with a small corpus (runs once in `zig build test`).

Continuous:

```bash
zig build test --fuzz
# or time-bounded
zig build test --fuzz=30s
```

Targets (no NIM, no Baileys):

| Test | File | Surface |
|------|------|---------|
| fuzz inbound json parse | `whatsapp_channel.zig` | Baileys JSON -> `parseMessage` / `parseConnectionUpdate` |
| fuzz journal jid isolation | `memory.zig` | `lineBelongsToChat` |
| fuzz pending jsonl | `pending.zig` | `pending-turns.jsonl` |
| fuzz hydrate tool json | `loop.zig` | leaked chat JSON -> tool calls |
| fuzz parseDecision | `memory_update.zig` / `memory_compact.zig` | UPDATE/SKIP/COMPACT |

Do not fuzz `runTurn` or WhatsApp connect.

`zig build test --fuzz` on Zig 0.16.0 fails to rebuild: compiler `test_runner.zig` mixes `builtin.StackTrace` and `debug.StackTrace`. Corpus still runs in `zig build test`. Extra mutations: `src/fuzz_mutate.zig` (400 havoc iterations, seed `0x7e970c1a`).
