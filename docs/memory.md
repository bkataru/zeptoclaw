# Memory

Three tempos. They are not the same job.

## Daily journal (raw)

Every WhatsApp turn appends to `~/.zeptoclaw/workspace/memory/YYYY-MM-DD.md` (Gregorian date in IST).

- `[in]` before the model runs
- `[out]` after a successful send
- Full message text. Distillation happens later, in long-term memory.

This file is the trace. Do not treat it as curated knowledge.

## Tools (on demand)

The chat model is not given the long-term file on every turn. It can call:

| Tool | Idea |
|------|------|
| `memory_get` | Read long-term, today, or yesterday |
| `memory_search` | Search long-term + recent journals |
| `memory_append` | Append to long-term or today’s journal |
| `memory_edit` | Replace a span in long-term or today |

Use these when a fact should be remembered *in the conversation*, not as a mandatory state-machine step.

## Ingest (about every 30 minutes)

`zeptoclaw memory update`, spawned from the gateway compact loop (`ZEPTO_MEMORY_SECS`, default 1800). Own process, own NVIDIA backoff.

1. No NIM if journals have no turns, or files have not changed since the last stamp.
2. One decide turn: `UPDATE <reason>` or `SKIP <reason>`.
3. Only UPDATE: synthesize long-term memory from the current document plus recent journals. Prompt asks for facts, not a dump of `[in]`/`[out]`.

If the child fails, the gateway may copy a few long `[out]` lines under `## Running notes (auto)` as a last resort.

The first ingest waits one interval after gateway start so a restart does not steal the first chat.

## Compact (about every 2 hours)

`zeptoclaw memory compact` via `barvis-memory-update.timer`. Different role from ingest.

It does **not** fold new chat logs in. It compresses the long-term document: fold auto notes into durable sections, merge duplicates, drop pings and tool JSON. Decide `COMPACT` / `SKIP`; skip if the file has not changed since the last compact.

NVIDIA key for this oneshot: `~/.config/zeptoclaw/nim.env` (not git).

## Caps

Long-term memory is capped at 32KB when written back by ingest/compact. Journals are not given that cap; a rewrite of a huge daily file still rereads at most 8MB when appending.

## Disable

- Ingest loop: `ZEPTO_MEMORY_SECS=0` on the gateway.
- Two-hour compact: `systemctl --user disable --now barvis-memory-update.timer`.
