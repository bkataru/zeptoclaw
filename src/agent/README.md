# Agent

## Overview

The `src/agent` package implements the Zeptoclaw conversational agent: NVIDIA NIM tool-use loop, workspace-scoped file/exec/search tools, long-term and daily memory (IST calendar), JSONL transcripts, scheduled cron turns, and isolated NIM jobs that synthesize or compact `MEMORY.md`. Message helpers re-export provider types and build chat payloads for tools and the loop.

## Interface

- `core_tools.zig:setWorkspace` — Sets thread-local workspace root for path resolution (default `"."`).
- `core_tools.zig:setExecEnabled` — Enables or disables `exec` tool (WhatsApp operator fromMe DMs).
- `core_tools.zig:execEnabled` — Returns whether exec is allowed.
- `core_tools.zig:workspace` — Returns current thread-local workspace path.
- `core_tools.zig:setVisionImage` — Attaches turn image path and MIME for `see_image`.
- `core_tools.zig:setVisionClient` — Sets API key, model, and base URL for vision/audio/video tools.
- `core_tools.zig:setChatId` — Sets thread-local chat/session id for memory journal lines.
- `core_tools.zig:readTool` — JSON tool: read workspace file (UTF-8, capped).
- `core_tools.zig:writeTool` — JSON tool: write workspace file.
- `core_tools.zig:editTool` — JSON tool: first-occurrence string replace in workspace file.
- `core_tools.zig:execTool` — JSON tool: `/bin/sh -c` in workspace with approval gate.
- `core_tools.zig:approveExec` — Appends trimmed command to exec approvals file.
- `core_tools.zig:webSearchTool` — JSON tool: DuckDuckGo HTML via `curl`.
- `core_tools.zig:seeImageTool` — JSON tool: vision model on attached image.
- `core_tools.zig:setAudioAttachment` — Attaches turn audio for `hear_audio`.
- `core_tools.zig:hearAudioTool` — JSON tool: transcribe attached audio via omni model.
- `core_tools.zig:setVideoAttachment` — Attaches turn video for `watch_video`.
- `core_tools.zig:watchVideoTool` — JSON tool: describe attached video (size-capped read).
- `core_tools.zig:resetPresence` — Clears listen/leave flags for a new turn.
- `core_tools.zig:wantSilent` — True if listen or leave was requested this turn.
- `core_tools.zig:wantLeave` — True if leave was requested this turn.
- `core_tools.zig:listenTool` — JSON tool: silent this turn, still record inbound.
- `core_tools.zig:leaveTool` — JSON tool: leave chat until barvis wake.
- `core_tools.zig:memoryGetTool` — JSON tool: read `MEMORY.md` or daily journal slice.
- `core_tools.zig:memorySearchTool` — JSON tool: ranked memory search.
- `core_tools.zig:memoryAppendTool` — JSON tool: append to long-term or daily memory.
- `core_tools.zig:memoryEditTool` — JSON tool: replace substring in memory files.
- `core_tools.zig:SkillHandlerFn` — Callback type for delegated skill execution.
- `core_tools.zig:setSkillHandler` — Registers optional skill handler for `skill` tool.
- `core_tools.zig:skillTool` — JSON tool: invoke registered skill by name.
- `core_tools.zig:ParamHold` — Holds parsed JSON parameter schemas for tool registration.
- `core_tools.zig:ParamHold.deinit` — Frees held parsed JSON values.
- `core_tools.zig:registerAll` — Registers all core tools into a `ToolRegistry`.
- `core_tools.zig:collectDefinitions` — Builds provider `ToolDefinition` slice from registry.
- `cron.zig:intervalSecs` — Cron period from `ZEPTO_CRON_SECS` (0 = disabled).
- `cron.zig:runLoop` — Blocking interval loop spawning agent turns with session id `cron`.
- `loop.zig:TurnOpts` — Per-turn options (prompts, media paths, `max_iters`).
- `loop.zig:Agent` — Main agent: session, tools, transcripts, NIM client, workspace.
- `loop.zig:Agent.init` — Constructs agent, registers tools, resolves workspace and transcript dir.
- `loop.zig:Agent.setWorkspace` — Sets workspace path (frees prior owned path if any).
- `loop.zig:Agent.setSessionId` — Sets session id for transcripts and memory.
- `loop.zig:Agent.setVisionModel` — Sets vision model name when non-empty.
- `loop.zig:Agent.deinit` — Releases session, registries, skill, owned paths.
- `loop.zig:Agent.run` — Single-turn alias calling `runTurn` with default opts.
- `loop.zig:Agent.runTurn` — Tool-use loop until text reply, silent, or leave.
- `loop.zig:Agent.isTransient` — Whether a provider error should be retried indefinitely.
- `loop.zig:shouldRetryChatError` — Policy helper: transient provider errors retry, permanent errors end the turn (the permanent budget of 3 lives in `NIMClient.chatWithTools`; the agent loop does not spend it again).
- `loop.zig:sanitizeReply` — Drops invalid UTF-8 from model replies for display.
- `memory.zig:Civil` — Gregorian date (year, month, day).
- `memory.zig:civilFromUnixDays` — Converts Unix day count to `Civil`.
- `memory.zig:civilNowIst` — Today's civil date in IST (UTC+5:30).
- `memory.zig:clockIst` — Current hour and minute in IST.
- `memory.zig:dailyPath` — Allocates `{ws}/memory/YYYY-MM-DD.md` path with day offset.
- `memory.zig:journalAppend` — Appends timestamped line to today's daily journal file.
- `memory.zig:lineBelongsToChat` — True if journal line contains `] (chat_id):` marker.
- `memory.zig:dailyContextAt` — Same-chat lines from today and yesterday (capped).
- `memory.zig:dailyContext` — Resolves workspace and calls `dailyContextAt`.
- `memory.zig:looksLikeRememberRequest` — Heuristic for explicit remember phrasing.
- `memory.zig:shouldPersistNote` — Whether to auto-persist a DM exchange to `MEMORY.md`.
- `memory.zig:persistDmNote` — Writes durable note under auto heading when heuristics match.
- `memory.zig:getLongTerm` — Reads `MEMORY.md` up to cap.
- `memory.zig:getDaily` — Reads daily journal for IST today or yesterday offset.
- `memory.zig:appendLongTerm` — Appends clipped note via auto-section merge.
- `memory.zig:appendDailyNote` — Appends `[note]` line to today's journal.
- `memory.zig:recall` — Ranked line recall over `MEMORY.md` and journals.
- `memory.zig:search` — Tool-facing search wrapper over recall (20 hits).
- `memory.zig:replaceIn` — First replace in workspace-relative path; trims `MEMORY.md` to cap.
- `memory.zig:compactFromDaily` — Spawns `zeptoclaw memory update` or extractive fallback.
- `memory.zig:intervalSecs` — Memory compact loop period from `ZEPTO_MEMORY_SECS` (default 1800).
- `memory.zig:runLoop` — Blocking loop calling `compactFromDaily`.
- `memory_compact.zig:Decision` — NIM decide outcome: `compact` or `skip`.
- `memory_compact.zig:parseDecision` — Parses first token of model decide reply.
- `memory_compact.zig:runOnce` — Two-phase NIM compact of existing `MEMORY.md`.
- `memory_update.zig:extractMarkdown` — Strips optional markdown fences from model output.
- `memory_update.zig:looksLikeMemoryDoc` — Validates synthesized text looks like memory markdown.
- `memory_update.zig:Decision` — NIM decide outcome: `update` or `skip`.
- `memory_update.zig:parseDecision` — Parses first token of model decide reply.
- `memory_update.zig:runOnce` — Journal-driven NIM update of `MEMORY.md`.
- `message.zig:Message` — Re-export of provider message type.
- `message.zig:ToolCall` — Re-export of provider tool call type.
- `message.zig:MessageRole` — Re-export of provider role enum.
- `message.zig:fromJSON` — Parses JSON object into owned `Message`.
- `message.zig:extractToolCalls` — Returns optional tool call slice from message.
- `message.zig:userMessage` — Allocates user role message with content.
- `message.zig:assistantMessage` — Allocates assistant role message with content.
- `message.zig:toolResultMessage` — Allocates tool result message with call id.
- `tools.zig:ToolFn` — Tool handler function pointer type.
- `tools.zig:Tool` — Named tool with description, JSON schema, handler.
- `tools.zig:Tool.deinit` — Frees owned name and description strings.
- `tools.zig:ToolRegistry` — String-keyed map of tools.
- `tools.zig:ToolRegistry.init` — Creates empty registry.
- `tools.zig:ToolRegistry.deinit` — Frees all registered tools.
- `tools.zig:ToolRegistry.register` — Inserts tool (owns name and description).
- `tools.zig:ToolRegistry.get` — Lookup by name.
- `tools.zig:ToolRegistry.execute` — Runs handler or returns `error.ToolNotFound`.
- `tools.zig:echoTool` — Test/demo tool echoing JSON `message` field.
- `tools.zig:currentTimeTool` — Returns Unix timestamp string.
- `transcript.zig:Store` — JSONL transcript writer per sanitized session id.
- `transcript.zig:Store.init` — Creates store with directory and keep count (40 lines).
- `transcript.zig:Store.append` — Appends one JSON line and compacts if over keep.

## Invariants

- `core_tools.zig:resolveInWorkspace` — Empty path, NUL, or absolute path outside workspace → `InvalidPath` / `PathEscape`; absolute paths must start with workspace prefix.
- `core_tools.zig:readTool` — Read size capped at 64 KiB; invalid JSON returns error string, not Zig error.
- `core_tools.zig:editTool` — File read capped at 256 KiB; replaces first `old_str` only.
- `core_tools.zig:execTool` — Denied when exec disabled, unapproved mutating command, or empty command; stdout 64 KiB / stderr 16 KiB limits via `runParentEnv`.
- `core_tools.zig:execApproved` — Allowlist readonly prefixes, `ZEPTO_EXEC_APPROVE` / `ZEPIO_EXEC_APPROVE`, or line in approvals file.
- `core_tools.zig:visionBreakerOpen` — After 3 vision failures, blocks media tools for 600 s cooldown (shared by see/hear/watch).
- `core_tools.zig:watchVideoTool` — Attached video read capped at 20 MiB (`VIDEO_MAX_BYTES`).
- `core_tools.zig:registerAll` — `ParamHold` holds up to 16 parsed parameter schemas; must outlive registry use.
- `cron.zig:runLoop` — No-op when `intervalSecs()` is 0; cron turn uses `max_iters` 4.
- `loop.zig:TurnOpts` — Default `max_iters` 200.
- `loop.zig:Agent.runTurn` — At `max_iters`, subsequent chat calls omit tool definitions; empty choices or blank assistant text retries with backoff.
- `loop.zig:Agent.chatUntilDone` — Transient provider errors retry without cap; the first permanent (non-transient) error is returned immediately.
- `loop.zig:hydrateToolCallsFromContent` — Text JSON tool calls get unique `text-tool-{n}` ids.
- `loop.zig:sanitizeUtf8` — Tool results replaced with U+FFFD on invalid UTF-8 before NIM history.
- `loop.zig:sanitizeReply` — Invalid UTF-8 code units dropped (not replaced) in outbound replies.
- `memory.zig:MEMORY_CAP` — Long-term memory file target size 32 KiB; `trimToCap` drops oldest auto notes.
- `memory.zig:dailyContextAt` — Returns null if fewer than ~72 bytes of filtered content; tail capped at 12 KiB.
- `memory.zig:recall` — Query terms: alnum runs ≥3 chars, max 12, stopwords excluded; max 16 scored hits internally; output capped ~6 KiB.
- `memory.zig:search` — Empty query returns error string; no matches returns `(no matches)`.
- `memory.zig:replaceIn` — Empty `old_str` errors; first match only.
- `memory.zig:spawnMemoryUpdate` — Skipped in tests; runs `$HOME/zeptoclaw/zig-out/bin/zeptoclaw memory update`.
- `memory_compact.zig:runOnce` — Skips NIM if `MEMORY.md` < 80 bytes or mtime ≤ last compact stamp; invalid model output leaves file unchanged (`InvalidCompact`).
- `memory_update.zig:runOnce` — Skips if no journal turn markers or journals mtime ≤ last update; invalid output leaves file unchanged (`InvalidUpdate`).
- `memory_update.zig:preserveAutoSection` — Re-appends old auto section if model output omitted it.
- `message.zig:fromJSON` — Missing or invalid role → `error.InvalidRole`.
- `tools.zig:ToolRegistry.execute` — Unknown tool name → `error.ToolNotFound`.
- `transcript.zig:Store.append` — Session id sanitized to alphanumeric, `-`, `_`; keeps last 40 JSONL lines then prepends compaction system note.

## Side Effects

- `core_tools.zig:readTool` / `writeTool` / `editTool` — Read/write workspace files via process CWD.
- `core_tools.zig:execTool` — Spawns `/bin/sh -c`; may append pending command to `sessions/exec-pending.txt`.
- `core_tools.zig:approveExec` — Appends to `~/.zeptoclaw/sessions/exec-approvals.txt` (or fallback path).
- `core_tools.zig:webSearchTool` — Network HTTP via `curl` to DuckDuckGo.
- `core_tools.zig:seeImageTool` / `hearAudioTool` / `watchVideoTool` — NIM HTTP chat; updates global vision failure atomics.
- `core_tools.zig:memoryAppendTool` / `memoryEditTool` — Writes under workspace `MEMORY.md` or `memory/*.md`.
- `core_tools.zig:listenTool` / `leaveTool` — Sets thread-local presence flags.
- `core_tools.zig:setWorkspace` / `setExecEnabled` / `setVisionImage` / etc. — Thread-local and module globals (`g_skill`, approval path caches).
- `cron.zig:runLoop` — Loads config, NIM client, agent; logs replies; sleeps with `nanosleep`.
- `loop.zig:Agent.runTurn` — NIM `chatWithTools`; session history mutation; transcript append; `engagement.unsubscribe` on leave; sets `g_skill_agent` during turn.
- `memory.zig:journalAppend` / `appendLongTerm` / `appendDailyNote` / `persistDmNote` / `replaceIn` / `compactFromDaily` — Workspace memory files and `memory/heartbeat-state.json`.
- `memory.zig:spawnMemoryUpdate` — Child process `zeptoclaw memory update`.
- `memory.zig:runLoop` — Periodic `compactFromDaily` and sleep.
- `memory_compact.zig:runOnce` — NIM chat; may rewrite `MEMORY.md` and `memory/heartbeat-state.json`.
- `memory_update.zig:runOnce` — NIM chat; reads SOUL/IDENTITY/MEMORY; writes `MEMORY.md` and heartbeat JSON.
- `transcript.zig:Store.append` — Creates transcript dir; rewrites `{session}.jsonl` with compaction.

## Verification

- Run: `zig build test`
