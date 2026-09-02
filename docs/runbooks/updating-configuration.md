# Configuration

ZeptoClaw reads OpenClaw-shaped JSON. Search order is in `src/openclaw_compat/openclaw.zig`: `~/.zeptoclaw/config.json`, `./zeptoclaw.json`, `./config.json`, then read-only `~/.openclaw/...`.

Important fields:

```json
{
  "env": { "NVIDIA_API_KEY": "from-env-preferred" },
  "agents": { "defaults": { "model": { "primary": "nvidia/nemotron-3-ultra-550b-a55b", "fallbacks": ["nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"] } } },
  "gateway": { "port": 18789, "auth": { "mode": "token", "token": "..." } },
  "channels": {
    "whatsapp": {
      "dmPolicy": "allowlist",
      "allowFrom": ["+15555550100"],
      "groupPolicy": "allowlist"
    }
  }
}
```

Prefer env for secrets (`NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`). Memory oneshots also read `~/.config/zeptoclaw/nim.env`. Restart the gateway after edits. Do not store live tokens in the git tree.

Persona and journals: `~/.zeptoclaw/workspace`. See `docs/memory.md`.
