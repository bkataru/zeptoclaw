#!/bin/bash
# Send heartbeat to Cloudflare Worker

# Configuration
WORKER_URL="${ZEPTOCLAW_WORKER_URL:-https://zeptoclaw-router.your-subdomain.workers.dev}"

# Get gateway info
GATEWAY_PID=$(pgrep -f "zeptoclaw-gateway" | head -1)
GATEWAY_STATUS="unknown"
MEMORY_MB=0

if [ -n "$GATEWAY_PID" ]; then
    # Check if gateway is responding
    if curl -s -f http://localhost:18789/health > /dev/null 2>&1; then
        GATEWAY_STATUS="ok"
    fi
    
    # Get memory usage
    MEMORY_MB=$(ps -p "$GATEWAY_PID" -o rss= | awk '{print int($1/1024)}')
fi

# Get hostname
HOSTNAME=$(hostname)

# Get uptime
UPTIME_SECONDS=$(cat /proc/uptime | awk '{print int($1)}')

# Send heartbeat
curl -s -X POST "$WORKER_URL/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{
        \"timestamp\": $(date +%s)000,
        \"hostname\": \"$HOSTNAME\",
        \"gateway_pid\": $GATEWAY_PID,
        \"gateway_http_status\": \"$GATEWAY_STATUS\",
        \"memory_mb\": $MEMORY_MB,
        \"uptime_seconds\": $UPTIME_SECONDS
    }" > /dev/null

echo "Heartbeat sent to $WORKER_URL"
