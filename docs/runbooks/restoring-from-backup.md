# Restore

Persona markdown and memory live in the private repo **github.com/bkataru/barvis**, which is `~/.openclaw/workspace` (and `~/.zeptoclaw/workspace` as a symlink). `barvis-sync.timer` commits that tree every 30 minutes.

ZeptoClaw live files under `~/zeptoclaw/sessions/` are gitignored in the **source** repo, then **copied** into `zeptoclaw-state/` inside barvis:

| Live path | In `bkataru/barvis` |
|-----------|---------------------|
| `zeptoclaw/sessions/transcripts/` | `zeptoclaw-state/transcripts/` |
| `zeptoclaw/sessions/whatsapp/` (creds, pre-keys, `inbound-ledger.json`) | `zeptoclaw-state/whatsapp/` |
| `zeptoclaw/sessions/exec-approvals.txt` | `zeptoclaw-state/exec-approvals.txt` |
| systemd user unit | **not** in git (`NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN`) |

Restore:

```bash
mkdir -p ~/zeptoclaw/sessions/transcripts ~/zeptoclaw/sessions/whatsapp
cp -a ~/.openclaw/workspace/zeptoclaw-state/transcripts/. ~/zeptoclaw/sessions/transcripts/
cp -a ~/.openclaw/workspace/zeptoclaw-state/whatsapp/. ~/zeptoclaw/sessions/whatsapp/
zig build
systemctl --user start zeptoclaw-gateway.service
```

First connect with a restored ledger should not replay already-seen ids. If you restore auth **without** the ledger, history can fire once.

Re-pair WhatsApp only if auth files are gone or `Bad MAC` never recovers.
