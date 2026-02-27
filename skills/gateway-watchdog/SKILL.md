---
name: gateway-watchdog
version: 1.0.0
description: Auto-detect and recover from stuck gateway sessions
metadata: {"emoji": "🐕"}
---

# Gateway Watchdog Skill

Automated monitoring and recovery for stuck gateway sessions.

## Triggers
scheduled: 0 * * * *
event: startup

## Configuration
stuck_threshold_seconds (integer): Restart if stuck > this (default: 600)

## Status
Stub skill - implementation pending.
