# Restore

Gitignored state you must back up yourself:

| Path | Contents |
|------|----------|
| `sessions/whatsapp/` | Baileys auth + `inbound-ledger.json` |
| `sessions/transcripts/` | agent transcripts |
| `~/.zeptoclaw/` | config, memory, credentials if used |
| systemd user unit | `NVIDIA_API_KEY`, `GATEWAY_AUTH_TOKEN` |

Restore auth dir, `zig build`, start `zeptoclaw-gateway`. First connect with a restored ledger should **not** replay already-seen ids. If you restore auth **without** the ledger, history can fire once.

Re-pair WhatsApp only if auth files are gone or `Bad MAC` never recovers.
