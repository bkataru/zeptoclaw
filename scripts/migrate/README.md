# OpenClaw to ZeptoClaw file copy

Optional. Copies credentials, sessions, memory, and webhook secrets from `~/.openclaw` to `~/.zeptoclaw`.

```bash
./migrate-all.sh --dry-run
./migrate-all.sh
```

Baileys auth used by the current gateway is `~/.zeptoclaw/sessions/whatsapp/`, not `~/.zeptoclaw/credentials/`.
