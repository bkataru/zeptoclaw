# Zig 0.15.2 Migration Completion & Production Hardening

## TL;DR

> **Quick Summary**: Complete Zig 0.15.2 API migration by fixing 9 skill modules, restore integration tests, fix thread safety, and add production hardening features.
>
> **Deliverables**:
> - All Zig 0.15.2 API issues resolved (ArrayList.toOwnedSlice fixes)
> - Build exits with code 0 (confirmed)
> - All tests passing (unit + integration)
> - Thread safety issues fixed
> - HTTP timeouts, config validation, graceful shutdown implemented
> - No sensitive data in logs
>
> **Estimated Effort**: XL (10-15 days)
>
> **Parallel Execution**: YES - 5-8 tasks per wave across independent modules
>
> **Critical Path**: Skill API fixes → Build verification → Integration tests → Thread safety → Production features

---

## Context

### Original Request
"Complete Zig 0.15.2 API migration across all modules with exhaustive analysis and agent delegation."

### Interview Summary
**Key Findings**:
- 9 skill modules use outdated `ArrayList.toOwnedSlice()` (missing allocator argument) - compilation errors
- WhatsApp channel has thread safety data races
- Integration tests disabled due to Config struct mismatch
- HTTP requests lack timeouts
- Sensitive credentials logged to stdout
- ConfigLoader errdefer bug causes potential leak
- 31 `@intCast` uses need validation
- Global mutable state in skills is not thread-safe
- Production readiness gaps (shutdown, validation, observability)

**Research Findings**:
- Zig 0.15.2 ArrayList API: `toOwnedSlice(allocator)` mandatory for managed lists
- Thread safety requires mutexes or atomics for shared state
- HTTP client needs explicit timeout configuration
- Structured logging via `std.log` with scopes recommended

### Metis Review (Pending Consultation)
- Identified gaps: test coverage, error handling consistency, graceful shutdown
- Guardrails: No scope creep, prioritize CRITICAL fixes first, maintain backward compatibility

---

## Work Objectives

### Core Objective
Complete Zig 0.15.2 migration to production-ready state with zero compilation errors, passing tests, and thread-safe operation.

### Concrete Deliverables
1. [ ] All 38 `toOwnedSlice()` calls fixed across 9 skill modules
2. [ ] Build compiles with `zig build` → exit code 0
3. [ ] Integration tests enabled and passing (`zig build test`)
4. [ ] WhatsApp channel thread safety fixed (mutexes/atomics)
5. [ ] HTTP request timeouts implemented in NIMClient
6. [ ] Sensitive data removed from logs
7. [ ] ConfigLoader errdefer bug fixed
8. [ ] All `@intCast` replaced with safe conversions or validated
9. [ ] `catch unreachable` replaced with proper error handling (except truly unreachable cases)
10. [ ] Skill global state eliminated (config per-instance)
11. [ ] Configuration validation at startup
12. [ ] Graceful shutdown (signal handling, resource cleanup)
13. [ ] StateStore.save() implemented
14. [ ] Structured logging standardized
15. [ ] Unit test coverage >=80% for modified modules
16. [ ] Backup file removed

### Definition of Done
- [ ] `zig build` exits with 0, no warnings
- [ ] `zig build test` exits with 0, all tests pass
- [ ] No data races detected (manual ThreadSanitizer or stress test)
- [ ] No memory leaks in 10-minute continuous run (valgrind或 equivalent)
- [ ] All code reviewed against Zig 0.15.2 best practices

### Must Have
- All 9 skill files must compile with Zig 0.15.2 API
- Thread safety fixes must not break existing single-threaded operation
- Integration tests must pass with real NVIDIA API key (or skip gracefully)
- No breaking changes to public APIs (Config, NIMClient, Channel interfaces)

### Must NOT Have (Guardrails)
- No simplification of migration scope - ALL 9 skill files must be fixed
- No removal of existing test assertions to make tests pass
- No hardcoded test values that mask real failures
- No disabling of tests to meet deadline
- No introduction of new global mutable state
- No sensitive data in any log output (including error messages)

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (Zig built-in test runner)
- **Automated tests**: TDD (RED-GREEN-REFACTOR)
- **Framework**: Zig built-in `std.testing`
- **Strategy**: Each fix includes unit tests; integration tests restored and run end-to-end

### QA Policy
Every task MUST include agent-executed QA scenarios. The executing agent will run verification after implementation.

- **Frontend/UI**: N/A (this is backend/service code)
- **TUI/CLI**: Use interactive_bash with `zig build`, `zig build test`
- **API**: Use Bash with `curl` for health checks, integration tests
- **Library/Module**: Use Zig test runner with specific test blocks

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Day 1 - Foundation: Critical compile fixes) - MAX PARALLEL (9 tasks):
├── Task 1: Fix nufast_physics skill toOwnedSlice (quick)
├── Task 2: Fix knowledge_base skill toOwnedSlice (quick)
├── Task 3: Fix semantic_search skill toOwnedSlice (quick)
├── Task 4: Fix local_llm skill toOwnedSlice (quick)
├── Task 5: Fix adhd_workflow skill toOwnedSlice (quick)
├── Task 6: Fix dirmacs_docs skill toOwnedSlice (quick)
├── Task 7: Fix planckeon_sites skill toOwnedSlice (quick)
├── Task 8: Fix discovery skill toOwnedSlice (quick)
└── Task 9: Fix memory_tree_search skill toOwnedSlice (quick)

Wave 2 (Day 1-2 - Build Verification):
├── Task 10: Run full build, fix any remaining compile errors (unspecified-high)
├── Task 11: Fix ConfigLoader errdefer bug (deep)
└── Task 12: Remove sensitive data from logs (quick)

Wave 3 (Day 2-3 - Runtime Safety):
├── Task 13: Add mutex to WhatsApp channel shared state (deep)
├── Task 14: Implement HTTP request timeouts in NIMClient (unspecified-high)
├── Task 15: Replace @intCast with safe conversions across 18 files (unspecified-high)
└── Task 16: Replace catch unreachable with proper errors (medium)

Wave 4 (Day 3-4 - Testing & Quality):
├── Task 17: Restore integration_test.zig with proper Config usage (deep)
├── Task 18: Re-enable integration tests in build.zig (quick)
├── Task 19: Add unit tests for ConfigLoader error paths (deep)
├── Task 20: Add thread safety stress tests for WhatsApp channel (deep)
└── Task 21: Implement skill instance per-execution (eliminate globals) (deep)

Wave 5 (Day 4-5 - Production Readiness):
├── Task 22: Add config validation at startup (quick)
├── Task 23: Implement StateStore.save() (unspecified-high)
├── Task 24: Standardize structured logging (medium)
├── Task 25: Add graceful shutdown (signal handling) (unspecified-high)
├── Task 26: Add health check endpoints (medium)
└── Task 27: Add metrics endpoint (Prometheus format) (medium)

Wave 6 (Day 5 - Cleanup & Documentation):
├── Task 28: Remove backup file migration_config.zig.bak (quick)
├── Task 29: Update README with migration status (quick)
├── Task 30: Add runbooks for deployment (writing)
└── Task 31: Final integration test run and verification (deep)

Wave FINAL (After ALL tasks - independent reviews, 4 parallel):
├── F1: Plan compliance audit (oracle)
├── F2: Thread safety review (unspecified-high)
├── F3: Security audit (sensitive data, auth) (unspecified-high)
└── F4: Performance benchmark (before/after) (deep)

Dependency Summary:
- Waves 1-2: Sequential (each depends on previous)
- Within waves: Tasks independent, run in parallel
- Wave 3 can start after Wave 2 completes
- Wave 4 depends on Wave 3 (thread safety fixes enable thread safety tests)
- Wave 5 depends on Wave 4 (features can be added after core is stable)
- Wave 6 depends on Wave 5
- FINAL wave depends on all previous waves

Parallel Speedup: ~70% faster than sequential
Max Concurrent: 9 (Wave 1) + 4 (FINAL) = 13 agents

```

---

## TODOs

> Implementation + Test = ONE Task. Never separate.
> EVERY task MUST have: Recommended Agent Profile + Parallelization info + QA Scenarios.
> **A task WITHOUT QA Scenarios is INCOMPLETE. No exceptions.**

- [x] 1. Fix nufast_physics skill toOwnedSlice() API

  **What to do**:
  - Change all 5 occurrences of `response.toOwnedSlice()` to `response.toOwnedSlice(ctx.allocator)`
  - Lines affected: 74, 93, 119, 140, 167 in `src/skills/nufast_physics/skill.zig`
  - Verify pattern: `var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable; defer response.deinit();` then `return SkillResult{ .message = response.toOwnedSlice() }`
  - Ensure `ctx.allocator` is the correct allocator (ExecutionContext stores allocator)

  **Must NOT do**:
  - Remove `defer response.deinit()` - it's safe even after toOwnedSlice (becomes no-op) and handles error paths
  - Change any other logic - minimal diff only
  - Introduce new allocations or restructuring

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `zig`
  - **Reason**: Simple find/replace across 5 lines; no complex logic, straightforward API fix
  - **Skills Evaluated but Omitted**: `visual-engineering` (no UI), `ultrabrain` (not complex), `artistry` (conventional fix)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with all other skill fixes in Wave 1)
  - **Parallel Group**: Wave 1 (Tasks 1-9)
  - **Blocks**: None (can start immediately)
  - **Blocked By**: None

  **References** (CRITICAL - provide exact context for executor):

  **Pattern References** (what to mimic):
  - `src/providers/health_tracker.zig:218` - Correct usage: `return available.toOwnedSlice(self.allocator);`
  - `src/channels/whatsapp/inbound.zig:172` - Correct usage: `return buffer.toOwnedSlice(allocator);`
  - `src/config/migration_config.zig:480` - Correct usage: `try whatsapp_allow_from.toOwnedSlice(self.allocator)`

  **API Reference**:
  - Zig 0.15.2 stdlib: `std.ArrayList.toOwnedSlice(allocator: Allocator) []u8` - mandatory allocator parameter for managed lists

  **WHY Each Reference Matters**:
  - `health_tracker.zig:218` shows correct pattern with `self.allocator` - demonstrates passing allocator explicitly
  - `inbound.zig:172` shows using local `allocator` variable - same pattern
  - `migration_config.zig:480` shows try-required version - but in our skill, we use `return` without try (since we're inside `catch unreachable` block? Actually handleBuild returns `!SkillResult`, so we can just `return SkillResult{ .message = response.toOwnedSlice(ctx.allocator) }` - no need for try because success always; but if we want to propagate OOM, we could use `try response.toOwnedSlice(ctx.allocator)`. However, since we have `defer response.deinit()`, toOwnedSlice should always succeed if capacity was enough? Actually toOwnedSlice can fail if allocator fails to shrink? No, it transfers ownership, doesn't allocate. It should not fail. So just `response.toOwnedSlice(ctx.allocator)` is fine.

  **Acceptance Criteria**:
  - [ ] All 5 toOwnedSlice calls updated to include `ctx.allocator` argument
  - [ ] `zig build` succeeds without errors about toOwnedSlice signature
  - [ ] No new warnings introduced

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify skill compiles after fix
    Tool: Bash
    Preconditions: Zig 0.15.2 installed, in project root
    Steps:
      1. Run: zig build
    Expected Result: Build exits with code 0, no errors like "expected argument 'allocator'"
    Failure Indicators: Compilation error referencing toOwnedSlice
    Evidence: .sisyphus/evidence/task-1-build.txt (full build output)

  Scenario: Verify skill registered and loads without panic
    Tool: Bash
    Preconditions: Build successful
    Steps:
      1. Run: ./zig-out/bin/zeptoclaw --list-skills 2>&1 | grep nufast-physics
    Expected Result: Skill name appears in list; exit code 0
    Failure Indicators: Panic on startup, skill not listed
    Evidence: .sisyphus/evidence/task-1-skill-list.txt
  ```

  **Evidence to Capture**:
  - [ ] task-1-build.txt (build output)
  - [ ] task-1-skill-list.txt (skill listing output)

  **Commit**: YES (grouped with Tasks 1-9 in Wave 1)
  - Message: `fix(skills): migrate ArrayList.toOwnedSlice() to Zig 0.15.2 API (9 skills)`
  - Files: `src/skills/nufast_physics/skill.zig`
  - Pre-commit test: `zig build`

- [x] 2. Fix knowledge_base skill toOwnedSlice() API

  **What to do**:
  - Change all 4 occurrences of `response.toOwnedSlice()` to `response.toOwnedSlice(ctx.allocator)`
  - Lines: 239, 333, 425, 447 in `src/skills/knowledge_base/skill.zig`
  - Functions affected: `handleIndex`, `handleSearch`, `handleQuery`, `handleList`

  **Must NOT do**:
  - Modify any other logic or error handling
  - Remove defer patterns

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `zig`
  - **Reason**: Same pattern as Task 1; straightforward replace
  - **Skills Evaluated but Omitted**: None

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 1)
  - **Blocks**: None

  **References**:
  - Same as Task 1: `src/providers/health_tracker.zig:218`, `src/channels/whatsapp/inbound.zig:172`
  - This file: `src/skills/knowledge_base/skill.zig:239` (first occurrence)

  **Acceptance Criteria**:
  - [ ] All 4 calls updated with allocator argument
  - [ ] `zig build` passes

  **QA Scenarios**:
  ```
  Scenario: Build success and skill loads
    Tool: Bash
    Steps:
      1. zig build
      2. ./zig-out/bin/zeptoclaw --list-skills | grep knowledge-base
    Expected: Build exit 0, skill listed
  ```

  **Evidence**:
  - .sisyphus/evidence/task-2-build.txt
  - .sisyphus/evidence/task-2-skill-list.txt

  **Commit**: YES (grouped with Tasks 1-9)
  - `fix(skills): migrate ArrayList.toOwnedSlice() to Zig 0.15.2 API`
  - Files: `src/skills/knowledge_base/skill.zig`

- [x] 3. Fix semantic_search skill toOwnedSlice() API

  **What to do**:
  - Fix 4 occurrences at lines 84, 117, 138, 165 in `src/skills/semantic_search/skill.zig`
  - Change `response.toOwnedSlice()` to `response.toOwnedSlice(ctx.allocator)`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

- [x] 4. Fix local_llm skill toOwnedSlice() API

  **What to do**:
  - Fix 4 occurrences at lines 88, 222, 280, 305 in `src/skills/local_llm/skill.zig`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

---

---
- [x] 5. Fix adhd_workflow skill toOwnedSlice() API

  **What to do**:
  - Fix 4 occurrences at lines 127, 160, 194, 217 in `src/skills/adhd_workflow/skill.zig`
  - Change `response.toOwnedSlice()` to `response.toOwnedSlice(ctx.allocator)`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1 (use pattern from `src/providers/health_tracker.zig:218`)
  **QA Scenarios**: Build + skill list (`grep adhd-workflow`)
  **Evidence**: .sisyphus/evidence/task-5-build.txt, task-5-skill-list.txt
  **Commit**: YES (grouped 1-9) - `fix(skills): migrate ArrayList.toOwnedSlice() to Zig 0.15.2 API`

- [x] 6. Fix dirmacs_docs skill toOwnedSlice() API

  **What to do**:
  - Fix 4 occurrences at lines 248, 357, 428, 450 in `src/skills/dirmacs_docs/skill.zig`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

- [x] 7. Fix planckeon_sites skill toOwnedSlice() API

  **What to do**:
  - Fix 5 occurrences at lines 73, 94, 116, 138, 166 in `src/skills/planckeon_sites/skill.zig`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

- [x] 8. Fix discovery skill toOwnedSlice() API

  **What to do**:
  - Fix 4 occurrences at lines 357, 407, 591, 610 in `src/skills/discovery/skill.zig`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

- [x] 9. Fix memory_tree_search skill toOwnedSlice() API

  **What to do**:
  - Fix 5 occurrences at lines 73, 122, 154, 184, 207 in `src/skills/memory_tree_search/skill.zig`

  **Parallelization**: YES (Wave 1)
  **References**: As Task 1
  **QA**: Build + skill list
  **Commit**: YES (grouped 1-9)

---

- [x] 10. Run full build, fix any remaining compile errors

  **What to do**:
  - Execute `zig build` and capture all compilation errors
  - Identify any remaining Zig 0.15.2 API issues beyond toOwnedSlice (e.g., parseFromSlice, getEnvVarOwned, deinit ordering)
  - Fix errors iteratively, verifying each fix with a rebuild
  - Ensure no warnings remain (treat warnings as errors via `-Drelease-safe` or similar)
  - Confirm build artifact creation (binaries in zig-out/bin/)

  **Must NOT do**:
  - Ignore warnings or suppress them via compiler flags
  - Skip fixing non-skill modules (providers, channels, services) - all must compile
  - Modify build.zig to exclude failing modules (no scope reduction)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `lsp_rename`, `ast_grep_search`]
  - **Reason**: Requires diagnostic analysis, iterative fixes across multiple modules; not simple find/replace
  - **Skills Evaluated but Omitted**: `quick` (too complex), `deep` (need faster iteration)

  **Parallelization**:
  - **Can Run In Parallel**: NO (Wave 2 depends on Wave 1 completion; sequential within wave)
  - **Parallel Group**: Wave 2 (Tasks 10-12)
  - **Blocks**: Task 11, Task 12 (wait for build to stabilize)
  - **Blocked By**: Tasks 1-9 (all skill fixes must complete first)

  **References**:
  - Build command: `zig build` (from build.zig)
  - Error patterns from background analysis: `src/providers/nim.zig: parseFromSlice usage`, `src/channels/whatsapp/*: getEnvVarOwned`
  - Zig 0.15.2 release notes for API changes

  **WHY Each Reference Matters**:
  - Build.zig defines targets and dependencies; understanding helps diagnose if errors are in linking vs compilation
  - Background analysis identified common migration pain points; prioritize these if seen

  **Acceptance Criteria**:
  - [ ] `zig build` exits with code 0
  - [ ] All 4 binaries produced (zeptoclaw, zeptoclaw-gateway, zeptoclaw-webhook, zeptoclaw-shell2http)
  - [ ] Zero compilation errors or warnings
  - [ ] No remaining toOwnedSlice, parseFromSlice, or getEnvVarOwned errors

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Full build succeeds and produces all binaries
    Tool: Bash
    Preconditions: Zig 0.15.2, all Wave 1 tasks completed
    Steps:
      1. cd /home/user/zeptoclaw
      2. zig build
    Expected Result: Exit code 0; binaries exist in zig-out/bin/
    Failure Indicators: Any compilation error, missing binary
    Evidence: .sisyphus/evidence/task-10-build.log

  Scenario: Verify no remaining toOwnedSlice errors
    Tool: Bash
    Steps:
      1. zig build 2>&1 | grep -i 'toOwnedSlice'
    Expected Result: No output (grep finds nothing)
    Evidence: .sisyphus/evidence/task-10-toOwnedSlice-check.txt
  ```

  **Evidence to Capture**:
  - [ ] task-10-build.log (full build output)
  - [ ] task-10-toOwnedSlice-check.txt (empty or confirming no matches)
  - [ ] task-10-binaries.txt (list of binaries: `ls -l zig-out/bin/`)

  **Commit**: YES
  - Message: `build: ensure compilation with Zig 0.15.2`
  - Files: All files modified during fix iterations (track via git)
  - Pre-commit: `zig build`

- [x] 11. Fix ConfigLoader errdefer bug

  **What to do**:
  - Locate the bug in `src/config/config_loader.zig` (or similar) where `errdefer` incorrectly calls `fc.deinit()` on a pointer or optional
  - Background analysis indicated: `if (file_config) |*fc| fc.deinit();` is incorrect - should properly deinit only if config was loaded and initialized
  - Fix the logic to ensure Config's allocated fields are properly freed on error without double-free or accessing null
  - Add unit tests covering error paths during config loading (file not found, invalid JSON, allocation failures)

  **Must NOT do**:
  - Remove error handling altogether
  - Introduce memory leaks by omitting deinit on error paths
  - Change Config struct layout without updating all consumers

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `lsp_find_references`, `ast_grep_search`]
  - **Reason**: Requires understanding of ownership, error paths, and testing; subtle bug
  - **Skills Evaluated but Omitted**: `quick` (not trivial), `unspecified-high` (need thorough analysis)

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 10; Task 12 can run in parallel with this)
  - **Blocks**: Task 12 (can proceed independently once Task 10 done)
  - **Blocked By**: Task 10 (must have build compiling first)

  **References**:
  - `src/config/config_loader.zig` - the bug location
  - `src/config/config.zig` - Config struct definition and deinit method
  - `src/config/error.zig` - error types
  - Background analysis: "ConfigLoader errdefer bug: `if (file_config) |*fc| fc.deinit();` incorrect"

  **WHY Each Reference Matters**:
  - ConfigLoader: Contains the faulty errdefer - must understand control flow
  - Config struct: Has deinit() that frees allocated fields (e.g., fallback_models ArrayList)
  - Error types: Helps design comprehensive tests for all failure modes

  **Acceptance Criteria**:
  - [ ] errdefer logic corrected - no double-free, no use-after-free
  - [ ] Config.deinit() correctly frees all owned memory (validate with `-fsanitize=address` if available)
  - [ ] Unit tests added for at least 3 error scenarios (file error, parse error, alloc error)
  - [ ] All tests pass (`zig build test`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Config loads successfully
    Tool: Bash (zig test)
    Preconditions: Valid config file present
    Steps:
      1. zig test src/config/config_loader_test.zig
    Expected: Test passes, config loaded, no leaks
    Evidence: .sisyphus/evidence/task-11-test-success.txt

  Scenario: Config error handling - invalid JSON
    Tool: Bash
    Steps:
      1. Create invalid config file
      2. Run loader; expect error
    Expected: Proper error message, no crash, no leak
    Evidence: .sisyphus/evidence/task-11-invalid-json.txt
  ```

  **Evidence to Capture**:
  - [ ] task-11-test-success.txt (test output)
  - [ ] task-11-invalid-json.txt (error handling run)
  - [ ] task-11-code-diff.txt (git diff showing fix)

  **Commit**: YES
  - Message: `fix(config): correct errdefer in mergeConfigs`
  - Files: `src/config/config_loader.zig`, `src/config/config.zig` (if deinit changes)
  - Pre-commit: `zig build test`

- [x] 12. Remove sensitive data from logs

  **What to do**:
  - Scan codebase for any logging of sensitive data (API keys, tokens, passwords, JWT, auth headers)
  - Pay special attention to `gateway_server.zig`, `webhook_server.zig`, ` nim.zig` (NIMClient request/response logging)
  - Replace sensitive values with placeholders like `[REDACTED]` or `***`
  - Ensure error messages do not leak full request bodies containing credentials
  - Verify structured logging fields (JSON logs) don't include sensitive keys

  **Must NOT do**:
  - Remove all logging (only redact sensitive parts)
  - Change log levels to suppress info (use proper filtering)
  - Break existing log parsing/monitoring (keep field names, just redact values)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `ast_grep_search`, `grep`]
  - **Reason**: Requires searching for patterns across codebase, understanding context of each log statement
  - **Skills Evaluated but Omitted**: `deep` (more exploration than deep analysis), `quick` (too many files)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 11, since both depend only on Task 10)
  - **Parallel Group**: Wave 2 (Tasks 10-12)
  - **Blocks**: None
  - **Blocked By**: Task 10 (build must compile to run tests)

  **References**:
  - Search patterns: `std.log.*info|err|debug`, `console.log`, `print`, `fmt.*print`
  - Files to check: `src/services/gateway_server.zig`, `src/services/webhook_server.zig`, `src/providers/nim.zig`, `src/channels/whatsapp/*`
  - OWASP log grooming guidelines

  **WHY Each Reference Matters**:
  - Gateway/webhook: Entry points that may log request headers containing auth tokens
  - NIMClient: Logs API calls that may include API keys in headers or body
  - WhatsApp: May log incoming messages with personal data

  **Acceptance Criteria**:
  - [ ] No log output contains patterns like `nvapi-`, `Bearer`, `API Key`, `password`, `token`
  - [ ] Existing log structure preserved (same fields, same levels)
  - [ ] Tests still pass (no breaking changes to log consumers)
  - [ ] Security scan (manual grep) passes: `grep -r 'nvapi' src/ | wc -l == 0` etc.

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify no API keys in logs during normal operation
    Tool: Bash
    Preconditions: Set NVIDIA_API_KEY in env, run gateway
    Steps:
      1. Start zeptoclaw-gateway in background
      2. Trigger an API call (e.g., via curl to /v1/chat/completions)
      3. Capture logs: `journalctl` or stdout file
      4. grep for 'nvapi' or the actual key prefix
    Expected: No sensitive data in logs
    Evidence: .sisyphus/evidence/task-12-logs-scan.txt

  Scenario: Error path does not leak request body
    Tool: Bash
    Steps:
      1. Send malformed request to gateway
      2. Check logs for full request body echo
    Expected: Error logged but body redacted
    Evidence: .sisyphus/evidence/task-12-error-log.txt
  ```

  **Evidence to Capture**:
  - [ ] task-12-logs-scan.txt (grep results showing no sensitive data)
  - [ ] task-12-error-log.txt (sample error log showing redaction)
  - [ ] task-12-modified-files.txt (list of files changed)

  **Commit**: YES
  - Message: `chore(logging): remove sensitive auth tokens from startup logs`
  - Files: All files with logging redactions
  - Pre-commit: `zig build`

|---
- [x] 13. Add mutex to WhatsApp channel shared state

  **What to do**:
  - Identify shared mutable state in `src/channels/whatsapp/whatsapp_channel.zig`: `connected`, `self_jid`, `self_e164`
  - These are accessed from both main thread and reader thread without synchronization
  - Add `std.Thread.Mutex` to protect each shared field
  - Wrap all reads/writes with `mutex.lock()` / `defer mutex.unlock()`
  - Initialize mutex in channel init, deinit in channel deinit
  - Consider using atomic booleans for `connected` if performance critical

  **Must NOT do**:
  - Use `@atomicStore`/`@atomicLoad` without proper memory ordering (use mutex for simplicity)
  - Remove any existing synchronization (double-check there isn't any already)
  - Change the channel's public API

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `lsp_find_references`, `ast_grep_search`]
  - **Reason**: Requires careful analysis of thread interactions, lock placement, and potential deadlocks
  - **Skills Evaluated but Omitted**: `quick` (not trivial), `unspecified-high` (need deep understanding of concurrency)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 14-16 in Wave 3, after Wave 2 completes)
  - **Parallel Group**: Wave 3 (Tasks 13-16)
  - **Blocks**: None within wave
  - **Blocked By**: Task 10-12 (build must be stable)

  **References**:
  - `src/channels/whatsapp/whatsapp_channel.zig:325-400` - reader thread loop accessing shared state
  - `src/channels/whatsapp/whatsapp_channel.zig:150-200` - main thread methods that modify state
  - Zig stdlib: `std.Thread.Mutex`
  - Background analysis: "WhatsApp channel has thread safety data races"

  **WHY Each Reference Matters**:
  - WhatsApp channel: The concurrency hotspot - reader thread runs in background, main thread sends/receives
  - Mutex: Standard Zig synchronization primitive; need to use correctly to avoid deadlocks

  **Acceptance Criteria**:
  - [ ] All accesses to `connected`, `self_jid`, `self_e164` protected by mutex
  - [ ] No data races detected by running stress test (concurrent reads/writes)
  - [ ] No deadlocks (program continues to respond under load)
  - [ ] Build and tests pass (`zig build test`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify WhatsApp channel initializes and connects
    Tool: Bash
    Steps:
      1. zig test src/channels/whatsapp/whatsapp_channel_test.zig - "test init and connect"
    Expected: Test passes, channel connects
    Evidence: .sisyphus/evidence/task-13-connect-test.txt

  Scenario: Stress test with concurrent operations
    Tool: custom Zig stress test or manual
    Steps:
      1. Run zeptoclaw with WhatsApp channel enabled
      2. Simulate multiple concurrent inbound messages (via test hook or real)
      3. Check for crashes or corrupted state
    Expected: No crashes, state remains consistent
    Evidence: .sisyphus/evidence/task-13-stress.log
  ```

  **Evidence to Capture**:
  - [ ] task-13-connect-test.txt
  - [ ] task-13-stress.log
  - [ ] task-13-code-diff.txt (git diff showing mutex additions)

  **Commit**: YES
  - Message: `fix(whatsapp): add mutex protection for shared state`
  - Files: `src/channels/whatsapp/whatsapp_channel.zig`
  - Pre-commit: `zig build test`


- [x] 14. Implement HTTP request timeouts in NIMClient

  **What to do**:
  - Add timeout configuration to NIMClient (e.g., `timeout_ms: u32 = 30000` default 30s)
  - Modify HTTP request logic in `src/providers/nim.zig` to set a deadline using `std.time.Timer` or HTTP client timeout option
  - For each request: start timer, if elapsed before response returns, cancel request and return `error.Timeout`
  - Ensure timeouts are configurable per-request or globally via config
  - Add tests that simulate slow responses (use mock server) and verify timeout triggers

  **Must NOT do**:
  - Add timeout to the point where it interrupts request body streaming improperly (respect HTTP semantics)
  - Make timeout non-configurable (must allow adjustment for slow networks)
  - Change existing API (NIMClient interface) in a breaking way

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `http`, `testing`]
  - **Reason**: Requires understanding of async I/O, timer APIs, and proper cleanup on timeout
  - **Skills Evaluated but Omitted**: `quick` (multiple moving parts), `deep` (need practical implementation)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 13, 15, 16 in Wave 3)
  - **Blocks**: None (independent of other Wave 3 tasks)
  - **Blocked By**: Wave 2 completion

  **References**:
  - `src/providers/nim.zig` - NIMClient implementation and request method
  - `src/providers/types.zig` - Provider interface
  - Zig stdlib: `std.time.Timer`, `std.net.Stream` (or whichever HTTP client is used)
  - Background analysis: "HTTP requests in NIMClient lack timeouts → potential hangs"

  **WHY Each Reference Matters**:
  - NIMClient: Central API client; timeout here prevents entire agent from hanging
  - Timer: Mechanism to enforce deadline; must be used correctly to cancel ongoing I/O

  **Acceptance Criteria**:
  - [ ] Timeout configurable (default 30s)
  - [ ] Requests exceeding timeout return `error.Timeout` cleanly
  - [ ] Resources cleaned up on timeout (no leaks)
  - [ ] Integration test with slow mock server confirms timeout behavior

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Normal request completes within timeout
    Tool: Bash + curl / test
    Steps:
      1. Run provider request to real NIM (or mock with fast response)
    Expected: Success, within timeout
    Evidence: .sisyphus/evidence/task-14-fast-success.txt

  Scenario: Slow server triggers timeout
    Tool: Zig test with mock HTTP server that delays response
    Steps:
      1. Start mock server that sleeps 35s before responding
      2. Configure NIMClient timeout 30s
      3. Make request
    Expected: Request aborted with error.Timeout after ~30s
    Evidence: .sisyphus/evidence/task-14-timeout.log
  ```

  **Evidence to Capture**:
  - [ ] task-14-fast-success.txt
  - [ ] task-14-timeout.log
  - [ ] task-14-config-diff.txt (shows new config field)

  **Commit**: YES
  - Message: `feat(nim): add configurable request timeout`
  - Files: `src/providers/nim.zig`, possibly config files
  - Pre-commit: `zig build test`


- [x] 15. Replace @intCast with safe conversions across 18 files

  **What to do**:
  - Find all occurrences of `@intCast` (31 found) across codebase using `rg '@intCast' src/`
  - Replace with safer alternatives: `@intCast` → `@intFromFloat` (if from float), `@intCast` → `@intFromEnum`/`@enumFromInt` (if enums), or explicit `if` check with `error.Overflow`
  - For narrowing conversions (i64 -> i32, usize -> i32, etc.), check range before casting or use `std.math.lossyCast` with validation
  - Add tests for boundary values (max i64 to i32, negative values, etc.)
  - Pay attention to file: `src/providers/nim.zig`, `src/channels/whatsapp/*`, `src/autonomous/*` (as per background scan)

  **Must NOT do**:
  - Blindly replace with `@intCast` again (must use safe conversion)
  - Remove conversions entirely (need to preserve semantics with type safety)
  - Change public function signatures (breaking API) - adjust implementation only

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `ast_grep_search`, `lsp_find_references`]
  - **Reason**: Many occurrences across files; need semantic analysis to choose correct safe alternative; risk of subtle bugs
  - **Skills Evaluated but Omitted**: `quick` (too many, need analysis), `deep` (but need batch processing)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 13, 14, 16)
  - **Blocks**: None (independent fixes across different files)
  - **Blocked By**: Wave 2 completion

  **References**:
  - Background analysis: 31 `@intCast` occurrences across 18 files (list provided in analysis output)
  - Zig docs: `@intFromFloat`, `@intFromEnum`, `@enumFromInt`, `std.math.lossyCast`, `std.math.add`, `std.math.sub`
  - Existing safe patterns in codebase: search for `std.math` usage

  **WHY Each Reference Matters**:
  - Background analysis: Provides the hit list of files and line numbers - starting point
  - Zig conversion builtins: Each has specific use case; choosing wrong can cause overflow or underflow

  **Acceptance Criteria**:
  - [ ] All 31 `@intCast` replaced with safe alternatives
  - [ ] No new `@intCast` introduced elsewhere
  - [ ] Build and tests pass (`zig build test`)
  - [ ] No runtime panics from overflow in affected code paths

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify no @intCast remains
    Tool: Bash
    Steps:
      1. rg '@intCast' src/
    Expected: No output
    Evidence: .sisyphus/evidence/task-15-no-intcast.txt

  Scenario: Test numeric edge cases
    Tool: Bash
    Steps:
      1. zig test affected_files.zig (run tests that cover conversions)
    Expected: All tests pass, no overflow errors
    Evidence: .sisyphus/evidence/task-15-tests.txt
  ```

  **Evidence to Capture**:
  - [ ] task-15-no-intcast.txt (grep output empty)
  - [ ] task-15-tests.txt (test output)
  - [ ] task-15-modified-files.txt (list of files changed)

  **Commit**: YES (multiple commits grouped, or one per file if large)
  - Message: `fix(safety): replace @intCast with validated conversions`
  - Files: All files with `@intCast` replacements
  - Pre-commit: `zig build test`


- [x] 16. Replace catch unreachable with proper errors

  **What to do**:
  - Find all `catch unreachable` patterns (e.g., `foo() catch unreachable;`)
  - Replace with proper error handling: `catch |err| return err;` or `catch handleError(err)`
  - For truly unreachable cases (where error is impossible), add comment explaining why and keep unreachable, but these should be rare
  - Update function return types to include error union if they currently discard errors
  - Ensure callers propagate errors properly

  **Must NOT do**:
  - Remove all unreachable (some are valid, e.g., after `std.mem.eql` which never fails)
  - Change error type arbitrarily (maintain existing error sets)
  - Break error handling contracts (propagate correctly)

  **Recommended Agent Profile**:
  - **Category**: `medium`
  - **Skills**: [`zig`, `ast_grep_search`]
  - **Reason**: Straightforward pattern replacement but requires judgment about which catches are legitimate
  - **Skills Evaluated but Omitted**: `quick` (need careful review), `deep` (not deeply complex)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 3)
  - **Blocks**: None
  - **Blocked By**: Wave 2

  **References**:
  - Background analysis: `catch unreachable` occurrences across codebase
  - Zig error handling best practices: always propagate unless truly unreachable
  - Example proper pattern: `try foo() catch |err| return err;` or `foo() catch |err| return error.FooFailed;`

  **WHY Each Reference Matters**:
  - Background analysis: Provides locations
  - Best practices: Ensure we don't introduce bugs by over-correcting

  **Acceptance Criteria**:
  - [ ] All `catch unreachable` replaced except those with justifying comments
  - [ ] Functions that previously discarded errors now propagate them
  - [ ] Build and tests pass
  - [ ] No new `unreachable` statements introduced in catch blocks

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify unreachable pattern removed
    Tool: Bash
    Steps:
      1. rg 'catch unreachable' src/
    Expected: Only remaining ones have comment '# legit' or similar justification
    Evidence: .sisyphus/evidence/task-16-catch-check.txt

  Scenario: Error propagation test
    Tool: Bash
    Steps:
      1. zig build test
    Expected: Tests pass, errors propagate correctly
    Evidence: .sisyphus/evidence/task-16-test.txt
  ```

  **Evidence to Capture**:
  - [ ] task-16-catch-check.txt
  - [ ] task-16-test.txt
  - [ ] task-16-modified-files.txt

  **Commit**: YES
  - Message: `fix(handling): replace catch unreachable with proper errors`
  - Files: All files where pattern replaced
  - Pre-commit: `zig build test`


|---

- [x] 17. Restore integration_test.zig with proper Config usage

  **What to do**:
  - Locate or create `tests/integration_test.zig` (currently missing or mismatched)
  - Update imports to use the new Config struct (after migration changes)
  - Write integration tests that cover end-to-end scenarios: agent startup, skill execution, provider calls (maybe mock NIM)
  - If real NIM integration tests exist, ensure they use environment variable for API key and skip if not set
  - Add test fixtures for various config combinations

  **Must NOT do**:
  - Hardcode test values that differ from real config (use realistic config)
  - Remove assertions to make tests pass
  - Introduce external dependencies without skip mechanism

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `testing`]
  - **Reason**: Integration tests require orchestrating multiple components; need to set up realistic environment
  - **Skills Evaluated but Omitted**: `quick` (complex setup), `unspecified-high` (need deep understanding of integration points)

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 18-21 in Wave 4, after Wave 3 completes)
  - **Blocks**: None
  - **Blocked By**: Wave 3 (thread safety and runtime fixes should be stable first)

  **References**:
  - Existing test structure: `tests/` directory, `src/**/*_test.zig`
  - Config usage in production code: `src/main.zig`, `src/root.zig`
  - Integration test examples from Zig standard library or other projects

  **WHY Each Reference Matters**:
  - Test directory: Follow existing patterns for organizing integration tests
  - Config usage: Integration tests need to construct Config correctly to avoid mismatches

  **Acceptance Criteria**:
  - [ ] integration_test.zig compiles and runs
  - [ ] Tests cover at least 3 end-to-end scenarios (startup, skill execution, provider call)
  - [ ] Tests skip gracefully if NVIDIA_API_KEY not set
  - [ ] All tests pass (`zig build test`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Run integration tests with mock provider
    Tool: Bash
    Steps:
      1. Set MOCK_PROVIDER=1 (or use test double)
      2. zig test tests/integration_test.zig
    Expected: Tests execute without real NIM, verify flow
    Evidence: .sisyphus/evidence/task-17-integration-mock.txt

  Scenario: Integration tests with real NIM (if key available)
    Tool: Bash
    Steps:
      1. export NVIDIA_API_KEY=...
      2. zig test tests/integration_test.zig
    Expected: Tests pass with real API calls
    Evidence: .sisyphus/evidence/task-17-integration-real.txt
  ```

  **Evidence to Capture**:
  - [ ] task-17-integration-mock.txt
  - [ ] task-17-integration-real.txt (if applicable)
  - [ ] task-17-test-source.txt (the test file content)

  **Commit**: YES
  - Message: `test: restore integration_test.zig with proper Config`
  - Files: `tests/integration_test.zig`
  - Pre-commit: `zig build test`


- [x] 18. Re-enable integration tests in build.zig

  **What to do**:
  - Open `build.zig`
  - Find the test step (typically `b.test` or similar)
  - Ensure `tests/integration_test.zig` is included in the test step (add if missing)
  - If tests were conditionally excluded based on a flag, remove the exclusion or set the flag appropriately
  - Verify `zig build test` runs the integration tests (alongside unit tests)

  **Must NOT do**:
  - Comment out integration tests again
  - Add integration tests to release builds (they should only run in test step)
  - Modify test runner options that break existing unit tests

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: [`zig`]
  - **Reason**: Simple configuration change in build.zig; no code logic
  - **Skills Evaluated but Omitted**: none

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 4; independent of other tasks once Task 17 done)
  - **Blocks**: None
  - **Blocked By**: Task 17 (test must exist to be enabled)

  **References**:
  - `build.zig` - the build script
  - Zig build system documentation: `b.test` step and `addTest`

  **WHY Each Reference Matters**:
  - build.zig: Central place controlling which tests run; needs correct inclusion

  **Acceptance Criteria**:
  - [ ] `zig build test` executes integration_test.zig
  - [ ] Build output shows integration tests being compiled and run
  - [ ] No errors from build system about missing test file

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify integration tests are part of build test
    Tool: Bash
    Steps:
      1. zig build test -v
    Expected: Output lists integration_test.zig among test files
    Evidence: .sisyphus/evidence/task-18-build-test-verbose.txt
  ```

  **Evidence to Capture**:
  - [ ] task-18-build-test-verbose.txt
  - [ ] task-18-build-diff.txt (git diff of build.zig)

  **Commit**: YES
  - Message: `test: enable integration tests in build.zig`
  - Files: `build.zig`
  - Pre-commit: `zig build test`


- [x] 19. Add unit tests for ConfigLoader error paths

  **What to do**:
  - In `src/config/config_loader_test.zig` (or create if missing)
  - Add test cases for:
    - File not found error
    - Invalid JSON syntax
    - Schema validation failures (missing required fields)
    - Allocation failure (simulate with `std.testing.failAlloc` if needed)
  - Use `std.testing` expectError assertions
  - Ensure each test constructs a ConfigLoader and calls appropriate method (e.g., `loadFromFile`)
  - Verify error messages are helpful

  **Must NOT do**:
  - Skip testing rare error paths (like OOM)
  - Change error types without updating tests

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `testing`]
  - **Reason**: Need to design comprehensive error tests; must understand all failure modes
  - **Skills Evaluated but Omitted**: `quick` (requires careful design)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 4)
  - **Blocks**: None
  - **Blocked By**: Wave 3 (but can start earlier; depends on ConfigLoader working)

  **References**:
  - `src/config/config_loader.zig` - implementation to test
  - `src/config/error.zig` - error set
  - `src/config/config.zig` - Config struct
  - Existing unit tests in `src/config/` if any

  **WHY Each Reference Matters**:
  - config_loader: The SUT (system under test)
  - error set: Must match expected errors
  - Config: Need valid config for positive tests

  **Acceptance Criteria**:
  - [ ] At least 5 new unit tests covering error conditions
  - [ ] All unit tests for ConfigLoader pass
  - [ ] Code coverage for ConfigLoader >= 90%
  - [ ] `zig build test` passes

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Run ConfigLoader unit tests
    Tool: Bash
    Steps:
      1. zig test src/config/config_loader_test.zig
    Expected: All tests pass, including new error tests
    Evidence: .sisyphus/evidence/task-19-config-loader-tests.txt
  ```

  **Evidence to Capture**:
  - [ ] task-19-config-loader-tests.txt
  - [ ] task-19-test-coverage.txt (coverage report if available)
  - [ ] task-19-test-source.txt (new test code)

  **Commit**: YES
  - Message: `test: add unit tests for ConfigLoader error paths`
  - Files: `src/config/config_loader_test.zig`
  - Pre-commit: `zig build test`


- [x] 20. Add thread safety stress tests for WhatsApp channel

  **What to do**:
  - In `src/channels/whatsapp/whatsapp_channel_test.zig` or create new stress test
  - Write a test that spawns multiple threads simulating concurrent inbound message processing
  - Each thread repeatedly sends fake WhatsApp messages to the channel's inbound handler
  - Run for a duration (e.g., 5 seconds) with many concurrent threads (e.g., 10 threads)
  - Verify no crashes, no data corruption, and proper mutex behavior (no deadlocks)
  - Optionally add race detection using `-Dthread-sanitizer` if Zig supports it

  **Must NOT do**:
  - Use unrealistic message patterns that don't match production
  - Introduce artificial sleeps that mask real race conditions
  - Disable the test on CI due to flakiness (fix flakiness instead)

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `testing`, `concurrency`]
  - **Reason**: Stress tests are tricky to write correctly; need to simulate realistic concurrency and detect subtle bugs
  - **Skills Evaluated but Omitted**: `quick` (complex), `unspecified-high` (need deep testing skills)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 4)
  - **Blocks**: None
  - **Blocked By**: Task 13 (thread safety must be implemented before testing)

  **References**:
  - `src/channels/whatsapp/whatsapp_channel.zig` - the mutex-protected state
  - Zig testing docs for `std.Thread` spawn and join
  - Example stress tests in Zig stdlib or other projects

  **WHY Each Reference Matters**:
  - WhatsApp channel: We need to stress-test the exact mutex-protected fields
  - Thread API: Correct usage needed to spawn many concurrent workers

  **Acceptance Criteria**:
  - [ ] Stress test compiles and runs
  - [ ] Test completes without deadlock or crash
  - [ ] Test catches intentional bug (e.g., temporarily remove mutex to verify it detects race) - optional but valuable
  - [ ] `zig build test` passes including this stress test

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Run stress test and verify no crashes
    Tool: Bash
    Steps:
      1. zig test src/channels/whatsapp/whatsapp_channel_test.zig - "test stress concurrent"
    Expected: Test runs 5s, exits with 0
    Evidence: .sisyphus/evidence/task-20-stress-test.txt

  Scenario: Verify mutex prevents data race (intentional bug check)
    Tool: Manual: temporarily comment mutex, re-run stress
    Expected: With mutex removed, stress test may detect race or crash (demonstrates test effectiveness)
    Evidence: .sisyphus/evidence/task-20-bug-demo.txt (optional)
  ```

  **Evidence to Capture**:
  - [ ] task-20-stress-test.txt
  - [ ] task-20-bug-demo.txt (optional)
  - [ ] task-20-test-source.txt

  **Commit**: YES
  - Message: `test: add thread safety stress tests for WhatsApp channel`
  - Files: `src/channels/whatsapp/whatsapp_channel_test.zig`
  - Pre-commit: `zig build test`


- [ ] 21. Implement skill instance per-execution (eliminate globals)

  **What to do**:
  - Identify skills that use global `var config` or other module-level mutable state (from background analysis)
  - Refactor to create a new skill instance per execution instead of using globals
  - Store configuration in the skill's instance struct (already likely there) and ensure each execution gets its own instance
  - Update skill registration if it assumes singleton pattern
  - Verify thread safety: multiple skill executions should not share mutable state

  **Must NOT do**:
  - Remove state entirely (skills need config) - just make it per-instance
  - Change skill API (keep same interface)
  - Introduce new global state in different module

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `lsp_rename`, `ast_grep_search`]
  - **Reason**: Requires understanding of module-level state, lifetime, and careful refactoring to avoid breaking existing calls
  - **Skills Evaluated but Omitted**: `quick` (complex), `unspecified-high` (need deep analysis of globals)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 4; may touch multiple skill files but each is independent)
  - **Blocks**: None (but needs Thread Safety from Task 13 to ensure per-instance doesn't re-introduce globals)
  - **Blocked By**: Task 13 (ensure thread-safe design)

  **References**:
  - Background analysis: "Global mutable state in skills (`var config`) not thread-safe"
  - Skill SDK: `src/skills/skill_sdk.zig`, `src/skills/execution_context.zig` - how skills are instantiated
  - Example skill without globals: compare `src/skills/nufast_physics/skill.zig` (likely instance-based)

  **WHY Each Reference Matters**:
  - Background analysis: Identifies which skills have problematic globals
  - Skill SDK: Shows how skills should be created and used; we need to align with that pattern

  **Acceptance Criteria**:
  - [ ] No skill module uses `var` at top-level (outside of structs/functions)
  - [ ] Each skill execution creates fresh instance (verify via code inspection)
  - [ ] Thread safety preserved (no shared mutable state across executions)
  - [ ] All tests pass (`zig build test`)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify skill globals eliminated
    Tool: Bash
    Steps:
      1. rg 'var [a-zA-Z_]+' src/skills/*/skill.zig
    Expected: Only matches inside struct or function bodies (no top-level `var`)
    Evidence: .sisyphus/evidence/task-21-grep-globals.txt

  Scenario: Skill execution still works correctly
    Tool: Bash
    Steps:
      1. ./zig-out/bin/zeptoclaw --list-skills
      2. Run a skill via agent command
    Expected: Skills execute normally, no regressions
    Evidence: .sisyphus/evidence/task-21-skill-execution.txt
  ```

  **Evidence to Capture**:
  - [ ] task-21-grep-globals.txt
  - [ ] task-21-skill-execution.txt (output showing skill works)
  - [ ] task-21-modified-files.txt

  **Commit**: YES
  - Message: `refactor(skills): eliminate global mutable state, per-execution instances`
  - Files: Affected skill modules (likely multiple)
  - Pre-commit: `zig build test`


|---

- [ ] 22. Add config validation at startup

  **What to do**:
  - In `src/config/validator.zig` (new file) or within ConfigLoader after merging configs, add validation logic
  - Validate required fields are present (e.g., NVIDIA_API_KEY, model ID)
  - Validate ranges: ports within 1-65535, timeouts > 0, thread counts > 0
  - Validate color codes, URLs, paths exist if needed
  - Return clear error messages for each validation failure
  - Call validator early in main.zig startup; on error, log and exit with code 1

  **Must NOT do**:
  - Allow startup with invalid config (fail fast is better)
  - Silently default critical missing values (like API key)
  - Print full config to logs (may contain secrets)

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: [`zig`, `validation`]
  - **Reason**: Straightforward validation checks; no complex logic
  - **Skills Evaluated but Omitted**: `deep` (simple checks), `unspecified-high` (routine)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5; independent of other Wave 5 tasks)
  - **Blocks**: None
  - **Blocked By**: Wave 4 (config must be stable)

  **References**:
  - Config struct: `src/config/config.zig`
  - Existing config loading: `src/config/config_loader.zig`
  - Zig stdlib: `std.mem.eql`, `std.fmt.parseInt`, `std.fs`

  **WHY Each Reference Matters**:
  - Config: Defines all fields to validate
  - ConfigLoader: Integration point - validation runs after loading

  **Acceptance Criteria**:
  - [ ] All required fields validated with helpful errors
  - [ ] Startup fails with non-zero exit if invalid config
  - [ ] Valid config passes without errors
  - [ ] Tests added for validator edge cases

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Startup with missing required field
    Tool: Bash
    Steps:
      1. Create config without NVIDIA_API_KEY
      2. Run ./zeptoclaw
    Expected: Exit with error message indicating missing API key
    Evidence: .sisyphus/evidence/task-22-missing-key.txt

  Scenario: Startup with invalid port
    Tool: Bash
    Steps:
      1. Set gateway.port = 99999
      2. Run ./zeptoclaw
    Expected: Error about port range
    Evidence: .sisyphus/evidence/task-22-invalid-port.txt
  ```

  **Evidence to Capture**:
  - [ ] task-22-missing-key.txt
  - [ ] task-22-invalid-port.txt
  - [ ] task-22-validator-source.txt

  **Commit**: YES
  - Message: `feat(config): add startup validation for required fields`
  - Files: `src/config/validator.zig`, `src/config/config.zig` (if validator method added)
  - Pre-commit: `zig build`


- [ ] 23. Implement StateStore.save()

  **What to do**:
  - In `src/autonomous/state_store.zig`, implement `save()` method that persists state to disk
  - State includes: memory embeddings, session data, skill states, workspace changes
  - Use atomic write: write to temp file then rename to avoid corruption
  - Serialize state as JSON or Zig binary (consistent with load)
  - Call `save()` on graceful shutdown (Task 25) and periodically (e.g., every 5 minutes)
  - Handle errors gracefully (log but don't crash on save failure)

  **Must NOT do**:
  - Block shutdown waiting for save (use background thread or timeout)
  - Save sensitive data unencrypted (consider encryption if needed)
  - Overwrite state file without backup (keep previous version as .bak)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `file-io`, `serialization`]
  - **Reason**: Requires careful file handling, atomic operations, error handling
  - **Skills Evaluated but Omitted**: `quick` (complex state), `deep` (I/O heavy)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5)
  - **Blocks**: None (independent of other Wave 5 tasks)
  - **Blocked By**: Wave 4 (state structure should be stable)

  **References**:
  - `src/autonomous/state_store.zig` - existing load and state structs
  - `src/autonomous/types.zig` - state definitions
  - Zig file I/O: `std.fs`, atomic rename via `std.fs.rename`
  - Background analysis: "StateStore.save()" missing

  **WHY Each Reference Matters**:
  - StateStore: Where to implement save
  - Types: What data to persist
  - fs: Atomic operations to prevent corruption

  **Acceptance Criteria**:
  - [ ] `save()` method implemented and writes complete state atomically
  - [ ] State can be loaded after save (round-trip test)
  - [ ] Background periodic save works (test by waiting)
  - [ ] Save errors are logged but don't crash

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Save and load state round-trip
    Tool: Bash
    Steps:
      1. Start agent, let it create state
      2. Trigger save: `kill -USR1` or call method
      3. Restart agent, verify state loaded
    Expected: State persists across restarts
    Evidence: .sisyphus/evidence/task-23-save-load.txt

  Scenario: Periodic autosave
    Tool: Bash
    Steps:
      1. Start agent, wait 6 minutes
      2. Check modification time of state file
    Expected: State file updated periodically
    Evidence: .sisyphus/evidence/task-23-autosave.log
  ```

  **Evidence to Capture**:
  - [ ] task-23-save-load.txt
  - [ ] task-23-autosave.log
  - [ ] task-23-code-diff.txt

  **Commit**: YES
  - Message: `feat(state): implement StateStore.save() for persistence`
  - Files: `src/autonomous/state_store.zig`
  - Pre-commit: `zig build test`


- [ ] 24. Standardize structured logging

  **What to do**:
  - Review all `std.log.*` calls across codebase
  - Ensure logs include consistent fields: timestamp, level, component, message, and context (e.g., request_id for HTTP)
  - Use JSON format for logs if not already (structured = machine parseable)
  - Add scopes: e.g., `log.debug("msg", .{ .component = "nim", .request_id = id })`
  - Remove string concatenation in log messages; use structured fields
  - Document logging conventions in a new `LOGGING.md` or similar

  **Must NOT do**:
  - Change log levels arbitrarily (respect existing levels)
  - Introduce breaking changes to log consumers (keep field names stable)
  - Log sensitive data (already handled in Task 12)

  **Recommended Agent Profile**:
  - **Category**: `medium`
  - **Skills**: [`zig`, `ast_grep_search`]
  - **Reason**: Need to standardize across many files; ensure consistency
  - **Skills Evaluated but Omitted**: `quick` (many files), `deep` (not deeply complex)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5)
  - **Blocks**: None
  - **Blocked By**: Wave 4

  **References**:
  - Zig stdlib logging: `std.log`
  - Existing log calls: `rg 'std\.log\.[a-z]+' src/`
  - OpenTelemetry or structured logging best practices

  **WHY Each Reference Matters**:
  - std.log: Standard logging facility; need to use it correctly
  - Existing calls: Baseline to refactor

  **Acceptance Criteria**:
  - [ ] All logs include at least timestamp, level, component
  - [ ] No string concatenation in log messages (all structured)
  - [ ] Log output is valid JSON (if JSON format chosen)
  - [ ] Log volume not increased significantly

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify structured fields present
    Tool: Bash
    Steps:
      1. Run agent with LOG_LEVEL=debug
      2. Capture logs to file
      3. Parse as JSON (jq) and check fields
    Expected: All logs have timestamp, level, component fields
    Evidence: .sisyphus/evidence/task-24-structured-check.txt
  ```

  **Evidence to Capture**:
  - [ ] task-24-structured-check.txt
  - [ ] task-24-modified-files.txt
  - [ ] task-24-sample-log.json

  **Commit**: YES
  - Message: `chore(logging): standardize structured logging format`
  - Files: All files with logging updates
  - Pre-commit: `zig build`


- [ ] 25. Add graceful shutdown (signal handling)

  **What to do**:
  - In main.zig (or root.zig), set up signal handlers for SIGINT, SIGTERM
  - Use `std.os.linux.sigaction` or Zig's signal abstraction
  - On signal, set an atomic flag (`should_shutdown`) that main loop checks
  - Main loop should break gracefully, finishing current work, closing channels, saving state
  - Ensure all resources deinitialized properly, then exit with code 0
  - Add timeout for shutdown (e.g., 10s) after which force exit

  **Must NOT do**:
  - Ignore signals (must respond to SIGTERM from systemd)
  - Exit with non-zero on graceful shutdown (should be 0)
  - Leak resources on fast shutdown (try to clean up)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: [`zig`, `signal-handling`, `concurrency`]
  - **Reason**: Signal handling and coordinated shutdown across threads is tricky
  - **Skills Evaluated but Omitted**: `quick` (complex coordination), `deep` (but implementation-focused)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5)
  - **Blocks**: None
  - **Blocked By**: Wave 4 (core stable)

  **References**:
  - Zig signal handling: `std.os.linux.sigaction` or `std.Thread` condition variables for coordination
  - Systemd service files need to send SIGTERM; test with `systemctl stop`
  - Existing main loop: `src/main.zig`, `src/agent/loop.zig`

  **WHY Each Reference Matters**:
  - Signals: How systemd orchestrates shutdown
  - Main loop: Where to inject shutdown check

  **Acceptance Criteria**:
  - [ ] SIGINT (Ctrl+C) causes graceful shutdown
  - [ ] SIGTERM causes graceful shutdown
  - [ ] State saved before exit
  - [ ] Exit code is 0 on graceful shutdown
  - [ ] Shutdown completes within 10s timeout

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Graceful shutdown via SIGINT
    Tool: Bash
    Steps:
      1. Start ./zeptoclaw-gateway
      2. Press Ctrl+C
    Expected: Logs show shutdown sequence, exit 0
    Evidence: .sisyphus/evidence/task-25-sigint.txt

  Scenario: Graceful shutdown via SIGTERM
    Tool: Bash
    Steps:
      1. Start gateway in background
      2. kill -TERM $PID
    Expected: Same graceful shutdown, exit 0
    Evidence: .sisyphus/evidence/task-25-sigterm.txt
  ```

  **Evidence to Capture**:
  - [ ] task-25-sigint.txt
  - [ ] task-25-sigterm.txt
  - [ ] task-25-code-diff.txt

  **Commit**: YES
  - Message: `feat(graceful): add signal handling for graceful shutdown`
  - Files: `src/main.zig`, `src/agent/loop.zig`
  - Pre-commit: `zig build`


- [ ] 26. Add health check endpoints

  **What to do**:
  - In `src/services/gateway_server.zig` and other HTTP servers, add `/health` endpoint
  - Endpoint returns JSON: `{"status":"healthy","timestamp":...}` with 200 OK if all systems operational
  - Checks: memory usage, provider connectivity (maybe quick ping), channel status
  - Add `/ready` endpoint for Kubernetes readiness probes (applies to gateway, webhook, shell2http)
  - Ensure health checks are lightweight and fast (<100ms)

  **Must NOT do**:
  - Make health checks too heavy (no full integration tests)
  - Expose internal details that help attackers (keep it simple)
  - Return 200 if degraded (should be 503 if critical failures)

  **Recommended Agent Profile**:
  - **Category**: `medium`
  - **Skills**: [`zig`, `http`]
  - **Reason**: Straightforward HTTP endpoints; need to choose appropriate checks
  - **Skills Evaluated but Omitted**: `quick` (multiple servers), `unspecified-high` (not complex)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5)
  - **Blocks**: None
  - **Blocked By**: Wave 4

  **References**:
  - Existing HTTP server code: `src/services/gateway_server.zig`, `src/services/http_server.zig`
  - Kubernetes probe guidelines: liveness vs readiness
  - Example health check implementation in other services

  **WHY Each Reference Matters**:
  - HTTP servers: Where to add endpoints
  - K8s probes: Need both liveness (is process alive) and readiness (can serve)

  **Acceptance Criteria**:
  - [ ] `/health` returns 200 JSON when healthy, 503 when degraded
  - [ ] `/ready` returns 200 when ready to accept traffic
  - [ ] Health checks complete in <100ms
  - [ ] All servers (gateway, webhook, shell2http) have health endpoints

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Health endpoint returns 200 when system healthy
    Tool: Bash (curl)
    Steps:
      1. Start gateway server
      2. curl http://localhost:18789/health
    Expected: HTTP 200, JSON with status "healthy"
    Evidence: .sisyphus/evidence/task-26-health-200.txt

  Scenario: Ready endpoint for Kubernetes
    Tool: Bash
    Steps:
      1. curl http://localhost:18789/ready
    Expected: HTTP 200
    Evidence: .sisyphus/evidence/task-26-ready-200.txt
  ```

  **Evidence to Capture**:
  - [ ] task-26-health-200.txt (curl output)
  - [ ] task-26-ready-200.txt
  - [ ] task-26-server-modules.txt (list of modified server files)

  **Commit**: YES
  - Message: `feat(health): add /health and /ready endpoints`
  - Files: `src/services/gateway_server.zig`, `src/services/webhook_server.zig`, `src/services/shell2http_server.zig`
  - Pre-commit: `zig build`


- [ ] 27. Add metrics endpoint (Prometheus format)

  **What to do**:
  - Expose `/metrics` endpoint on gateway (or dedicated metrics server) in Prometheus text format
  - Instrument key metrics: request count, latency (buckets), error count, skill invocation count, memory usage
  - Use Prometheus client library if available, or simple text format: `metric_name{label="value"} value`
  - Update Prometheus deployment config (if any) to scrape this endpoint
  - Ensure metrics are low-overhead (avoid heavy computations)

  **Must NOT do**:
  - Expose sensitive data as metric labels (e.g., user IDs, API keys)
  - Make metrics endpoint authenticated (Prometheus needs direct access)
  - Add unbounded cardinality metrics (e.g., per-URL without limit)

  **Recommended Agent Profile**:
  - **Category**: `medium`
  - **Skills**: [`zig`, `http`, `monitoring`]
  - **Reason**: Need to design metric set and implement exposition
  - **Skills Evaluated but Omitted**: `quick` (instrumentation takes time), `deep` (not algorithmically hard)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 5)
  - **Blocks**: None
  - **Blocked By**: Wave 4

  **References**:
  - Prometheus text format spec: `# HELP`, `# TYPE`, metric lines
  - Existing metrics (if any): search for `counter`, `gauge`, `histogram`
  - `src/services/gateway_server.zig` - where to add endpoint

  **WHY Each Reference Matters**:
  - Prometheus format: Must conform to parser expectations
  - Gateway: Central place to aggregate metrics

  **Acceptance Criteria**:
  - [ ] `/metrics` endpoint returns valid Prometheus format
  - [ ] Core metrics present: request_total, request_duration_seconds, errors_total, memory_bytes
  - [ ] Prometheus can scrape and parse metrics
  - [ ] Metrics update in real-time (test by generating traffic)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Metrics endpoint returns valid Prometheus format
    Tool: Bash
    Steps:
      1. curl http://localhost:18789/metrics
      2. Pipe to promtool check rules (if available)
    Expected: Valid format, no parse errors
    Evidence: .sisyphus/evidence/task-27-metrics-output.txt

  Scenario: Metrics update under load
    Tool: Bash + Apache bench or hey
    Steps:
      1. Start gateway
      2. Run `hey -c 10 -z 30s http://localhost:18789/v1/chat/completions`
      3. curl /metrics during and after
    Expected: request_total increases, latency histogram populated
    Evidence: .sisyphus/evidence/task-27-under-load.txt
  ```

  **Evidence to Capture**:
  - [ ] task-27-metrics-output.txt
  - [ ] task-27-under-load.txt
  - [ ] task-27-promtool-check.txt (if available)

  **Commit**: YES
  - Message: `feat(metrics): add Prometheus /metrics endpoint`
  - Files: `src/services/gateway_server.zig`
  - Pre-commit: `zig build`


|---

- [x] 28. Remove backup file migration_config.zig.bak

  **What to do**:
  - Check if backup file exists: `migration_config.zig.bak` (from earlier migration attempts)
  - Verify it's not tracked by git: `git status` should show it as untracked
  - If exists and untracked, remove it: `rm migration_config.zig.bak`
  - If tracked, remove from git: `git rm --cached migration_config.zig.bak` then delete
  - Confirm removal: `ls` shows no such file

  **Must NOT do**:
  - Remove any other files accidentally (verify exact filename)
  - Force remove tracked file without git rm (would remain in history but that's ok, still remove from working tree)
  - Delete migration_config.zig itself (only the .bak)

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: [`bash`]
  - **Reason**: Trivial file deletion; no complexity
  - **Skills Evaluated but Omitted**: none

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 6; independent)
  - **Blocks**: None
  - **Blocked By**: Wave 5

  **References**:
  - `ls migration_config.zig.bak` to check existence
  - `git status` to see if tracked

  **WHY Each Reference Matters**:
  - ls: Confirms file exists before removal
  - git status: Determines correct removal method (untracked vs tracked)

  **Acceptance Criteria**:
  - [ ] Backup file no longer exists in working directory
  - [ ] No accidental deletion of other files
  - [ ] Git repository clean (no untracked backup)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify backup file removed
    Tool: Bash
    Steps:
      1. ls migration_config.zig.bak 2>/dev/null || echo 'not found'
    Expected: Output 'not found'
    Evidence: .sisyphus/evidence/task-28-check.txt
  ```

  **Evidence to Capture**:
  - [ ] task-28-check.txt
  - [ ] task-28-git-status.txt (shows clean)

  **Commit**: YES
  - Message: `chore: remove backup migration_config.zig.bak`
  - Files: N/A (deleted file, but list in commit as deleted if tracked)
  - Pre-commit: `git status` (should be clean)


- [x] 29. Update README with migration status

  **What to do**:
  - Open `README.md`
  - Update the "Migration from OpenClaw" section to reflect completion of all 11 phases
  - Add a note about Zig 0.15.2 migration complete, any remaining known issues (none), and how to verify build
  - Update "Skills Ported" count if needed (should be 21)
  - Update "Build Status" badge if present
  - Add a line in "Recent Updates" summarizing completion

  **Must NOT do**:
  - Remove existing useful information (just add completion note)
  - Change API documentation (keep accurate)
  - Add TODOs or placeholders

  **Recommended Agent Profile**:
  - **Category**: `writing`
  - **Skills**: [`markdown`, `technical-writing`]
  - **Reason**: Documentation update; needs clear, concise prose
  - **Skills Evaluated but Omitted**: `quick` (requires care), `deep` (not deep analysis)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 6; independent)
  - **Blocks**: None
  - **Blocked By**: Wave 5 (but can start earlier)

  **References**:
  - Current README.md
  - Recent commit messages (the 6 migration commits)
  - Project status: all 11 phases complete

  **WHY Each Reference Matters**:
  - README: Primary user-facing doc; must accurately reflect state
  - Commits: What to summarize in Recent Updates

  **Acceptance Criteria**:
  - [ ] README clearly states migration complete
  - [ ] Build instructions still accurate
  - [ ] Skills list accurate (21 skills)
  - [ ] No broken links or formatting

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: README renders correctly on GitHub
    Tool: Web browser or curl
    Steps:
      1. cat README.md > /tmp/readme.md
      2. Use GitHub Markdown preview locally or check online
    Expected: No broken formatting, all sections visible
    Evidence: .sisyphus/evidence/task-29-render-check.txt
  ```

  **Evidence to Capture**:
  - [ ] task-29-render-check.txt
  - [ ] task-29-diff.txt (git diff of README)

  **Commit**: YES
  - Message: `docs: update README with Zig 0.15.2 migration completion`
  - Files: `README.md`
  - Pre-commit: `git build` (just build, not needed for docs)


- [x] 30. Add runbooks for deployment

  **What to do**:
  - Create `docs/runbooks/` directory if not exists
  - Write runbooks covering: common operational tasks, troubleshooting, monitoring, backup/restore
  - Include sections: Prerequisites, Steps, Expected outcomes, Rollback procedures
  - Runbooks to include:
    - Deploying new version (systemd restart, health checks)
    - Handling memory leak (restart, state restore)
    - Responding to API outage (retry, fallback provider)
    - Restoring from StateStore backup
    - Updating configuration safely
  - Use clear, step-by-step instructions with commands

  **Must NOT do**:
  - Write vague runbooks (be specific with commands and paths)
  - Include internal secrets in runbooks (reference env vars instead)
  - Make runbooks overly long; focus on actionable procedures

  **Recommended Agent Profile**:
  - **Category**: `writing`
  - **Skills**: [`technical-writing`, `devops`]
  - **Reason**: Documentation requires clear procedural writing for operators
  - **Skills Evaluated but Omitted**: `quick` (requires thoroughness), `deep` (operational knowledge needed)

  **Parallelization**:
  - **Can Run In Parallel**: YES (Wave 6; independent)
  - **Blocks**: None
  - **Blocked By**: Wave 5 (runbooks reference new features)

  **References**:
  - Existing systemd service files for deployment steps
  - Configuration files and env vars
  - Monitoring endpoints (/health, /metrics)
  - StateStore backup location

  **WHY Each Reference Matters**:
  - systemd: Deployment involves service management
  - Config: Procedures reference config changes
  - Monitoring: Runbooks use health metrics

  **Acceptance Criteria**:
  - [ ] At least 5 runbooks covering common incidents
  - [ ] Each runbook includes clear commands, expected outputs, rollback
  - [ ] Runbooks stored in `docs/runbooks/*.md`
  - [ ] Peer review by operator (simulate following steps)

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Verify runbook completeness
    Tool: Bash
    Steps:
      1. ls docs/runbooks/
      2. For each .md file, check for 'Prerequisites', 'Steps', 'Rollback'
    Expected: 5+ files, each has required sections
    Evidence: .sisyphus/evidence/task-30-runbooks-list.txt
  ```

  **Evidence to Capture**:
  - [ ] task-30-runbooks-list.txt
  - [ ] task-30-sample-runbook.md (one example)
  - [ ] task-30-docs-diff.txt

  **Commit**: YES
  - Message: `docs: add operational runbooks for deployment and troubleshooting`
  - Files: `docs/runbooks/*.md` (new files)
  - Pre-commit: N/A


- [ ] 31. Final integration test run and verification

  **What to do**:
  - Execute full test suite: `zig build test`
  - Run integration tests with real NVIDIA API key (if available) or ensure they skip gracefully
  - Capture full test output and verify all tests pass
  - If any tests fail, debug and re-run until all pass
  - Final verification: build release binary and smoke test basic operations (start gateway, send a request)
  - Document any known limitations or open issues in a new `KNOWN_ISSUES.md` if needed

  **Must NOT do**:
  - Skip final test run (must verify everything works)
  - Ignore failing tests (must fix before declaring done)
  - Commit with known failing tests (all must pass)

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`zig`, `testing`, `troubleshooting`]
  - **Reason**: Final comprehensive verification; requires diagnosing any last failures
  - **Skills Evaluated but Omitted**: `quick` (potential debugging), `unspecified-high` (comprehensive)

  **Parallelization**:
  - **Can Run In Parallel**: NO (Wave 6; final sequential verification)
  - **Blocks**: All other tasks (this is the last task before final wave)
  - **Blocked By**: All previous waves (must be complete)

  **References**:
  - Test commands: `zig build test`
  - Integration tests: `tests/integration_test.zig`
  - Build artifacts: `zig-out/bin/`
  - Known issues from previous test runs

  **WHY Each Reference Matters**:
  - Final gate: everything must pass before handing off to reviewers

  **Acceptance Criteria**:
  - [ ] `zig build test` exits 0 with all tests passing
  - [ ] Integration tests either pass or skip with clear message (no failures)
  - [ ] Release build succeeds (`zig build -Drelease-safe`)
  - [ ] Basic smoke test (curl gateway /health) succeeds
  - [ ] No new regressions since last test run

  **QA Scenarios (MANDATORY)**:

  ```
  Scenario: Full test suite passes
    Tool: Bash
    Steps:
      1. zig build test
    Expected: Exit 0, "All N tests passed"
    Evidence: .sisyphus/evidence/task-31-full-test.txt

  Scenario: Release build and smoke test
    Tool: Bash
    Steps:
      1. zig build -Drelease-safe
      2. ./zig-out/bin/zeptoclaw-gateway &
      3. curl http://localhost:18789/health
      4. kill %%
    Expected: Build succeeds, health returns 200
    Evidence: .sisyphus/evidence/task-31-smoke.txt
  ```

  **Evidence to Capture**:
  - [ ] task-31-full-test.txt
  - [ ] task-31-smoke.txt
  - [ ] task-31-release-build.txt
  - [ ] task-31-known-issues.md (if any)

  **Commit**: YES
  - Message: `chore: final integration test run and verification`
  - Files: Any last-minute fixes (unlikely)
  - Pre-commit: `zig build test`


|---
## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE. Rejection → fix → re-run.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, curl endpoint, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Thread Safety Review** — `unspecified-high`
  Run `tsc --noEmit` + linter + `bun test`. Review all changed files for: `as any`/`@ts-ignore`, empty catches, console.log in prod, commented-out code, unused imports. Check AI slop: excessive comments, over-abstraction, generic names (data/result/item/temp).
  Output: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high` (+ `playwright` skill if UI)
  Start from clean state. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Test cross-task integration (features working together, not isolation). Test edge cases: empty state, invalid input, rapid actions. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance. Detect cross-task contamination: Task N touching Task M's files. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **1-9** (skill fixes): `fix(skills): migrate ArrayList.toOwnedSlice() to Zig 0.15.2 API`
- **10** (build fix): `build: ensure compilation with Zig 0.15.2`
- **11** (ConfigLoader bug): `fix(config): correct errdefer in mergeConfigs`
- **12** (logs): `chore(logging): remove sensitive auth tokens from startup logs`
- **13** (thread safety): `fix(whatsapp): add mutex protection for shared state`
- **14** (timeouts): `feat(nim): add configurable request timeout`
- **15** (@intCast): `fix(safety): replace @intCast with validated conversions`
- **16** (errors): `fix(handling): replace catch unreachable with proper errors`
- **17-21** (tests): `test: restore and expand integration and unit tests`
- **22-27** (production): `feat(prod): add validation, graceful shutdown, metrics`
- **28-31** (cleanup): `chore: remove backup, document, final verification`
- **FINAL** (reviews): No commit - these are verification steps

---

## Success Criteria

### Build Verification
```bash
$ zig build
# Exit: 0, no errors/warnings about API usage
```

### Test Verification
```bash
$ zig build test
# Exit: 0, all tests pass (including integration tests)
# Output: "All 23 tests passed" (or similar count)
```

### Thread Safety Verification
```bash
# Stress test with concurrent requests (manual or automated)
$ ./zig-out/bin/zeptoclaw-gateway --stress 100
# No crashes, no data corruption
```

### Memory Leak Check (10 min run)
```bash
$ valgrind --leak-check=full ./zig-out/bin/zeptoclaw-gateway [test args] &
$ sleep 600
$ kill $!
$ valgrind output shows "0 leaks"
```

---

## Risk Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Build fails due to cascading errors after skill fixes | High | High | Sentinel approach: fix one skill at a time, verify build incrementally |
| Thread safety fixes introduce deadlocks | Medium | High | Use std.Thread.Mutex with defer unlock; add deadlock detection tests |
| Integration tests flaky due to external API | High | Medium | Provide skip mechanism with clear message; mock alternative |
| @intCast replacement misses edge cases | Medium | Medium | Add comprehensive test coverage for numeric conversions |

---

## Notes for Agent Orchestrator

- **Delegate via Sisyphus**: This plan is designed for parallel execution. Assign Wave 1 tasks (1-9) to multiple Sisyphus-Junior agents (category `quick` with Zig skill). Each task is independent.
- **Dependency management**: Ensure Wave 2 tasks wait for Wave 1 completion. Use `depends_on` field if supported.
- **Evidence collection**: Each task must produce evidence files in `.sisyphus/evidence/` per QA scenarios.
- **Compilation gating**: Do not proceed to Wave 2 until all Wave 1 tasks report success.
- **Integration tests**: May require NVIDIA API key; ensure agent has access via `.env` or prompt user.
- **Backup file deletion**: Simple but verify it's not tracked by git before deleting.

---

**Plan Version**: 1.0
**Last Updated**: 2025-02-28
**Status**: Ready for Execution
