# Restore

Persona markdown and memory live in the private repo **github.com/bkataru/barvis**, checked out at `~/.zeptoclaw/workspace`. `~/.openclaw/workspace` is a read-only leftover. `barvis-sync.timer` commits the ZeptoClaw workspace every 30 minutes (includes daily journals and `MEMORY.md`).

Live files under `~/.zeptoclaw/sessions/` are copied into `zeptoclaw-state/` in barvis:

| Live path | In `bkataru/barvis` |
|-----------|---------------------|
| `~/.zeptoclaw/sessions/transcripts/` | `zeptoclaw-state/transcripts/` |
| `~/.zeptoclaw/sessions/whatsapp/` | `zeptoclaw-state/whatsapp/` |
| `~/.zeptoclaw/sessions/exec-approvals.txt` | `zeptoclaw-state/exec-approvals.txt` |
| systemd user unit | **not** in git (`NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`) |

Policy (allowlist, ports, model) is `~/.zeptoclaw/config.json` (redacted; no tokens).

Restore:

```bash
mkdir -p ~/.zeptoclaw/sessions/transcripts ~/.zeptoclaw/sessions/whatsapp
cp -a ~/.zeptoclaw/workspace/zeptoclaw-state/transcripts/. ~/.zeptoclaw/sessions/transcripts/
cp -a ~/.zeptoclaw/workspace/zeptoclaw-state/whatsapp/. ~/.zeptoclaw/sessions/whatsapp/
# copy systemd template, then set NVIDIA_API_KEY and GATEWAY_AUTH_TOKEN on the local unit
systemctl --user start zeptoclaw-gateway.service
```
