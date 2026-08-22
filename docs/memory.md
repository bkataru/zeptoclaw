# Memory

Three jobs. They write different files.

## Daily journal (raw)

`gateway_server.zig` calls `memory.journalAppend` on every WhatsApp turn:

- `[in]` before `runTurn`
- `[out]` after a successful send
- Path: `~/.zeptoclaw/workspace/memory/YYYY-MM-DD.md` (Gregorian IST via `civilFromUnixDays`)
- Full message text (no 2000-char clip). Rewrite-on-append rereads at most 8MB of the existing daily file.

This is the trace. `MEMORY.md` is distilled later.

## Tools (`core_tools.zig`)

Turns do not inject `MEMORY.md` or daily files into the system prompt. The model can call:

| Tool | Args | File |
|------|------|------|
| `memory_get` | `which=long\|daily\|yesterday` | `MEMORY.md` or today's/yesterday's journal |
| `memory_search` | `query`, optional `include_long` | `MEMORY.md` + recent journals |
| `memory_append` | `text`, `target=long\|daily` | `MEMORY.md` or today |
| `memory_edit` | `old_str`, `new_str`, `target=long\|daily` | replace span |

`core_tools.setChatId` is called from `loop.zig` so appends tag the chat.

## Ingest (30 min): `zeptoclaw memory update`

`memory.runLoop` sleeps `ZEPTO_MEMORY_SECS` (default 1800) then `std.process.run`s `~/zeptoclaw/zig-out/bin/zeptoclaw memory update`. Own process, own NIM backoff (`NIMClient` in the child). Account quota is still shared.

`memory_update.runOnce`:

1. Load today + yesterday journals. Exit with no NIM if no `[in]`/`[out]`/`[note]`, or if journal mtime `<= lastMemoryUpdate` in `memory/heartbeat-state.json`.
2. Decide turn: reply must start with `UPDATE` or `SKIP` (`parseDecision`).
3. On `UPDATE`, second `nim.chat` synthesizes `MEMORY.md` (prompt: facts, not dump of `[in]`/`[out]`). Cap 32KB. `preserveAutoSection` keeps `## Running notes (auto)` if the model dropped it.

If the child fails, `compactFromDaily` copies up to 8 long `[out]` lines (skip `{"name"`) under `## Running notes (auto)`.

First ingest waits one interval after gateway start.

## Compact (2 h): `zeptoclaw memory compact`

`barvis-memory-update.timer` -> `barvis-memory-update.service` -> `zeptoclaw memory compact`.

Does not load journals. `memory_compact.runOnce` reads `MEMORY.md`, skips if `< 80` bytes or mtime `<= lastMemoryCompact`. Decide `COMPACT`/`SKIP`, then rewrite: fold auto notes into durable sections, merge duplicates, drop pings/tool JSON. NVIDIA key: `~/.config/zeptoclaw/nim.env`.

Stamps keep both `lastMemoryUpdate` and `lastMemoryCompact` in `heartbeat-state.json`.

## Disable

- Ingest: `ZEPTO_MEMORY_SECS=0` on the gateway unit.
- Compact: `systemctl --user disable --now barvis-memory-update.timer`.
