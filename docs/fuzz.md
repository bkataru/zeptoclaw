# Fuzzing

Unit tests call `std.testing.fuzz` with a small corpus (once per `zig build test`). Extra mutations: `src/fuzz_mutate.zig` (400 havoc iterations, seed `0x7e970c1a`).

`zig build test --fuzz` on Zig 0.16.0 fails to rebuild: compiler `test_runner.zig` mixes `builtin.StackTrace` and `debug.StackTrace`. Bypass:

```bash
./zig-out/bin/zeptoclaw fuzz           # 50000 havoc iters, no NIM
./zig-out/bin/zeptoclaw fuzz 2000
```

Nightly (optional): copy `contrib/systemd/zeptoclaw-fuzz.{service,timer}` and `systemctl --user enable --now zeptoclaw-fuzz.timer`.

Targets (no NIM HTTP):

| Surface | Code |
|---------|------|
| Inbound JSON | `WhatsAppChannel.parseMessage` / `parseConnectionUpdate` |
| Journal JID | `memory.lineBelongsToChat` |
| pending-turns.jsonl | `pending.loadFrom` / enqueue |
| Tool JSON | `hydrateToolCallsFromContent` |
| UPDATE/SKIP/COMPACT | `memory_update` / `memory_compact` `parseDecision` |
| NIM completion JSON | `nim.tryParseCompletion` |
| last-image index | `inbound_media.loadLast` |
| Presence slots | `engagement.subscribe` |

Redacted seed shapes: `testdata/fuzz/seeds.jsonl` (dummy E.164 `1555555010x`, bodies `x`). Do not commit live journals or phone numbers.

Properties in `zig build test`: suffix JID is not a match; `dailyContextAt` keeps chats apart; pending enqueue/ack round-trip; parseMessage rejects non-objects.
