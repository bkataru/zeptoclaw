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

Success: `connection status=connected`. A new **barvis** ping should log `inbound` then `generating` then `sent message_id=…` (not `RpcTimeout`).

`systemctl --user restart` can hang on this unit; kill + start is the reliable path.
