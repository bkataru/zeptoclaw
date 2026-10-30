# Channels

## Overview

`src/channels` holds shared conversation I/O used across transports: a terminal REPL (`cli.zig`), ANSI formatters for roles and tools (`cli_utils.zig`), stdin line reading (`input.zig`), bounded in-memory chat history (`session.zig`, wired into `agent/loop.zig`), and provider streaming accumulation (`stream.zig`). The WhatsApp transport and native stack live under [./whatsapp/README.md](./whatsapp/README.md).

## Interface

- `cli.zig:runInteractiveSession` — Blocking REPL: prompts, slash commands, forwards other input to `agent.run`.
- `cli.zig:showPrompt` — Writes the green `Zeptoclaw>` prompt to stdout.
- `cli_utils.zig:formatMessagePrefix` — ANSI role prefix string for user, assistant, system, or tool.
- `cli_utils.zig:formatToolCall` — Writes a cyan “Calling {name} with {args}” line.
- `cli_utils.zig:formatToolResult` — Writes a cyan checkmark result line for a tool name.
- `cli_utils.zig:formatError` — Writes a red `Error:` line.
- `cli_utils.zig:formatStreamingToken` — Writes a streaming token chunk to any compatible writer.
- `cli_utils.zig:clearCurrentLine` — Sends `\r\x1b[K` to erase the current terminal line.
- `input.zig:readLine` — Prints `prompt`, reads up to 4096 bytes from stdin, returns an owned trimmed line.
- `input.zig:isEOF` — Non-blocking probe: true when stdin has no byte available (or read fails).
- `session.zig:Session` — In-memory message list with cap, start time, and monotonic message counter.
- `stream.zig:StreamHandler` — Comptime factory for a writer-typed handler that buffers and streams chunks.
- `stream.zig:handleStream` — Runs `client.streamCompletion` with chunk handler, returns owned full response.

## Invariants

- `cli.zig:runInteractiveSession` — Empty trimmed lines are skipped; `error.EndOfStream` from `readLine` exits without error.
- `cli.zig:runInteractiveSession` — Built-in slash commands are `/help`, `/exit`, `/quit`, `/clear`, `/session`, `/new`, `/reset`; other `/…` input is passed to the agent.
- `session.zig:Session.addMessage` — When `messages.items.len >= max_messages`, the oldest message is deinit’d and removed before append.
- `session.zig:Session.addMessage` — `message_count` increments on every append (including evictions).
- `session.zig:Session.clear` — Frees all messages and resets `message_count` to 0 without shrinking capacity.
- `session.zig:Session.getHistory` — Returns the live `messages.items` slice (not a copy).
- `input.zig:readLine` — Caller must `free` the returned slice; zero-byte read yields `error.EndOfStream`.
- `input.zig:readLine` — Single read bounded by a 4096-byte stack buffer (long lines truncate).
- `cli_utils.zig:formatMessagePrefix` — Returns string literals only (no allocation).
- `stream.zig:StreamHandler` — `handleChunk` appends to the internal buffer before calling `formatStreamingToken` on the same chunk.
- `stream.zig:StreamHandler` — `finalize` appends a newline via `writeAll`, then `dupe`s the buffer for the caller.

## Side Effects

- `cli.zig:runInteractiveSession` — Writes welcome, prompts, prefixed user/assistant lines, and command help to stdout; calls `agent.run` and `agent.session.clear` for session commands.
- `cli.zig:showPrompt` — Writes prompt bytes to stdout.
- `input.zig:readLine` — Writes prompt to stdout; reads stdin; allocates duplicate line text.
- `input.zig:isEOF` — Reads one byte from stdin via the compat IO reader.
- `session.zig:Session.init` — Records `compat.timestamp()` as `start_time`.
- `session.zig:Session.addMessage` — Appends owned `types.Message` values; may deinit evicted messages.
- `session.zig:Session.deinit` — Deinit’s every stored message and the message list.
- `cli_utils.zig:formatToolCall` / `cli_utils.zig:formatToolResult` / `cli_utils.zig:formatError` / `cli_utils.zig:formatStreamingToken` / `cli_utils.zig:clearCurrentLine` — Write ANSI/control bytes to the supplied writer (`std.Io.File` uses compat streaming writes).
- `stream.zig:handleStream` — Invokes `client.streamCompletion`; streams tokens to `writer`; returns allocator-owned full text from `finalize`.

## Verification

- Run: `zig build test`
