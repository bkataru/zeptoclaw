# Responding to NVIDIA NIM API Outage

## Prerequisites

- NVIDIA NIM API key configured
- Understanding of fallback provider configuration (if available)
- Access to NIM status page or error indicators from logs
- Systemd service management permissions

## Overview

When the NVIDIA NIM API becomes unavailable (HTTP 5xx, timeouts, rate limits), ZeptoClaw can experience degraded performance or failures. This runbook covers:

1. Confirming NIM outage
2. Enabling fallback provider (if configured)
3. Mitigating impact (retry, circuit breaker)
4. Restoring normal operation after NIM recovery
5. Long-term resilience improvements

---

## Step 1: Confirm Outage

### Check Gateway Logs for NIM Errors

```bash
# Look for recent errors in gateway logs
journalctl --user -u zeptoclaw-gateway -n 200 | grep -i 'nim\|nvidia\|provider' | tail -20

# Typical error messages:
# "provider error: request failed with status 503"
# "timeout after 30000ms"
# "rate limit exceeded"
# "authentication failed"
```

### Check Health Endpoint

```bash
curl -s http://localhost:18789/health | jq . 2>/dev/null || echo "Health check failed"
```

**Degraded state:**
```json
{
  "status": "degraded",
  "providers": ["NIM unreachable"],
  "timestamp": "..."
}
```

### Test Direct NIM API (from gateway host)

```bash
# curl test with your API key
curl -s -H "Authorization: Bearer $NVIDIA_API_KEY" \
  "https://integrate.api.nvidia.com/v1/models" | head -20

# If returns error or timeout, NIM is likely down
```

### Check NVIDIA Status Page

Visit: https://status.nvidia.com/ or NVIDIA developer portal for incident reports.

---

## Step 2: Immediate Mitigation

### Option A: Enable Fallback Provider (if configured)

If ZeptoClaw is configured with a fallback provider (e.g., local LLM, OpenAI), switch to it:

```bash
# Edit configuration (see Configuration runbook)
# Typically in ~/.config/zeptoclaw/config.json or similar

# Change provider priority or set fallback only
# Example:
# {
#   "providers": [
#     { "name": "fallback", "type": "openai-compatible", "url": "http://localhost:8000/v1" },
#     { "name": "nim", "type": "nim", "api_key": "..." }
#   ]
# }

# After editing, restart gateway
systemctl --user restart zeptoclaw-gateway.service

# Verify health again
curl -s http://localhost:18789/health
```

**Note:** Fallback provider must be pre-configured. If not, see long-term improvements below.

### Option B: Circuit Breaker (Automatic)

If circuit breaker is enabled (see provider configuration), ZeptoClaw should automatically stop trying NIM after consecutive failures and switch to fallback. Verify:

```bash
# Check metrics for circuit breaker state
curl -s http://localhost:18789/metrics | grep -i 'circuit'
# Look for: zeptoclaw_provider_circuit_state{provider="nim"} 1 (0=closed,1=open,2=half)
```

If circuit is open, NIM calls are already blocked. Monitor `/metrics` to see when NIM becomes healthy again.

### Option C: Retry with Backoff (if not already)

Ensure provider configuration includes retry logic:

```json
{
  "retry_policy": {
    "max_retries": 3,
    "backoff_ms": 1000,
    "backoff_multiplier": 2
  }
}
```

No immediate action needed; just verify config.

---

## Step 3: Reduce Load (if under stress)

If NIM outage coinciding with high traffic, consider temporarily:

### Lower Concurrent Request Limits

```bash
# Edit gateway configuration (e.g., concurrency settings)
# and restart

# Example: max_concurrent_requests in config
```

### Enable Request Queueing

If queue configured, increase queue size to buffer requests:

```bash
# Adjust in config
```

**Note:** This is a temporary measure; queue fill-up will eventually backpressure clients.

---

## Step 4: Monitor Recovery

When NIM recovers, ZeptoClaw should automatically resume using it (if circuit breaker configured). Monitor:

```bash
# Watch health endpoint
while true; do
  curl -s http://localhost:18789/health | jq .status
  sleep 10
done
```

### Manual Re-enable NIM (if disabled)

If you manually removed NIM from config:

```bash
# Edit config to restore NIM provider
# Move NIM back to primary position or enable it
# restart gateway
systemctl --user restart zeptoclaw-gateway.service
```

### Verify NIM is healthy again

```bash
# Test direct NIM call
curl -s -H "Authorization: Bearer $NVIDIA_API_KEY" \
  "https://integrate.api.nvidia.com/v1/models" | grep -q 'id' && echo "NIM reachable"

# Check gateway health
curl -s http://localhost:18789/health | jq .providers
# Should show NIM as healthy
```

---

## Step 5: Post-Incident Review

### Collect Timeline

```bash
# Extract relevant log entries around incident
journalctl --user -u zeptoclaw-gateway --since "2 hours ago" > ~/nim-outage-$(date +%Y%m%d).log

# Note:
# - Start time: when errors first appeared
# - End time: when NIM recovered
# - Actions taken (fallback enable/disable, restarts)
# - Client impact (failed requests count from metrics)
```

### Review Metrics

If Prometheus collected metrics during incident:

- Request rate (requests_per_second)
- Error rate (errors_total / requests_total)
- P99 latency
- Circuit state changes

### Update Runbooks

If the incident revealed gaps (e.g., no fallback configured, slow detection), update configuration and procedures.

---

## Long-Term Resilience Improvements

### 1. Configure Multiple Providers

Set up a local fallback provider (e.g., Llama 3 via Ollama):

```json
{
  "providers": [
    { "name": "nim", "type": "nim", "api_key": "...", "priority": 1 },
    { "name": "local-ollama", "type": "openai-compatible", "url": "http://localhost:11434/v1", "priority": 2 }
  ]
}
```

### 2. Set Circuit Breaker Thresholds

```json
{
  "circuit_breaker": {
    "failure_threshold": 5,
    "timeout_ms": 30000,
    "reset_timeout_s": 60
  }
}
```

This prevents hammering a down NIM with requests and fails fast to fallback.

### 3. Add Request Timeouts

Already implemented (Task 14). Ensure timeouts are set to avoid hanging connections.

### 4. Implement Bulkhead Pattern

Limit concurrent requests per provider to isolate failures.

### 5. Alerting

Create alerts on:
- Provider error rate > 50% for 1 minute
- Circuit breaker opened
- Health status degraded

Send to Slack/email/PagerDuty.

---

## Rollback

If enabling fallback causes issues:

```bash
# Restore original config from backup (if changed)
cp ~/.config/zeptoclaw/config.json.bak ~/.config/zeptoclaw/config.json

# Restart gateway
systemctl --user restart zeptoclaw-gateway.service

# Verify health
curl -s http://localhost:18789/health
```

---

## References

- [Configuration](/runbooks/updating-configuration.md) - How to safely edit config files
- [Health Check](/runbooks/troubleshooting.md) - Interpreting health status
- [NVIDIA Status](https://status.nvidia.com/)
- Metrics: `/metrics` endpoint for provider-specific error counts

---

## Quick Commands Reference

```bash
# Check gateway health
curl http://localhost:18789/health

# Check provider status
curl http://localhost:18789/metrics | grep provider

# Restart gateway
systemctl --user restart zeptoclaw-gateway.service

# View recent errors
journalctl --user -u zeptoclaw-gateway -n 100 | grep -i error

# Test direct NIM
curl -H "Authorization: Bearer $NVIDIA_API_KEY" https://integrate.api.nvidia.com/v1/models
```
