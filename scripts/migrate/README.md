# OpenClaw to ZeptoClaw file copy

Optional. Copies credentials, sessions, memory, and webhook secrets from `~/.openclaw` to `~/.zeptoclaw`.

```bash
./migrate-all.sh --dry-run
./migrate-all.sh
```

The current gateway session store is `~/.zeptoclaw/sessions/whatsapp/native.sqlite`, not `~/.zeptoclaw/credentials/`.
