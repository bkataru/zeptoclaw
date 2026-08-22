# Initial deployment

1. Install Zig 0.16.0 and Node 18+.
2. `zig build` in the repo.
3. Set `NVIDIA_API_KEY` (and `GATEWAY_AUTH_TOKEN`) in the **user** systemd unit or `~/.config/zeptoclaw/env` (`chmod 600`).
4. Put WhatsApp allowlist in OpenClaw-compatible config (`channels.whatsapp`).
5. `systemctl --user enable --now zeptoclaw-gateway.service`
6. Confirm `journalctl --user -u zeptoclaw-gateway.service` shows `connection status=connected`.
7. Pair WhatsApp if stdout/stderr asks for a QR (wrapper prints QR on stderr).

Optional: `scripts/migrate/` if moving files from `~/.openclaw`. Optional: webhook / shell2http units.

Do not commit session auth, ledger JSON, or API keys.
