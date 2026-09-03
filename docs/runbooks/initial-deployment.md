# Initial deployment

1. Install Zig 0.16.0.
2. `zig build` in the repo.
3. Set `NVIDIA_API_KEY` and `GATEWAY_AUTH_TOKEN` on the user systemd unit or `~/.config/zeptoclaw/env` (`chmod 600`). Copy the same NVIDIA key to `~/.config/zeptoclaw/nim.env` for memory oneshots.
4. Put WhatsApp allowlist in OpenClaw-compatible config (`channels.whatsapp`). Workspace is `~/.zeptoclaw/workspace`.
5. `systemctl --user enable --now zeptoclaw-gateway.service`
6. Optional: `systemctl --user enable --now barvis-memory-update.timer` (`zeptoclaw memory compact` every 2 h).
7. Confirm `journalctl --user -u zeptoclaw-gateway.service` shows `connection status=connected`.
8. Pair WhatsApp if stderr asks for a QR (`zeptoclaw whatsapp pair`).

Optional: `scripts/migrate/` if moving files from `~/.openclaw`. Optional: webhook / shell2http units.

Do not commit session auth, ledger JSON, or API keys.
