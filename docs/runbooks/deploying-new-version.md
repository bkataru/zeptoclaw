# Deploy a new Zig build

```bash
cd zeptoclaw
zig build
zig build test --summary all
systemctl --user kill zeptoclaw-gateway.service
pkill -9 -f zeptoclaw-gateway
systemctl --user start zeptoclaw-gateway.service
journalctl --user -u zeptoclaw-gateway.service --since "30s ago"
```

Success: `connection status=connected`. A ping should log `inbound` then `generating` then a send. After a send, `[memory] journal in` / `out` on `memory/YYYY-MM-DD.md`.

`systemctl --user restart` can hang on this unit; kill + start is the reliable path.

Memory ingest waits `ZEPTO_MEMORY_SECS` (default 1800) after start. `barvis-memory-update.timer` is `memory compact`, not ingest. See `docs/memory.md`.
