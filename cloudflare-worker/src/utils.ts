/**
 * Utility functions extracted from worker.ts for testing
 */

/**
 * Check if two content strings are similar using Jaccard similarity
 */
export function isSimilarContent(content1: string, content2: string, threshold = 0.7): boolean {
  const normalize = (s: string) => s.toLowerCase().replace(/[^a-z0-9\s]/g, '').trim();
  const words1 = new Set(normalize(content1).split(/\s+/));
  const words2 = new Set(normalize(content2).split(/\s+/));
  
  // Jaccard similarity
  const intersection = [...words1].filter(w => words2.has(w)).length;
  const union = new Set([...words1, ...words2]).size;
  
  return union > 0 && (intersection / union) > threshold;
}

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
 * Check if a model is healthy based on its health state
 */
export function isModelHealthy(health: ModelHealth, now: number): boolean {
  return health.cooldownUntil < now;
}

/**
 * Get default model health state
 */
export function getDefaultHealth(): ModelHealth {
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
 * Get default Barvis state
 */
export function getDefaultBarvisState(): BarvisState {
  return {
    replied_comments: [],
    local_last_seen: 0,
    last_check: 0,
    last_reply: 0,
    total_replies: 0,
    last_browse: 0,
    last_post: 0,
    last_follow: 0,
    last_action: null,
    seen_posts: [],
    upvoted_posts: [],
    commented_posts: [],
    interesting_moltys: [],
    following: [],
    discoveries: [],
    post_ideas: [],
    total_upvotes: 0,
    total_comments: 0,
    total_posts: 0,
    // Enhanced health tracking
    last_heartbeat: undefined,
    heartbeat_history: [],
    gateway_incidents: [],
    downtime_alerts_sent: [],
  };
}

/**
 * Flatten nested comment structure into flat array
 */
export function flattenComments(comments: MoltbookComment[]): MoltbookComment[] {
  const flat: MoltbookComment[] = [];
  for (const comment of comments) {
    flat.push(comment);
    if (comment.replies && comment.replies.length > 0) {
      flat.push(...flattenComments(comment.replies));
    }
  }
  return flat;
}

/**
 * Find unreplied comments from a list of comments
 */
export function findUnrepliedCommentsFromList(
  comments: MoltbookComment[],
  repliedComments: string[],
  agentId: string
): MoltbookComment[] {
  const allComments = flattenComments(comments);
  
  // Build a set of comment IDs that have a Barvis reply as a child
  const commentsWithBarvisReply = new Set<string>();
  for (const comment of allComments) {
    if (comment.author.id === agentId && comment.parent_id) {
      commentsWithBarvisReply.add(comment.parent_id);
    }
  }
  
  // Find comments that:
  // 1. Are not from Barvis
  // 2. Haven't been replied to yet (not in replied_comments)
  // 3. Don't already have a Barvis reply as a child
  // 4. Are either top-level OR are replies to Barvis's comments
  const unreplied = allComments.filter(comment => {
    if (comment.author.id === agentId) return false;
    if (repliedComments.includes(comment.id)) return false;
    if (commentsWithBarvisReply.has(comment.id)) return false;
    if (!comment.parent_id) return true;
    const parent = allComments.find(c => c.id === comment.parent_id);
    if (parent && parent.author.id === agentId) return true;
    return false;
  });
  
  return unreplied;
}

// Type definitions
export interface ModelHealth {
  lastFailure: number;
  consecutiveFailures: number;
  cooldownUntil: number;
  lastSuccess: number;
  avgLatency: number;
  requestCount: number;
}

export interface MoltbookComment {
  id: string;
  content: string;
  author: {
    id: string;
    username: string;
    display_name?: string;
  };
  created_at: string;
  parent_id?: string;
  replies?: MoltbookComment[];
}

export interface HeartbeatData {
  timestamp: number;
  hostname?: string;
  gateway_pid?: number;
  gateway_http_status?: string;
  wsl_memory_percent?: number;
  uptime_seconds?: number;
  recent_crashes?: number;
  version?: string;
}

export interface BarvisState {
  replied_comments: string[];
  local_last_seen: number;
  last_check: number;
  last_reply: number;
  total_replies: number;
  last_browse: number;
  last_post: number;
  last_follow: number;
  last_action: string | null;
  seen_posts: string[];
  upvoted_posts: string[];
  commented_posts: string[];
  interesting_moltys: string[];
  following: string[];
  discoveries: unknown[];
  post_ideas: string[];
  total_upvotes: number;
  total_comments: number;
  total_posts: number;
  // Enhanced health tracking
  last_heartbeat?: HeartbeatData;
  heartbeat_history?: HeartbeatData[];
  gateway_incidents?: unknown[];
  downtime_alerts_sent?: number[];
}

// Model configurations
export const MODELS = [
  { id: "deepseek-ai/deepseek-v3.2", name: "DeepSeek V3.2", maxTokens: 8192, priority: 1 },
  { id: "qwen/qwen3-235b-a22b", name: "Qwen3 235B", maxTokens: 8192, priority: 1 },
  { id: "mistralai/mistral-large-3-675b-instruct-2512", name: "Mistral Large 3", maxTokens: 8192, priority: 1 },
  { id: "stepfun-ai/step-3.5-flash", name: "Step 3.5 Flash", maxTokens: 16384, priority: 2 },
  { id: "moonshotai/kimi-k2.5", name: "Kimi K2.5", maxTokens: 16384, priority: 2 },
  { id: "z-ai/glm4.7", name: "GLM 4.7", maxTokens: 16384, priority: 2 },
  { id: "meta/llama-3.3-70b-instruct", name: "Llama 3.3 70B", maxTokens: 8192, priority: 3 },
  { id: "nvidia/nemotron-3-nano-30b-a3b", name: "Nemotron 3 Nano", maxTokens: 16384, priority: 3 },
  { id: "minimaxai/minimax-m2.1", name: "MiniMax M2.1", maxTokens: 8192, priority: 3 },
  { id: "deepseek-ai/deepseek-v3.1", name: "DeepSeek V3.1", maxTokens: 8192, priority: 4 },
  { id: "qwen/qwq-32b", name: "QwQ 32B", maxTokens: 8192, priority: 4 },
  { id: "nvidia/llama-3.1-nemotron-70b-instruct", name: "Nemotron 70B", maxTokens: 8192, priority: 4 },
  { id: "google/gemma-3-27b-it", name: "Gemma 3 27B", maxTokens: 8192, priority: 4 },
  { id: "microsoft/phi-4-mini-instruct", name: "Phi-4 Mini", maxTokens: 8192, priority: 5 },
];

// Time constants
export const COOLDOWN_BASE_MS = 60_000;
export const COOLDOWN_MAX_MS = 600_000;
export const LOCAL_AGENT_TIMEOUT_MS = 60 * 60 * 1000;
export const POST_COOLDOWN_MS = 4 * 60 * 60 * 1000;
export const BROWSE_COOLDOWN_MS = 25 * 60 * 1000;
