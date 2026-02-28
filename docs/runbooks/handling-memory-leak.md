# Handling Memory Leak

## Prerequisites

- Access to systemd service logs (`journalctl --user`)
- Understanding of ZeptoClaw memory metrics (see `/metrics` endpoint)
- Ability to restart services (user systemd permissions)
- Previous StateStore backup available (see [Restoring from Backup](/runbooks/restoring-from-backup.md))

## Overview

This runbook helps diagnose and recover from a memory leak in ZeptoClaw. Key signs:
- Rising memory usage over time (check `/metrics` or system monitoring)
- Out-of-memory (OOM) kills in logs
- Performance degradation,GC pauses, or swapping
- `RSS` (Resident Set Size) steadily increasing in monitoring

---

## Step 1: Confirm Memory Leak

### Check Memory Metrics via Prometheus Endpoint

```bash
# Query metrics endpoint
curl -s http://localhost:18789/metrics | grep -E 'process_resident_memory_bytes|memory_usage_bytes'

# Example output (bytes):
# process_resident_memory_bytes 52428800
# process_virtual_memory_bytes 104857600

# Convert to MB: divide by 1024^2
# Or use:
curl -s http://localhost:18789/metrics | grep 'process_resident_memory_bytes' | awk '{print $2/1024/1024 " MB"}'
```

### Check System Memory Usage

```bash
# Using ps
ps -o pid,rss,cmd -p $(pgrep -f zeptoclaw-gateway)

# Using systemd (if systemd service)
systemctl --user status zeptoclaw-gateway.service | grep Memory

# Using top/htop
top -p $(pgrep -f zeptoclaw-gateway) -b -n 1 | head -15
```

### Correlate with Time

Monitor memory over 1 hour:

```bash
# Log memory every 30 seconds for 1 hour
for i in {1..120}; do
  ts=$(date -Iseconds)
  rss=$(ps -o rss= -p $(pgrep -f zeptoclaw-gateway))
  echo "$ts,$rss" >> /tmp/zeptoclaw-memory.csv
  sleep 30
done

# Plot or review CSV
cat /tmp/zeptoclaw-memory.csv
```

**Leak Pattern:** RSS increases monotonically without plateauing or decreasing after GC cycles.

---

## Step 2: Immediate Mitigation

If memory grows to near system limits and impacts stability:

### Restart Gateway (Minimal Impact)

Restarting gateway preserves agent state (sessions, memory) in StateStore.

```bash
# Restart just the gateway (zero-downtime if load balancer configured)
systemctl --user restart zeptoclaw-gateway.service

# Wait for restart
sleep 5
curl -s http://localhost:18789/health || echo "Gateway failed to restart"

# Check logs for rapid memory growth after restart
journalctl --user -u zeptoclaw-gateway -n 50
```

**Impact:** Brief interruption for clients (connections reset). Agent state preserved.

### Full Cluster Restart (if needed)

If multiple services show leak:

```bash
# Stop all ZeptoClaw services
systemctl --user stop --all

# Wait 10 seconds for OS to reclaim memory
sleep 10

# Start services in order
systemctl --user start zeptoclaw-gateway.service
systemctl --user start zeptoclaw-webhook.service
systemctl --user start zeptoclaw-shell2http.service
# ... other services

# Verify health
curl -s http://localhost:18789/health || echo "Failed to restart cleanly"
```

**Impact:** All services down for ~10-30 seconds. Sessions may be interrupted.

---

## Step 3: Diagnose Leak Source

### Enable Detailed Logging Temporarily

```bash
# Edit gateway service to increase log level
systemctl --user edit zeptoclaw-gateway.service

# Add:
[Service]
Environment="LOG_LEVEL=debug"

# Reload and restart
systemctl --user daemon-reload
systemctl --user restart zeptoclaw-gateway.service
```

Watch logs for object accumulation:

```bash
journalctl --user -u zeptoclaw-gateway -f | grep -i 'deinit\|free\|alloc'
```

### Examine Skill Usage

Certain skills may allocate large structures. Check logs for repeated invocations.

```bash
# Count skill invocations from logs
journalctl --user -u zeptoclaw-gateway -n 1000 | grep -oP 'skill:[A-Za-z-]+' | sort | uniq -c | sort -nr
```

### Profile Memory (if zig tools available)

If `zig` toolchain includes `zig memory-leak-detector` or similar:

```bash
# Run gateway in foreground with sanitizers
ASAN_OPTIONS=detect_leaks=1:halt_on_error=0 zig-out/bin/zeptoclaw-gateway &
sleep 60  # let it run and accumulate
kill %1
# Check ASAN output for leaks
```

---

## Step 4: Restore State (if corrupted)

If memory leak accompanied by state corruption, restore from backup:

```bash
# See full guide: /home/user/zeptoclaw/docs/runbooks/restoring-from-backup.md

# Quick restore:
systemctl --user stop zeptoclaw-gateway.service

# Remove current state (WARNING: data loss)
rm -rf ~/.local/share/zeptoclaw/state/*

# Restore from backup (most recent)
cp -r ~/.local/share/zeptoclaw/backups/$(ls -t ~/.local/share/zeptoclaw/backups/ | head -1)/state/* ~/.local/share/zeptoclaw/state/

# Fix permissions
chmod 700 ~/.local/share/zeptoclaw/state

# Restart
systemctl --user start zeptoclaw-gateway.service
curl -s http://localhost:18789/health
```

---

## Step 5: Report and Prevent

### Create Incident Report

Document:
- Time of leak detection
- Memory usage over time (graph if possible)
- Restart timestamp and duration
- Any errors in logs
- Skills in use at time of leak
- Git commit hash at deployment

Store in `~/.local/share/zeptoclaw/incidents/` or ticketing system.

### Apply Code Fix

Once leak source identified (likely skill or provider allocation without deinit), create fix:

- Ensure all `ArrayList` and `AutoArrayHashMap` have matching `deinit()`
- Check for forgotten `try` allocations that fail but still leak
- Review `defer` patterns for early returns

### Test Fix

Build with debug allocator:

```bash
zig build -Drelease-safe -Dmemory-leak-detection
# Or use valgrind if available
valgrind --leak-check=full ./zig-out/bin/zeptoclaw-gateway &
sleep 30
kill %1
```

---

## When to Escalate

If leak persists after restart and state restore:
- Suspected Zig runtime or vendor library bug → collect minimal reproducible case
- Leak occurs within minutes → likely catastrophic (每个请求泄漏) → rollback to previous version immediately
- Gradual leak over days → may be acceptable if restarts are routine (add to quarterly maintenance)

---

## References

- [StateStore backup and restore](/runbooks/restoring-from-backup.md)
- [Configuration](/runbooks/updating-configuration.md)
- System monitoring: `/metrics` endpoint, Prometheus alerts
- Log analysis: `journalctl --user -u zeptoclaw-gateway`

---

## Rollback

If leak cannot be contained quickly:

1. Stop all services
2. Restore binaries from backup (see [Deploying New Version](/runbooks/deploying-new-version.md) rollback section)
3. Restore state from backup
4. Start services with `systemctl --user start`
5. Verify health
