/**
 * Utility functions for ZeptoClaw Cloudflare Worker
 */

/**
 * Calculate cooldown duration based on consecutive failures
 */
export function calculateCooldown(consecutiveFailures: number): number {
  const COOLDOWN_BASE_MS = 60_000; // 1 minute
  const COOLDOWN_MAX_MS = 600_000; // 10 minutes
  const cooldown = COOLDOWN_BASE_MS * Math.pow(2, consecutiveFailures - 1);
  return Math.min(cooldown, COOLDOWN_MAX_MS);
}

/**
 * Check if a gateway is healthy based on its health state
 */
export function isGatewayHealthy(health: GatewayHealth, now: number): boolean {
  return health.cooldownUntil < now;
}

/**
 * Get default gateway health state
 */
export function getDefaultGatewayHealth(): GatewayHealth {
  return {
    lastFailure: 0,
    consecutiveFailures: 0,
    cooldownUntil: 0,
    lastSuccess: 0,
    avgLatency: 0,
    requestCount: 0,
  };
}

/**
 * Get default ZeptoClaw state
 */
export function getDefaultZeptoClawState(): ZeptoClawState {
  return {
    local_last_seen: 0,
    last_heartbeat: undefined,
    heartbeat_history: [],
    gateway_incidents: [],
    downtime_alerts_sent: [],
    total_requests: 0,
    total_errors: 0,
    last_error: undefined,
  };
}

// Type definitions
export interface GatewayHealth {
  lastFailure: number;
  consecutiveFailures: number;
  cooldownUntil: number;
  lastSuccess: number;
  avgLatency: number;
  requestCount: number;
}

export interface HeartbeatData {
  timestamp: number;
  hostname?: string;
  gateway_pid?: number;
  gateway_http_status?: string;
  uptime_seconds?: number;
  version?: string;
  memory_mb?: number;
}

export interface GatewayIncident {
  timestamp: number;
  type: string;
  session_id?: string;
  stuck_duration_seconds?: number;
  hostname?: string;
  error?: string;
  reported_at: string;
}

export interface ZeptoClawState {
  local_last_seen: number;
  last_heartbeat?: HeartbeatData;
  heartbeat_history?: HeartbeatData[];
  gateway_incidents?: GatewayIncident[];
  downtime_alerts_sent?: number[];
  total_requests: number;
  total_errors: number;
  last_error?: string;
}

// Time constants
export const COOLDOWN_BASE_MS = 60_000;
export const COOLDOWN_MAX_MS = 600_000;
export const LOCAL_AGENT_TIMEOUT_MS = 60 * 60 * 1000; // 1 hour
export const GATEWAY_TIMEOUT_MS = 30_000; // 30 seconds
export const MAX_RETRIES = 3;
