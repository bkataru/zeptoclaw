# Operational Safety

## Overview

Message-based security skill: prompt-injection heuristics, dangerous-shell substring checks, and slash commands for safety status and identity/auth reporting. Returns empty success when no rule matches. Policy and operator guidance are in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — exported skill struct for security hardening hooks.
- `skill.zig:skill.init` — no-op; config treated as constant at runtime via `parseConfig`.
- `skill.zig:skill.execute` — requires message content; optionally blocks on injection patterns; handles `/safety-check`, `/verify-identity`, `/auth-status`, dangerous commands, or returns empty `successResponse`.
- `skill.zig:skill.deinit` — no-op.
- `skill.zig:skill.getMetadata` — id `operational-safety`, version `1.0.0`, enabled skill describing prompt injection defense and privileged command authorization.

## Invariants

- `skill.zig:parseConfig` — ignores `config_json`; always sets `trusted_whatsapp_number = "+919182065182"`, `enable_prompt_injection_detection = true`, `log_privileged_operations = true`, `require_explicit_auth = true`.
- `skill.zig:detectPromptInjection` — case-insensitive substring match against fixed `injection_patterns` list (via `toLower`, which currently returns input unchanged).
- `skill.zig:containsDangerousCommand` — substring match against `dangerous_commands` list (`sudo rm -rf`, `chmod 777`, `rm -rf /`, fork bomb pattern, `dd if=/dev/zero`).
- `skill.zig:skill.execute` — prompt injection path returns `SkillResult.stop`; dangerous command path returns `SkillResult.stop` after warning; unmatched messages return success with empty string.

## Side Effects

- `skill.zig:skill.execute` — `ctx.respond` with allocated warning or status text on matched paths; `SkillResult.stop` ends processing for injection and dangerous commands.
- `skill.zig:skill.getMetadata` — metadata hash map allocated with `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
