# Troubleshooting Common Issues

## Prerequisites

- Access to logs (`journalctl --user`)
- Ability to run commands and restart services
- Access to configuration files and binaries

---

## Issue: Services Fail to Start

### Symptom

```bash
systemctl --user status zeptoclaw-gateway.service
# Shows: failed, inactive, or loaded but not active
```

### Diagnosis

```bash
# View journal for this unit
journalctl --user -u zeptoclaw-gateway -n 50

# Check for common errors:
# - "permission denied" → binary not executable or lacking capabilities
# - "address already in use" → port conflict
# - "no such file or directory" → binary missing
# - "environment variable required" → NVIDIA_API_KEY not set
```

### Fixes

1. **Binary not found or not executable:**
   ```bash
   chmod +x /home/user/zeptoclaw/zig-out/bin/*
   ```

2. **Port in use:**
   ```bash
   # Find process using port 18789
   sudo ss -tulpn | grep :18789
   # Change port in config or stop conflicting service
   ```

3. **Missing environment:**
   ```bash
   export NVIDIA_API_KEY=your-key
   systemctl --user import-environment NVIDIA_API_KEY
   systemctl --user restart zeptoclaw-gateway.service
   ```

4. **Binary crashes on start:**
   ```bash
   # Run directly to see error output
   ./zig-out/bin/zeptoclaw-gateway
   # If segfault or panic, report issue with backtrace
   ```

---

## Issue: Health Endpoint Returns `degraded` or `unhealthy`

### Symptom

```bash
curl http://localhost:18789/health
# {"status":"degraded"} or {"status":"unhealthy"}
```

### Diagnosis

```bash
# Check full health response (more details)
curl http://localhost:18789/health | jq .

# Check logs for provider errors
journalctl --user -u zeptoclaw-gateway -n 100 | grep -i 'provider\|nim\|error'

# Check if NIM API reachable
curl -s -H "Authorization: Bearer $NVIDIA_API_KEY" \
  https://integrate.api.nvidia.com/v1/models | head -5
```

### Common Causes

1. **NIM API unreachable** → See [Responding to API Outage](/runbooks/responding-to-api-outage.md)
2. **Invalid API key** → Verify `NVIDIA_API_KEY` is correct and not expired
3. **Provider timeout** → Increase timeout in config
4. **Circuit breaker open** → Automatic after failures; will reset after cooldown

---

## Issue: High Memory Usage

See dedicated runbook: [Handling Memory Leak](/runbooks/handling-memory-leak.md)

Quick actions:

```bash
# Monitor memory
watch -n 5 'ps -o pid,rss,cmd -p $(pgrep -f zeptoclaw-gateway)'

# Restart gateway if suspicious growth
systemctl --user restart zeptoclaw-gateway.service
```

---

## Issue: Slow Response Times

### Diagnosis

```bash
# Check metrics for latency
curl -s http://localhost:18789/metrics | grep 'http_request_duration_seconds' | head

# Check provider latency specifically
curl -s http://localhost:18789/metrics | grep 'provider_latency_seconds'

# Check system load
top -b -n 1 | head -15
```

### Common Causes

1. **NIM API slow** → Network issue or NIM overloaded; enable fallback or wait
2. **High CPU on host** → Check for other processes; consider scaling up
3. **Large context** → Requests with huge histories; implement pruning
4. **Disk I/O contention** → StateStore save blocking; check disk latency

---

## Issue: Skill Execution Fails

### Symptom

Agent responds with error: "Skill X failed" or "tool call error"

### Diagnosis

```bash
# Find logs for that skill execution
journalctl --user -u zeptoclaw-gateway | grep -i 'skill.*error\|tool.*failed' | tail -20

# Verify skill is loaded
./zig-out/bin/zeptoclaw --list-skills | grep -i 'skill-name'

# Test skill directly (if test endpoint exists)
```

### Common Skill Issues

- **Configuration missing**: Skill's required config not in config file
- **Permission denied**: Skill accessing file/directory without OS permissions
- **Timeout**: Skill took too long; increase skill timeout in config
- **API quota**: External API (GitHub, web) rate limits; add retry or backoff

---

## Issue: WhatsApp Channel Not Receiving Messages

### Diagnosis

```bash
# Check WhatsApp channel status
systemctl --user status whatsapp-responder.service

# Check inbound.zig logs
journalctl --user -u whatsapp-responder | tail -50

# Verify WhatsApp credentials configured
grep -A3 'whatsapp' ~/.config/zeptoclaw/config.json

# Test QR code generation (if using QR login)
# The service should log QR code to terminal when first started
```

### Common Issues

- **QR code expired** → Restart WhatsApp service to get new QR
- **Phone not connected** → Ensure WhatsApp app is connected and Web session active
- **Credential file missing** → Run migration scripts from `scripts/migrate/`

---

## Issue: Metrics Endpoint Missing or Incomplete

### Symptom

```bash
curl http://localhost:18789/metrics
# No metrics or 404
```

### Diagnosis

```bash
# Check if metrics feature compiled
./zig-out/bin/zeptoclaw-gateway --help | grep -i metric

# Check build configuration
# Build.zig should include metrics feature (usually always included in release)
```

### Fix

Rebuild with metrics enabled:

```bash
zig build -Drelease-safe -Dmetrics
# Or edit build.zig to always enable
```

---

## Issue: StateStore Save Fails

### Symptom

Logs contain: "failed to save state: ..."

### Diagnosis

```bash
# Check directory permissions
ls -la ~/.local/share/zeptoclaw/state

# Check disk space
df -h ~

# Check for file locks (if another process holds state)
lsof ~/.local/share/zeptoclaw/state
```

### Fixes

1. **Permission denied**: Ensure agent user owns state directory
   ```bash
   chown -R $(whoami) ~/.local/share/zeptoclaw/state
   ```

2. **Disk full**: Clean up disk or configure StateStore to use different location

3. **File locked**: Should be rare; restart service to release lock

---

## Issue: Integration Tests Fail

### Symptom

```bash
zig build test
# Some tests fail, especially integration_test.zig
```

### Common Causes

- **NVIDIA_API_KEY not set**: Integration tests require real API or mock
  ```bash
  export NVIDIA_API_KEY=your-key
  zig build test
  ```

- **Config mismatch**: Tests use different Config struct than production
  - Ensure `integration_test.zig` imports correct Config type
  - Update test fixtures to match production config fields

- **Network timeout**: Tests hitting real NIM with slow response
  - Increase timeout in test config
  - Use mock provider instead

See `src/providers/` mock implementations for testing strategies.

---

## Issue: Systemd Timers Not Triggering

### Symptom

Timer units exist but jobs not running:

```bash
systemctl --user list-timers | grep zeptoclaw
# Shows next/left but no recent "ran" entries
```

### Diagnosis

```bash
# Check timer status
systemctl --user status workspace-sync.timer

# Check if timers are enabled and active
systemctl --user is-enabled workspace-sync.timer

# Check for timer monotonic/calendar configuration errors
systemctl --user cat workspace-sync.timer
```

### Fix

Ensure timers are started (not just enabled):

```bash
systemctl --user start workspace-sync.timer
# Enable ensures start on boot; start triggers now
```

---

## Logging Levels

To increase log verbosity temporarily:

```bash
# For a single service
systemctl --user edit zeptoclaw-gateway.service
# Add:
[Service]
Environment="LOG_LEVEL=debug"

systemctl --user daemon-reload
systemctl --user restart zeptoclaw-gateway.service
```

Valid levels: `debug`, `info`, `warn`, `error`.

---

## Permission Denied Errors

Common causes:

- **Binary not executable:**
  ```bash
  chmod +x zig-out/bin/*
  ```

- **Config file not readable:**
  ```bash
  chmod 600 ~/.config/zeptoclaw/config.json
  ```

- **State directory unwritable:**
  ```bash
  chmod 700 ~/.local/share/zeptoclaw/state
  ```

- **Systemd user not permitted:** If using system-wide services, ensure service files have correct `User=` and `Group=` directives, or use user services as documented.

---

## Network Connectivity Issues

```bash
# Test outbound connectivity from host
curl -I https://integrate.api.nvidia.com

# Check firewall
sudo ufw status  # or iptables -L

# If behind proxy, ensure proxy variables set:
echo $http_proxy $https_proxy
```

---

## Data Corruption Recovery

If state files appear corrupted (JSON parse errors, incomplete writes):

1. Restore from latest backup: see [Restoring from Backup](/runbooks/restoring-from-backup.md)
2. If no backup, try dropping corrupted file and restarting (data loss localized)
3. Report issue with corrupted file for investigation

---

## Collecting Debug Information for Support

When escalating:

```bash
# Gather system info
uname -a > ~/debug-info.txt
zig version >> ~/debug-info.txt
git rev-parse HEAD >> ~/debug-info.txt

# Gather recent logs (last 1000 lines)
journalctl --user -u zeptoclaw-gateway -n 1000 > ~/gateway-log.txt
journalctl --user -u zeptoclaw-webhook -n 1000 > ~/webhook-log.txt
journalctl --user -u zeptoclaw-shell2http -n 1000 > ~/shell2http-log.txt

# Gather config (redact API key)
sed 's/nvapi-[^"]*/nvapi-REDACTED/' ~/.config/zeptoclaw/config.json > ~/config-redacted.json

# Gather metrics
curl -s http://localhost:18789/metrics > ~/metrics.txt

# Pack into tarball
tar czf ~/zeptoclaw-debug-$(date +%Y%m%d-%H%M%S).tar.gz \
  ~/debug-info.txt \
  ~/*-log.txt \
  ~/config-redacted.json \
  ~/metrics.txt
```

---

## Emergency Contacts

- **NVIDIA NIM Status**: https://status.nvidia.com/
- **ZeptoClaw Issues**: https://github.com/bkataru/zeptoclaw/issues
- **Barvis/Moltbook**: https://www.moltbook.com/u/barvis_da_jarvis

---

## Index of Common Issues

| Symptom | Likely Cause | Runbook |
|---------|--------------|---------|
| Service won't start | Binary missing, env missing, port conflict | This document |
| Health `degraded` | NIM outage, provider failing | [API Outage](/runbooks/responding-to-api-outage.md) |
| Memory rising | Leak, unbounded growth | [Memory Leak](/runbooks/handling-memory-leak.md) |
| Slow responses | NIM slow, network, load | This document (Slow Response) |
| Skill errors | Missing config, permissions | This document (Skill Execution) |
| State corruption | Disk failure, crash | [Restore from Backup](/runbooks/restoring-from-backup.md) |
| Config change needed | Safe update procedure | [Configuration](/runbooks/updating-configuration.md) |

---

## Quick Command Reference

```bash
# Check all services
systemctl --user list-units 'zeptoclaw*' 'gateway*' 'whatsapp*' 'moltbook*'

# View logs (last 100 lines)
journalctl --user -u zeptoclaw-gateway -n 100

# Test health
curl http://localhost:18789/health

# Check metrics
curl http://localhost:18789/metrics | head

# Restart gateway
systemctl --user restart zeptoclaw-gateway.service

# Validate config
./zig-out/bin/zeptoclaw --validate-config

# Increase log level temporarily
systemctl --user import-environment LOG_LEVEL=debug
systemctl --user restart zeptoclaw-gateway.service
```
