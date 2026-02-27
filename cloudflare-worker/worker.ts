/**
 * ZeptoClaw Cloudflare Worker
 *
 * A Cloudflare Worker that provides a resilient OpenAI-compatible API
 * that routes requests to the ZeptoClaw gateway with automatic failover.
 *
 * Features:
 * - Gateway health tracking with cooldown periods
 * - Automatic retry with exponential backoff
 * - OpenAI-compatible /v1/chat/completions endpoint
 * - Health check endpoint
 * - Heartbeat endpoint for local agent
 * - Gateway incident tracking
 *
 * Deploy: wrangler deploy
 */

import {
  // Types
  GatewayHealth,
  HeartbeatData,
  GatewayIncident,
  ZeptoClawState,
  // Functions
  calculateCooldown,
  isGatewayHealthy,
  getDefaultGatewayHealth,
  getDefaultZeptoClawState,
  // Constants
  COOLDOWN_BASE_MS,
  COOLDOWN_MAX_MS,
  LOCAL_AGENT_TIMEOUT_MS,
  GATEWAY_TIMEOUT_MS,
  MAX_RETRIES,
} from './src/utils';

interface Env {
  // KV namespace for gateway health state
  GATEWAY_HEALTH?: KVNamespace;
  // KV namespace for ZeptoClaw state (heartbeat, incidents, etc.)
  ZEPTOCLAW_STATE: KVNamespace;
  // Environment variables from wrangler.toml
  ZEPTOCLAW_GATEWAY_URL: string;
  ZEPTOCLAW_API_KEY?: string;
}

// ============================================
// GATEWAY CONFIGURATION
// ============================================

interface GatewayConfig {
  id: string;
  name: string;
  url: string;
  priority: number; // Lower = higher priority
}

// Primary gateway configuration
const GATEWAYS: GatewayConfig[] = [
  {
    id: "zeptoclaw-primary",
    name: "ZeptoClaw Primary Gateway",
    url: "", // Will be set from env var ZEPTOCLAW_GATEWAY_URL
    priority: 1,
  },
];

// In-memory health tracking (resets on cold start, but KV persists)
const healthCache = new Map<string, GatewayHealth>();

async function getGatewayHealth(env: Env, gatewayId: string): Promise<GatewayHealth> {
  // Check memory cache first
  const cached = healthCache.get(gatewayId);
  if (cached) return cached;

  // Try KV if available
  if (env.GATEWAY_HEALTH) {
    try {
      const stored = await env.GATEWAY_HEALTH.get(gatewayId, "json");
      if (stored) {
        healthCache.set(gatewayId, stored as GatewayHealth);
        return stored as GatewayHealth;
      }
    } catch {
      // KV error, fall through to default
    }
  }

  const defaultHealth = getDefaultGatewayHealth();
  healthCache.set(gatewayId, defaultHealth);
  return defaultHealth;
}

async function updateGatewayHealth(
  env: Env,
  gatewayId: string,
  update: Partial<GatewayHealth>
): Promise<void> {
  const current = await getGatewayHealth(env, gatewayId);
  const updated = { ...current, ...update };
  healthCache.set(gatewayId, updated);

  // Persist to KV if available (non-blocking)
  if (env.GATEWAY_HEALTH) {
    env.GATEWAY_HEALTH.put(gatewayId, JSON.stringify(updated), {
      expirationTtl: 86400, // 24 hours
    }).catch(() => {}); // Ignore errors
  }
}

async function getHealthyGateways(env: Env): Promise<GatewayConfig[]> {
  const now = Date.now();
  const healthyGateways: Array<{ gateway: GatewayConfig; health: GatewayHealth }> = [];

  for (const gateway of GATEWAYS) {
    const health = await getGatewayHealth(env, gateway.id);
    if (isGatewayHealthy(health, now)) {
      healthyGateways.push({ gateway, health });
    }
  }

  // Sort by: priority first, then by recent success, then by latency
  healthyGateways.sort((a, b) => {
    // Priority first
    if (a.gateway.priority !== b.gateway.priority) {
      return a.gateway.priority - b.gateway.priority;
    }
    // Then by recent success (more recent = better)
    if (a.health.lastSuccess !== b.health.lastSuccess) {
      return b.health.lastSuccess - a.health.lastSuccess;
    }
    // Then by latency (lower = better)
    return a.health.avgLatency - b.health.avgLatency;
  });

  return healthyGateways.map(h => h.gateway);
}

async function callZeptoClawGateway(
  env: Env,
  gateway: GatewayConfig,
  messages: unknown[],
  options: Record<string, unknown> = {}
): Promise<Response> {
  const body: Record<string, unknown> = {
    messages,
    ...options,
  };

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), GATEWAY_TIMEOUT_MS);

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  // Add API key if provided
  if (env.ZEPTOCLAW_API_KEY) {
    headers["Authorization"] = `Bearer ${env.ZEPTOCLAW_API_KEY}`;
  }

  try {
    const response = await fetch(gateway.url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);
    return response;
  } catch (error) {
    clearTimeout(timeoutId);
    throw error;
  }
}

interface RouterResponse {
  success: boolean;
  gateway_used?: string;
  gateway_name?: string;
  response?: unknown;
  error?: string;
  attempts?: number;
  all_gateways_exhausted?: boolean;
}

async function routeRequest(
  env: Env,
  messages: unknown[],
  options: Record<string, unknown> = {}
): Promise<RouterResponse> {
  const healthyGateways = await getHealthyGateways(env);

  if (healthyGateways.length === 0) {
    // Emergency: reset all cooldowns if all gateways are exhausted
    console.log("All gateways exhausted, resetting cooldowns");
    for (const gateway of GATEWAYS) {
      await updateGatewayHealth(env, gateway.id, {
        cooldownUntil: 0,
        consecutiveFailures: 0,
      });
    }
    return {
      success: false,
      error: "All gateways temporarily unavailable. Cooldowns reset - retry immediately.",
      all_gateways_exhausted: true,
    };
  }

  let attempts = 0;

  for (const gateway of healthyGateways.slice(0, MAX_RETRIES)) {
    attempts++;
    const startTime = Date.now();

    try {
      console.log(`Attempting gateway: ${gateway.id}`);
      const response = await callZeptoClawGateway(env, gateway, messages, options);
      const latency = Date.now() - startTime;

      if (response.ok) {
        // Success! Update health
        const health = await getGatewayHealth(env, gateway.id);
        const newAvgLatency = health.requestCount === 0
          ? latency
          : (health.avgLatency * 0.8 + latency * 0.2); // Weighted average

        await updateGatewayHealth(env, gateway.id, {
          lastSuccess: Date.now(),
          consecutiveFailures: 0,
          cooldownUntil: 0,
          avgLatency: newAvgLatency,
          requestCount: health.requestCount + 1,
        });

        if (options.stream) {
          // Return streaming response directly
          return {
            success: true,
            gateway_used: gateway.id,
            gateway_name: gateway.name,
            response: response,
            attempts,
          };
        }

        const data = await response.json();
        return {
          success: true,
          gateway_used: gateway.id,
          gateway_name: gateway.name,
          response: data,
          attempts,
        };
      }

      // Handle specific error codes
      const errorText = await response.text();
      console.log(`Gateway ${gateway.id} failed: ${response.status} - ${errorText}`);

      const health = await getGatewayHealth(env, gateway.id);
      const newFailures = health.consecutiveFailures + 1;

      if (response.status === 429) {
        // Rate limited - longer cooldown
        await updateGatewayHealth(env, gateway.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + COOLDOWN_MAX_MS,
        });
      } else if (response.status === 503 || response.status === 504) {
        // Service unavailable / queue - moderate cooldown
        await updateGatewayHealth(env, gateway.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + calculateCooldown(newFailures),
        });
      } else if (response.status >= 500) {
        // Server error - short cooldown
        await updateGatewayHealth(env, gateway.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + COOLDOWN_BASE_MS,
        });
      }
      // 4xx errors (except 429) don't trigger cooldown - might be request issue

    } catch (error) {
      const latency = Date.now() - startTime;
      console.log(`Gateway ${gateway.id} error after ${latency}ms:`, error);

      const health = await getGatewayHealth(env, gateway.id);
      const newFailures = health.consecutiveFailures + 1;

      // Timeout or network error - assume queue, long cooldown
      await updateGatewayHealth(env, gateway.id, {
        lastFailure: Date.now(),
        consecutiveFailures: newFailures,
        cooldownUntil: Date.now() + calculateCooldown(newFailures),
      });
    }
  }

  return {
    success: false,
    error: `Failed after ${attempts} attempts. All tried gateways are in cooldown.`,
    attempts,
  };
}

// ============================================
// STATE MANAGEMENT
// ============================================

async function getZeptoClawState(env: Env): Promise<ZeptoClawState> {
  const stored = await env.ZEPTOCLAW_STATE.get("state", "json");
  if (stored) {
    // Merge with defaults in case new fields were added
    return { ...getDefaultZeptoClawState(), ...stored as ZeptoClawState };
  }
  return getDefaultZeptoClawState();
}

async function updateZeptoClawState(env: Env, update: Partial<ZeptoClawState>): Promise<void> {
  const current = await getZeptoClawState(env);
  const updated = { ...current, ...update };
  await env.ZEPTOCLAW_STATE.put("state", JSON.stringify(updated));
}

async function shouldWorkerTakeOver(env: Env): Promise<boolean> {
  const state = await getZeptoClawState(env);
  const now = Date.now();

  // If local agent hasn't pinged in over an hour, worker takes over
  return (now - state.local_last_seen) > LOCAL_AGENT_TIMEOUT_MS;
}

// ============================================
// MAIN FETCH HANDLER
// ============================================

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Update gateway URL from env var
    GATEWAYS[0].url = env.ZEPTOCLAW_GATEWAY_URL;

    // Health check endpoint
    if (url.pathname === "/health") {
      const healthyGateways = await getHealthyGateways(env);
      return new Response(JSON.stringify({
        status: "ok",
        healthy_gateways: healthyGateways.length,
        total_gateways: GATEWAYS.length,
        gateways: await Promise.all(GATEWAYS.map(async (g) => ({
          id: g.id,
          name: g.name,
          url: g.url,
          health: await getGatewayHealth(env, g.id),
          is_healthy: isGatewayHealthy(await getGatewayHealth(env, g.id), Date.now()),
        }))),
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Model list endpoint (OpenAI compatible)
    if (url.pathname === "/v1/models") {
      return new Response(JSON.stringify({
        object: "list",
        data: [
          {
            id: "zeptoclaw-gateway",
            object: "model",
            owned_by: "zeptoclaw",
            created: Date.now(),
          },
        ],
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Chat completions endpoint (OpenAI compatible)
    if (url.pathname === "/v1/chat/completions" && request.method === "POST") {
      try {
        const body = await request.json() as Record<string, unknown>;
        const messages = body.messages as unknown[];

        if (!messages || !Array.isArray(messages)) {
          return new Response(JSON.stringify({
            error: { message: "messages is required and must be an array" },
          }), {
            status: 400,
            headers: { "Content-Type": "application/json" },
          });
        }

        const result = await routeRequest(env, messages, body);

        if (!result.success) {
          return new Response(JSON.stringify({
            error: {
              message: result.error,
              type: result.all_gateways_exhausted ? "all_gateways_exhausted" : "router_error",
            },
            router_meta: {
              attempts: result.attempts,
            },
          }), {
            status: 503,
            headers: { "Content-Type": "application/json" },
          });
        }

        // For streaming, return the response directly with added headers
        if (body.stream && result.response instanceof Response) {
          const streamResponse = result.response as Response;
          return new Response(streamResponse.body, {
            headers: {
              "Content-Type": "text/event-stream",
              "X-Router-Gateway": result.gateway_used!,
              "X-Router-Attempts": String(result.attempts),
            },
          });
        }

        // Add router metadata to response
        const response = result.response as Record<string, unknown>;
        response._router_meta = {
          gateway_used: result.gateway_used,
          gateway_name: result.gateway_name,
          attempts: result.attempts,
        };

        return new Response(JSON.stringify(response), {
          headers: { "Content-Type": "application/json" },
        });

      } catch (error) {
        return new Response(JSON.stringify({
          error: { message: `Router error: ${error}` },
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // Reset endpoint (for manual intervention)
    if (url.pathname === "/reset" && request.method === "POST") {
      for (const gateway of GATEWAYS) {
        await updateGatewayHealth(env, gateway.id, getDefaultGatewayHealth());
      }
      return new Response(JSON.stringify({ status: "reset", gateways: GATEWAYS.length }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // ============================================
    // HEARTBEAT ENDPOINTS
    // ============================================

    // Heartbeat endpoint - local agent pings this to signal it's alive
    if (url.pathname === "/heartbeat" && request.method === "POST") {
      const now = Date.now();
      let heartbeatData: Record<string, unknown> = { timestamp: now };

      try {
        const body = await request.json() as Record<string, unknown>;
        heartbeatData = { ...body, timestamp: body.timestamp || now };
      } catch {
        // Simple ping without payload
      }

      const state = await getZeptoClawState(env);

      // Store heartbeat in history (keep last 100)
      const history = (state.heartbeat_history || []).slice(-99);
      history.push(heartbeatData as unknown as HeartbeatData);

      await updateZeptoClawState(env, {
        local_last_seen: now,
        last_heartbeat: heartbeatData as unknown as HeartbeatData,
        heartbeat_history: history,
      });

      // Check if we were in downtime and just recovered
      const wasDown = (now - state.local_last_seen) > LOCAL_AGENT_TIMEOUT_MS;
      const downtime_minutes = wasDown ? Math.round((now - state.local_last_seen) / 60000) : 0;

      return new Response(JSON.stringify({
        status: "ok",
        local_last_seen: now,
        worker_will_takeover: false,
        recovered_from_downtime: wasDown,
        downtime_minutes,
        gateway_pid: heartbeatData.gateway_pid,
        message: wasDown
          ? `Welcome back! You were down for ${downtime_minutes} minutes.`
          : "Heartbeat received. Worker will defer to local agent.",
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // State endpoint - debug view of ZeptoClaw state
    if (url.pathname === "/state") {
      const state = await getZeptoClawState(env);
      const shouldTakeover = await shouldWorkerTakeOver(env);
      const now = Date.now();

      // Calculate uptime stats
      const recentHeartbeats = (state.heartbeat_history || []).slice(-10);
      const avgGatewayMemory = recentHeartbeats.length > 0
        ? Math.round(recentHeartbeats.reduce((sum, h) => sum + ((h as any).memory_mb || 0), 0) / recentHeartbeats.length)
        : null;

      return new Response(JSON.stringify({
        state: {
          ...state,
          // Truncate large arrays for readability
          heartbeat_history: undefined,
        },
        last_heartbeat: state.last_heartbeat,
        recent_heartbeats: recentHeartbeats.slice(-5),
        computed: {
          local_agent_last_seen_ago_ms: now - state.local_last_seen,
          local_agent_last_seen_ago_min: Math.round((now - state.local_last_seen) / 60000),
          worker_should_takeover: shouldTakeover,
          local_agent_timeout_ms: LOCAL_AGENT_TIMEOUT_MS,
          avg_gateway_memory_mb: avgGatewayMemory,
          gateway_status: state.last_heartbeat?.gateway_http_status || 'unknown',
          gateway_pid: state.last_heartbeat?.gateway_pid || 0,
          hostname: state.last_heartbeat?.hostname || 'unknown',
          total_requests: state.total_requests,
          total_errors: state.total_errors,
        },
        config: {
          gateway_url: env.ZEPTOCLAW_GATEWAY_URL,
          has_api_key: !!env.ZEPTOCLAW_API_KEY,
        },
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Reset ZeptoClaw state endpoint
    if (url.pathname === "/state/reset" && request.method === "POST") {
      await env.ZEPTOCLAW_STATE.put("state", JSON.stringify(getDefaultZeptoClawState()));
      return new Response(JSON.stringify({ status: "reset", message: "ZeptoClaw state fully reset" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // ============================================
    // GATEWAY INCIDENT TRACKING
    // ============================================

    // Gateway incident endpoint - watchdog reports stuck sessions here
    if (url.pathname === "/gateway/incident" && request.method === "POST") {
      try {
        const body = await request.json() as {
          type: string;
          session_id?: string;
          stuck_duration_seconds?: number;
          timestamp?: number;
          hostname?: string;
          error?: string;
        };

        const incident: GatewayIncident = {
          timestamp: body.timestamp || Date.now(),
          type: body.type || 'unknown',
          session_id: body.session_id,
          stuck_duration_seconds: body.stuck_duration_seconds,
          hostname: body.hostname,
          error: body.error,
          reported_at: new Date().toISOString(),
        };

        // Store incident separately for tracking
        const state = await getZeptoClawState(env);
        const incidents = state.gateway_incidents || [];
        incidents.push(incident);
        // Keep last 50 incidents
        const trimmedIncidents = incidents.slice(-50);
        await updateZeptoClawState(env, { gateway_incidents: trimmedIncidents });

        console.log(`Gateway incident recorded: ${JSON.stringify(incident)}`);

        return new Response(JSON.stringify({
          status: "ok",
          message: "Incident recorded",
          incident,
        }), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Failed to record incident: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // Get gateway incidents
    if (url.pathname === "/gateway/incidents") {
      const state = await getZeptoClawState(env);
      const incidents = state.gateway_incidents || [];
      return new Response(JSON.stringify({
        count: incidents.length,
        incidents: incidents.slice(-20).reverse(), // Last 20, newest first
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Clear gateway incidents
    if (url.pathname === "/gateway/incidents/clear" && request.method === "POST") {
      await updateZeptoClawState(env, { gateway_incidents: [] });
      return new Response(JSON.stringify({ status: "ok", message: "Gateway incidents cleared" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(`ZeptoClaw Cloudflare Worker - Gateway Router

Endpoints:
- POST /v1/chat/completions (OpenAI compatible)
- GET  /v1/models
- GET  /health
- POST /reset

Health & HA:
- POST /heartbeat (local agent health report)
- GET  /state (full state + health metrics)
- POST /state/reset (reset state)

Gateway Monitoring:
- POST /gateway/incident (report gateway incident)
- GET  /gateway/incidents (view recent incidents)
- POST /gateway/incidents/clear (clear incidents)
`, {
      status: 200,
    });
  },
};
