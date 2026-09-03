# OpenClaw compatibility

Zig-only bridge (`src/openclaw_compat/openclaw.zig`). No npm `openclaw`. `$HOME/.zeptoclaw` first, then read-only `~/.openclaw`. Live WhatsApp is the native client + `Agent.runTurn`. Gateway port **18789**. Workspace markdown (soul, identity, journals, `MEMORY.md`) is `~/.zeptoclaw/workspace`.

## 1. Principles

- **Zero npm `openclaw` dep** - the bridge never imports the npm package; it only parses on-disk formats and mirrors path/API conventions.
- **ZeptoClaw primary → OpenClaw legacy fallback** - every resolver tries `~/.zeptoclaw` first, then falls back read-only to `~/.openclaw`.
- **Preserve wire + KV compat** - reuses Cloudflare KV `70a3dbb693e246d48a0fbdc7b32c7317` + `compatibility_date = 2026-01-01` so either side sees the same state.
- **Canonical logic stays ZeptoClaw** - legacy aliases are normalized, not duplicated.

**Build deps:** `build.zig` / `build.zig.zon` import only `utcp` + `zeitgeist` (vendored `vendor/zeitgeist`), plus `mcp`/`raikage`/`hf-hub-zig`/`niza`/`zenmap`. No `openclaw` entry.

## 2. Cloudflare Worker KV & Compatibility Date

`cloudflare-worker/wrangler.toml`:

```toml
compatibility_date = "2026-01-01"

[[kv_namespaces]]
binding = "BARVIS_STATE"
id = "70a3dbb693e246d48a0fbdc7b32c7317"

[[kv_namespaces]]
binding = "ZEPTOCLAW_STATE"
id = "70a3dbb693e246d48a0fbdc7b32c7317"
```

Both bindings point at the **same KV id** - old gateways writing `BARVIS_STATE` remain visible to new gateways reading `ZEPTOCLAW_STATE` (and vice versa). State key is `state` (BarvisState: `replied_comments`, `seen_posts`, `last_heartbeat`, `heartbeat_history`, etc.). Cron trigger `*/30 * * * *` preserved.

> Deploy is live at `https://zeptoclaw-router.bkataru.workers.dev` (Version 6a24e46a-*), health `1/1` `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` @ `https://integrate.api.nvidia.com/v1/chat/completions` (superseded `thinkingmachines/inkling`, EOL 2026-08-25). Both `BARVIS_STATE`/`ZEPTOCLAW_STATE` share `70a3dbb693e246d48a0fbdc7b32c7317`. Alias `barvis-router` 182dc8e2 remains until route cutover.

## 3. Config Paths & Priority

### 3.1 Candidates (in order)

In `src/openclaw_compat/openclaw.zig`:

```zig
pub const primary_config_paths = [_][]const u8{
    "/home/user/.zeptoclaw/config.json",
    "./zeptoclaw.json",
    "./config.json",
};
pub const legacy_config_paths = [_][]const u8{
    "/home/user/.openclaw/openclaw.json",
    "/home/user/.openclaw/workspace/openclaw.json",
};
pub fn defaultConfigCandidates() []const []const u8 {
    return &(primary_config_paths ++ legacy_config_paths);
}
```

`src/config/migration_config.zig:ConfigLoader.load()` probes the 5 paths above in order via `compat.cwd().openFile`, parsing the first hit as `OpenClawConfig` (`ignore_unknown_fields = true`). `findExistingConfig(allocator)` returns the first existing path (owned dupe) or `null`.

### 3.2 Format

Both candidates share the **OpenClaw JSON schema** (`OpenClawConfig`):

```json
{
  "env": { "NVIDIA_API_KEY": "nvapi-..." },
  "agents": {
    "defaults": {
      "model": { "primary": "nvidia/nemotron-3-ultra-550b-a55b", "fallbacks": ["nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"] },
      "imageModel": { "primary": "...", "fallbacks": [] },
      "workspace": "/home/user/.openclaw/workspace",
      "maxConcurrent": 4
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "controlUi": { "enabled": true, "allowInsecureAuth": false },
    "auth": { "mode": "token", "token": "..." }
  },
  "channels": {
    "whatsapp": {
      "dmPolicy": "allowlist|pairing|open|disabled",
      "allowFrom": ["+15555550100"],
      "groupPolicy": "allowlist|open|disabled"
    }
  }
}
```

Loaded into `ZeptoClawConfig` (canonical runtime config). Unknown fields ignored. `model.primary` is the agent's single chat model; `model.fallbacks[0]` (when present) is dispatched by the `see_image` tool for vision (the primary model need not support vision). Only `allowFrom`/`dmPolicy`/`groupPolicy` are hot-reloadable via `POST /reload`; model changes require a gateway restart.

## 4. Workspace Resolution

```zig
pub fn resolveWorkspaceDir(allocator) ![]const u8
```

1. `$HOME/.zeptoclaw/workspace` if it exists → return it
2. else `$HOME/.openclaw/workspace` (legacy)
3. else return legacy path anyway (caller creates lazily)

Consumers: `src/services/webhook_endpoints.zig:EndpointContext.init()` and `src/services/shell2http_endpoints.zig:EndpointContext.init()` both call `zeptoclaw.openclaw_compat.resolveWorkspaceDir(allocator)` so `git pull/push` etc. run in the correct checkout.

## 5. Credentials / Sessions / Group Policies

```zig
pub fn primaryCredentialsDir(allocator) ![]const u8 // ~/.zeptoclaw/credentials
pub fn legacyCredentialsDir(allocator) ![]const u8  // ~/.openclaw/credentials
pub fn primarySessionsDir(allocator) ![]const u8    // ~/.zeptoclaw/sessions
pub fn legacySessionsDir(allocator) ![]const u8     // ~/.openclaw/agents/main/sessions
```

Always **primary first, legacy fallback read-only**. Group policies + `allowFrom` live inside the config JSON (`channels.whatsapp.dmPolicy` / `groupPolicy` / `allowFrom` + `group_activation_commands`), but session/credential directories are bridged so WhatsApp auth state is readable from either tree. Runtime reads `whatsapp_*` fields from the merged `ZeptoClawConfig` regardless of source file.

## 6. Gateway Service & Ports

```zig
pub const primary_gateway_service = "zeptoclaw-gateway.service";
pub const legacy_gateway_service  = "openclaw-gateway.service";
pub fn gatewayServiceVariants() [2][]const u8
pub fn journalGatewayArgs(service) [6][]const u8 // journalctl --user -u <service> -n 50
```

| Concern | Canonical | Legacy fallback |
|---------|-----------|----------------|
| systemd unit | `zeptoclaw-gateway.service` on `:18789` (`gateway.port`, `bind=lan` → `0.0.0.0:18789`) via `systemd/zeptoclaw-gateway.service` | `openclaw-gateway.service` |
| Journal | `journalctl --user -u zeptoclaw-gateway.service -n 50 --no-pager` | Falls back to `openclaw-gateway.service` if primary empty (see `shell2http_endpoints.zig:journalGateway`) |
| Process probe | `pgrep -a zeptoclaw` | Falls back to `pgrep -a openclaw` (`shell2http_endpoints.zig:processOpenclaw`, route `/process/openclaw`) |

Gateway binary `zig-out/bin/zeptoclaw-gateway` (`build.zig:gateway_server_mod` → `src/gateway/gateway_server.zig`). Sessions dir `/home/user/zeptoclaw/sessions`.

## 7. Gateway HTTP API

### 7.1 Legacy alias mapping

```zig
pub fn isLegacyGatewayAlias(path) bool
pub fn canonicalizeGatewayPath(path) []const u8
```

| Legacy (OpenClaw) | Canonical (ZeptoClaw) |
|-------------------|-----------------------|
| `/gateway/health` | `/health` |
| `/gateway/state`  | `/state` |
| `/gateway/status` | `/status` |

Only those three are aliases; all other paths pass through.

### 7.2 Canonical gateway routes (`src/gateway/http_server.zig`)

```
GET  /health
GET  /status
GET  /sessions                  POST /sessions/:id/terminate
GET  /config   POST /config
GET  /logs  (alias → status)
WS   /ws
GET  /  /ui  (control UI, gated)
POST /autonomous/run|/browse|/search|/post|/idea
GET  /discoveries  POST /discoveries/clear
POST /agent  /agent/wait
POST /exec/approve
POST /reload
POST /heartbeat  GET /state
POST /gateway/incident  GET /gateway/incidents
GET  /metrics  (Prometheus)
```

### 7.3 Shell2HTTP read-only surface (`src/services/shell2http_endpoints.zig`)

`/health`, `/systemctl/status`, `/timers`, `/journal/gateway` (with fallback), `/journal/watchdog`, `/journal/webhook`, `/git/status`, `/git/log`, `/disk`, `/memory`, `/uptime`, `/date`, `/ollama/list`, `/ollama/ps`, `/process/openclaw`, `/process/all`, `/worker/state` … all via `EndpointContext.workspace_dir` from the bridge.

### 7.4 Webhook surface (`src/services/webhook_endpoints.zig`)

12 endpoints via `zeptoclaw.openclaw_compat`:

`health` (GET, no auth), `gateway-restart` (`systemctl --user restart zeptoclaw-gateway.service`), `git-pull`/`git-push`, `sync-memory`, `deploy-worker`, `run-tests`, `ollama-run`, `notify`, `timer-status`, `journal-tail`, `heartbeat` (POST `https://barvis-router.bkataru.workers.dev/heartbeat`).

### 7.5 Worker surface (`cloudflare-worker/worker.ts`)

`/health`, `/state` (KV BarvisState), `/moltbook/*`, `/autonomous/*`, `/gateway/*`, `/heartbeat` (persists `last_heartbeat` + history). Single-model routing `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` + KV health tracking.

## 8. Allow-List / E.164 Normalization

```zig
pub fn normalizeE164Digits(allocator, s) ![]u8
pub fn isAllowFromMatch(allow_from, candidate_e164) bool
```

Digits-only compare so `+91 96747 46069` ≡ `15555550101` ≡ `+15555550101`. Used to match `channels.whatsapp.allowFrom` entries against runtime senders.

```zig
test "isAllowFromMatch digits-only" { ... }
test "isLegacyGatewayAlias" { ... }
```

## 9. Migration: `~/.openclaw` → `~/.zeptoclaw`

### 9.1 Manual migration (non-destructive - keep legacy for fallback)

```bash
mkdir -p ~/.zeptoclaw
cp ~/.openclaw/openclaw.json ~/.zeptoclaw/config.json
# or: cp ~/.openclaw/workspace/openclaw.json ~/.zeptoclaw/config.json

cp -a ~/.openclaw/workspace ~/.zeptoclaw/workspace
mkdir -p ~/.zeptoclaw/credentials ~/.zeptoclaw/sessions
cp -a ~/.openclaw/credentials/* ~/.zeptoclaw/credentials/ 2>/dev/null || true
cp -a ~/.openclaw/agents/main/sessions/* ~/.zeptoclaw/sessions/ 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user disable openclaw-gateway.service 2>/dev/null || true

curl -s http://localhost:18789/health          # canonical
curl -s http://localhost:18789/gateway/health  # alias
journalctl --user -u zeptoclaw-gateway.service -n 50 --no-pager
pgrep -a zeptoclaw || pgrep -a openclaw
```

Until `~/.openclaw` is deleted, every resolver is `try ~/.zeptoclaw/<path> else ~/.openclaw/<path>` (read-only fallback).

### 9.2 Worker / KV

No KV migration needed - dual bindings already share `70a3dbb693e246d48a0fbdc7b32c7317`. Deploy with `wrangler deploy` once `CLOUDFLARE_API_TOKEN` is set; `compatibility_date = 2026-01-01` stays.

### 9.3 Rollback

```bash
mv ~/.zeptoclaw/config.json ~/.zeptoclaw/config.json.bak
systemctl --user restart zeptoclaw-gateway.service
# Next load falls back to ~/.openclaw/openclaw.json automatically
```

## 10. Verification

```bash
cat docs/openclaw-compat.md
grep -n openclaw src/openclaw_compat/openclaw.zig | head
grep -rn "zeptoclaw.openclaw_compat" src/services/ --include="*.zig"
grep -n "BARVIS_STATE\|ZEPTOCLAW_STATE\|compatibility_date" cloudflare-worker/wrangler.toml
curl -s http://localhost:18789/health; echo
curl -s http://localhost:18789/gateway/health; echo
```

## 11. File Reference

| File | Role |
|------|------|
| `src/openclaw_compat/openclaw.zig` | Bridge: path constants, `resolveWorkspaceDir`, `findExistingConfig`, service variants, alias mapping, E.164 helpers |
| `src/root.zig` | Re-exports as `zeptoclaw.openclaw_compat` |
| `src/compat.zig` | `cwd`/`getEnvVarOwned`/`timestamp` shims |
| `src/config/migration_config.zig` | `OpenClawConfig` ↔ `ZeptoClawConfig`, 5-path probe |
| `src/services/webhook_endpoints.zig` | 12 webhook endpoints via bridge |
| `src/services/shell2http_endpoints.zig` | 30+ read-only endpoints, journal/process fallbacks |
| `src/gateway/http_server.zig` | Canonical HTTP routes |
| `src/gateway/gateway_server.zig` | `:18789` entrypoint |
| `cloudflare-worker/wrangler.toml` | Dual KV bindings + `compatibility_date` |
| `cloudflare-worker/worker.ts` | Worker routes + KV state |
| `systemd/zeptoclaw-gateway.service` | Canonical unit (`:18789`, `openclaw` fallback) |
| `build.zig` / `build.zig.zon` | `utcp` + `zeitgeist` only for bridge |

## 12. Notes

- Do **not** add `openclaw` to `package.json` or `build.zig.zon`.
- Keep legacy aliases (`/gateway/*`, `openclaw-gateway.service`, `~/.openclaw/**`) - cheap, prevents breakage for old scripts/crons/workers.
- Removing the fallback is a breaking change; gate behind a major version.