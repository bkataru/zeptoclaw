# Deploy a new Zig build

```bash
cd zeptoclaw
zig build
zig build test --summary all
systemctl --user kill zeptoclaw-gateway.service
pkill -9 -f zeptoclaw-gateway
pkill -9 -f baileys_wrapper
systemctl --user start zeptoclaw-gateway.service
journalctl --user -u zeptoclaw-gateway.service --since "30s ago"
```

Success: `connection status=connected`. A new ping should log `inbound` then `generating` then `sent message_id=…` (not a send-ACK timeout). After a turn, `[memory] journal in` / `out` on `memory/YYYY-MM-DD.md`.

`systemctl --user restart` can hang on this unit; kill + start is the reliable path.

Memory ingest waits `ZEPTO_MEMORY_SECS` (default 1800) after start. The 2-hour timer is **compact**, not ingest. See [memory.md](../memory.md).
