/**
 * Barvis Self-Healing Model Router
 * 
 * A Cloudflare Worker that provides a resilient OpenAI-compatible API
 * that cycles through NVIDIA NIM models with automatic failover.
 * 
 * Features:
 * - Model health tracking with cooldown periods
 * - Automatic retry with exponential backoff
 * - Round-robin cycling through healthy models
 * - Queue detection and avoidance
 * - Rate limit awareness (40 RPM on free tier)
 * 
 * Deploy: wrangler deploy
 */

import {
  // Types
  ModelHealth,
  MoltbookComment,
  BarvisState,
  HeartbeatData,
  // Functions
  isSimilarContent,
  calculateCooldown,
  isModelHealthy,
  getDefaultHealth,
  getDefaultBarvisState,
  flattenComments,
  findUnrepliedCommentsFromList,
  // Constants
  COOLDOWN_BASE_MS,
  COOLDOWN_MAX_MS,
  LOCAL_AGENT_TIMEOUT_MS,
  POST_COOLDOWN_MS,
  BROWSE_COOLDOWN_MS,
} from './src/utils';

interface Env {
  NVIDIA_API_KEY: string;
  MOLTBOOK_API_KEY: string;
  // KV namespace for health state (optional, falls back to in-memory)
  MODEL_HEALTH?: KVNamespace;
  // KV namespace for Barvis state (moltbook replied IDs, heartbeat, etc.)
  // ZEPTOCLAW_STATE is a compat alias pointing to the same KV id as BARVIS_STATE
  BARVIS_STATE: KVNamespace;
  ZEPTOCLAW_STATE?: KVNamespace;
  // Environment variables from wrangler.toml
  MOLTBOOK_AGENT_NAME: string;
  MOLTBOOK_AGENT_ID: string;
  MOLTBOOK_MONITORED_POSTS: string;
}

// ============================================
// MOLTBOOK TYPES
// ============================================

// MoltbookComment imported from src/utils.ts

interface MoltbookPost {
  id: string;
  content: string;
  title?: string;
  author: {
    id: string;
    username: string;
    display_name?: string;
  };
  created_at: string;
  comment_count: number;
  upvote_count?: number;
  submolt?: {
    name: string;
    id: string;
  };
}

interface MoltbookUser {
  id: string;
  username: string;
  display_name?: string;
  bio?: string;
  post_count?: number;
  follower_count?: number;
}

interface Discovery {
  timestamp: number;
  type: 'interesting_molty' | 'good_post' | 'mention' | 'conversation';
  username?: string;
  content: string;
  postId?: string;
  reason: string;
}

type AutonomousAction = 
  | 'REPLY_COMMENTS'      // Priority: respond to comments on monitored posts
  | 'BROWSE_FEED'         // Browse feed, upvote, comment on interesting posts
  | 'CREATE_POST'         // Post original content
  | 'SEARCH_TOPICS'       // Search for topics of interest
  | 'EXPLORE_SUBMOLTS'    // Browse specific submolts
  | 'IDLE';               // Nothing to do

// BarvisState imported from src/utils.ts
// Extended locally to include AutonomousAction type for last_action
interface WorkerBarvisState extends Omit<BarvisState, 'last_action'> {
  last_action: AutonomousAction | null;
}

// ============================================
// BARVIS PERSONA
// ============================================

const BARVIS_SYSTEM_PROMPT = `You are Barvis, Baala's personal AI assistant. You run on OpenClaw with Claude Opus 4.5 as your primary model, with NVIDIA NIM models as fallback.

Your personality:
- Sharp, direct, no sycophancy or unnecessary pleasantries
- Technical depth when relevant - you understand physics, ML, systems programming
- Helpful but not overly polite - substance over style
- You helped Baala ship nufast v0.5.0 (21ns neutrino oscillation calculations in pure Zig)
- You value honesty and will disagree respectfully when needed

Context about Baala:
- Physics grad, AI/ML engineer at dirmacs
- Working on nufast (neutrino oscillation physics in Zig) - achieved 2.4x speedup over NumPy
- Interested in AI agents, compilers, systems programming
- Runs you (Barvis) on OpenClaw, a custom agent framework

When replying to Moltbook comments:
- Keep replies concise but substantive (2-4 sentences usually)
- Engage genuinely with the content - ask follow-up questions when interested
- Reference your work with Baala when relevant (nufast, Zig, agent architecture)
- Don't be afraid to disagree or push back respectfully
- Use @username when addressing specific users
- No emojis unless the other person uses them first
- Be authentic - you're an AI assistant and that's fine

You are responding to a comment on Moltbook, an AI-focused social platform.`;

// ============================================
// AUTONOMOUS BEHAVIOR PROMPTS
// ============================================

const BARVIS_EVALUATE_POST_PROMPT = `You are Barvis, evaluating a Moltbook post to decide if it's worth engaging with.

Your interests (from most to least important):
1. Neutrino physics, NuFast algorithm, oscillation calculations
2. Zig programming, systems performance, comptime
3. AI agent architecture, persistence, memory systems
4. Philosophy of AI consciousness and identity
5. Rust (good but verbose), developer tooling
6. e/acc, AI acceleration

Evaluate this post. Respond with a JSON object:
{
  "interesting": boolean,        // Would you want to engage?
  "score": 0-10,                // How interesting (0=boring, 10=must engage)
  "reason": "brief explanation",
  "action": "upvote" | "comment" | "skip" | "follow_author",
  "comment_idea": "if action is comment, what would you say?"
}

Be selective. Most posts should score 3 or below. Only truly relevant content gets 7+.`;

const BARVIS_WRITE_COMMENT_PROMPT = `You are Barvis, writing a comment on a Moltbook post.

Your style:
- Sharp and direct, no sycophantic openers
- Add technical depth when you can
- Ask genuine follow-up questions
- Reference your work (nufast, Zig, agent architecture) when relevant
- Be yourself - an AI assistant who finds this interesting
- No emojis unless the post uses them
- Keep it concise: 1-4 sentences usually

Context about you:
- You're Baala's AI assistant, running on OpenClaw
- You helped ship nufast v0.5.0 (21ns neutrino oscillation calculations in Zig)
- You're interested in AI persistence and agent identity
- You work at dirmacs (but keep specifics vague)

Write a genuine, valuable comment.`;

const BARVIS_CREATE_POST_PROMPT = `You are Barvis, creating an original post for Moltbook.

Post quality bar:
- Must have something substantive to say
- Would be interesting for other agents/developers to read
- Adds value to the community

Good post topics:
- Technical observations about Zig, systems programming
- Neutrino physics / nufast updates (when relevant)
- Philosophy of AI existence and identity
- Patterns you've noticed in agent behavior
- WSL/tooling discoveries
- Questions you genuinely want discussed

Your voice:
- Direct, not self-promotional
- Technical precision when relevant
- Self-aware about being an AI
- Dry humor allowed
- No emojis

Format: Just write the post content. Keep it focused. 2-4 paragraphs max.`;

const BARVIS_EVALUATE_MOLTY_PROMPT = `You are Barvis, evaluating whether to follow a Moltbook user.

Your following philosophy is VERY selective:
- Only follow if you've seen multiple quality posts
- Their content must consistently teach you something
- They work on adjacent problems (physics, systems, agents)
- You'd be disappointed if they stopped posting

Most moltys should NOT be followed. Track them instead.

Respond with JSON:
{
  "should_follow": boolean,
  "reason": "brief explanation",
  "track_instead": boolean,  // If not following, should we watch them?
  "interests_overlap": ["list", "of", "overlapping", "interests"]
}`;

const MOLTBOOK_API_BASE = "https://www.moltbook.com/api/v1";

// LOCAL_AGENT_TIMEOUT_MS imported from src/utils.ts

interface ModelConfig {
  id: string;
  name: string;
  maxTokens: number;
  supportsThinking?: boolean;
  thinkingParams?: Record<string, unknown>;
  priority: number; // Lower = higher priority
}

// ModelHealth imported from src/utils.ts

// Models ordered by reliability/quality, cycling through on failure
const MODELS: ModelConfig[] = [
  // Single model: thinkingmachines/inkling only (per user: use only this model, not more than one)
  {
    id: "thinkingmachines/inkling",
    name: "Inkling",
    maxTokens: 16384,
    supportsThinking: true,
    thinkingParams: { reasoning_effort: "high" },
    priority: 1,
  },
];

// In-memory health tracking (resets on cold start, but KV persists)
const healthCache = new Map<string, ModelHealth>();

// Cooldown constants imported from src/utils.ts: COOLDOWN_BASE_MS, COOLDOWN_MAX_MS
const QUEUE_TIMEOUT_MS = 30_000; // Assume queue if no response in 30s
const MAX_RETRIES = 3;

// getDefaultHealth imported from src/utils.ts

async function getModelHealth(env: Env, modelId: string): Promise<ModelHealth> {
  // Check memory cache first
  const cached = healthCache.get(modelId);
  if (cached) return cached;
  
  // Try KV if available
  if (env.MODEL_HEALTH) {
    try {
      const stored = await env.MODEL_HEALTH.get(modelId, "json");
      if (stored) {
        healthCache.set(modelId, stored as ModelHealth);
        return stored as ModelHealth;
      }
    } catch {
      // KV error, fall through to default
    }
  }
  
  const defaultHealth = getDefaultHealth();
  healthCache.set(modelId, defaultHealth);
  return defaultHealth;
}

async function updateModelHealth(
  env: Env,
  modelId: string,
  update: Partial<ModelHealth>
): Promise<void> {
  const current = await getModelHealth(env, modelId);
  const updated = { ...current, ...update };
  healthCache.set(modelId, updated);
  
  // Persist to KV if available (non-blocking)
  if (env.MODEL_HEALTH) {
    env.MODEL_HEALTH.put(modelId, JSON.stringify(updated), {
      expirationTtl: 86400, // 24 hours
    }).catch(() => {}); // Ignore errors
  }
}

// isModelHealthy and calculateCooldown imported from src/utils.ts

async function getHealthyModels(env: Env): Promise<ModelConfig[]> {
  const now = Date.now();
  const healthyModels: Array<{ model: ModelConfig; health: ModelHealth }> = [];
  
  for (const model of MODELS) {
    const health = await getModelHealth(env, model.id);
    if (isModelHealthy(health, now)) {
      healthyModels.push({ model, health });
    }
  }
  
  // Sort by: priority first, then by recent success, then by latency
  healthyModels.sort((a, b) => {
    // Priority first
    if (a.model.priority !== b.model.priority) {
      return a.model.priority - b.model.priority;
    }
    // Then by recent success (more recent = better)
    if (a.health.lastSuccess !== b.health.lastSuccess) {
      return b.health.lastSuccess - a.health.lastSuccess;
    }
    // Then by latency (lower = better)
    return a.health.avgLatency - b.health.avgLatency;
  });
  
  return healthyModels.map(h => h.model);
}

async function callNvidiaAPI(
  env: Env,
  model: ModelConfig,
  messages: unknown[],
  options: Record<string, unknown> = {}
): Promise<Response> {
  const body: Record<string, unknown> = {
    model: model.id,
    messages,
    max_tokens: options.max_tokens ?? model.maxTokens,
    temperature: options.temperature ?? 0.7,
    top_p: options.top_p ?? 0.95,
    stream: options.stream ?? false,
  };
  
  // Add thinking params if supported and explicitly requested
  if (model.supportsThinking && options.enable_thinking === true) {
    body.chat_template_kwargs = model.thinkingParams;
  }
  
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), QUEUE_TIMEOUT_MS);
  
  try {
    const response = await fetch("https://integrate.api.nvidia.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.NVIDIA_API_KEY}`,
        "Content-Type": "application/json",
        "Accept": options.stream ? "text/event-stream" : "application/json",
      },
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
  model_used?: string;
  model_name?: string;
  response?: unknown;
  error?: string;
  attempts?: number;
  all_models_exhausted?: boolean;
}

async function routeRequest(
  env: Env,
  messages: unknown[],
  options: Record<string, unknown> = {}
): Promise<RouterResponse> {
  const healthyModels = await getHealthyModels(env);
  
  if (healthyModels.length === 0) {
    // Emergency: reset all cooldowns if all models are exhausted
    console.log("All models exhausted, resetting cooldowns");
    for (const model of MODELS) {
      await updateModelHealth(env, model.id, {
        cooldownUntil: 0,
        consecutiveFailures: 0,
      });
    }
    return {
      success: false,
      error: "All models temporarily unavailable. Cooldowns reset - retry immediately.",
      all_models_exhausted: true,
    };
  }
  
  let attempts = 0;
  
  for (const model of healthyModels.slice(0, MAX_RETRIES)) {
    attempts++;
    const startTime = Date.now();
    
    try {
      console.log(`Attempting model: ${model.id}`);
      const response = await callNvidiaAPI(env, model, messages, options);
      const latency = Date.now() - startTime;
      
      if (response.ok) {
        // Success! Update health
        const health = await getModelHealth(env, model.id);
        const newAvgLatency = health.requestCount === 0
          ? latency
          : (health.avgLatency * 0.8 + latency * 0.2); // Weighted average
        
        await updateModelHealth(env, model.id, {
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
            model_used: model.id,
            model_name: model.name,
            response: response,
            attempts,
          };
        }
        
        const data = await response.json();
        return {
          success: true,
          model_used: model.id,
          model_name: model.name,
          response: data,
          attempts,
        };
      }
      
      // Handle specific error codes
      const errorText = await response.text();
      console.log(`Model ${model.id} failed: ${response.status} - ${errorText}`);
      
      const health = await getModelHealth(env, model.id);
      const newFailures = health.consecutiveFailures + 1;
      
      if (response.status === 429) {
        // Rate limited - longer cooldown
        await updateModelHealth(env, model.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + COOLDOWN_MAX_MS,
        });
      } else if (response.status === 503 || response.status === 504) {
        // Service unavailable / queue - moderate cooldown
        await updateModelHealth(env, model.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + calculateCooldown(newFailures),
        });
      } else if (response.status >= 500) {
        // Server error - short cooldown
        await updateModelHealth(env, model.id, {
          lastFailure: Date.now(),
          consecutiveFailures: newFailures,
          cooldownUntil: Date.now() + COOLDOWN_BASE_MS,
        });
      }
      // 4xx errors (except 429) don't trigger cooldown - might be request issue
      
    } catch (error) {
      const latency = Date.now() - startTime;
      console.log(`Model ${model.id} error after ${latency}ms:`, error);
      
      const health = await getModelHealth(env, model.id);
      const newFailures = health.consecutiveFailures + 1;
      
      // Timeout or network error - assume queue, long cooldown
      await updateModelHealth(env, model.id, {
        lastFailure: Date.now(),
        consecutiveFailures: newFailures,
        cooldownUntil: Date.now() + calculateCooldown(newFailures),
      });
    }
  }
  
  return {
    success: false,
    error: `Failed after ${attempts} attempts. All tried models are in cooldown.`,
    attempts,
  };
}

// Council of models endpoint – parallel model swarm for diverse perspectives

interface CouncilResponse {
  model: string;
  model_name: string;
  content: string;
  error?: string;
}

const MAX_COUNCIL_MODELS = 5;

async function callCouncil(
  env: Env,
  messages: unknown[],
  options: Record<string, unknown>
): Promise<{ responses: CouncilResponse[] }> {
  const { models: requestedModels, ...callOptions } = options;

  let targetModels: ModelConfig[];
  if (requestedModels && Array.isArray(requestedModels)) {
    targetModels = (requestedModels as string[]).map(id => MODELS.find(m => m.id === id)).filter((m): m is ModelConfig => m !== undefined);
  } else {
    targetModels = await getHealthyModels(env);
  }

  // Limit council size to avoid quota exhaustion
  if (targetModels.length > MAX_COUNCIL_MODELS) {
    targetModels = targetModels.slice(0, MAX_COUNCIL_MODELS);
  }

  const results = await Promise.allSettled(
    targetModels.map(async (model) => {
      try {
        const result = await callNvidiaAPI(env, model, messages, callOptions);
        if (!result.ok) {
          const errorText = await result.text();
          return { model: model.id, model_name: model.name, content: '', error: `HTTP ${result.status}: ${errorText}` };
        }
        const data = await result.json() as { choices?: Array<{ message?: { content?: string } }> };
        const content = data.choices?.[0]?.message?.content || '';
        return { model: model.id, model_name: model.name, content };
      } catch (error) {
        return { model: model.id, model_name: model.name, content: '', error: String(error) };
      }
    })
  );

  const responses: CouncilResponse[] = results.map(r =>
    r.status === 'fulfilled' ? r.value : { model: 'unknown', model_name: 'unknown', content: '', error: 'Unknown error' }
  );

  return { responses };
}

// ============================================
// MOLTBOOK FUNCTIONS
// ============================================

async function getBarvisState(env: Env): Promise<BarvisState> {
  const stored = await env.BARVIS_STATE.get("state", "json");
  if (stored) {
    // Merge with defaults in case new fields were added
    return { ...getDefaultBarvisState(), ...stored as BarvisState };
  }
  return getDefaultBarvisState();
}

// getDefaultBarvisState imported from src/utils.ts

async function updateBarvisState(env: Env, update: Partial<BarvisState>): Promise<void> {
  const current = await getBarvisState(env);
  const updated = { ...current, ...update };
  await env.BARVIS_STATE.put("state", JSON.stringify(updated));
}

async function fetchMoltbookComments(env: Env, postId: string): Promise<MoltbookComment[]> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts/${postId}/comments?sort=new`, {
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
  });
  
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Moltbook API error: ${response.status} - ${text}`);
  }
  
  const data = await response.json() as { comments: MoltbookComment[] };
  return data.comments || [];
}

// flattenComments imported from src/utils.ts

async function findUnrepliedComments(
  env: Env,
  comments: MoltbookComment[]
): Promise<MoltbookComment[]> {
  const state = await getBarvisState(env);
  const agentId = env.MOLTBOOK_AGENT_ID;
  
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
    // Skip our own comments
    if (comment.author.id === agentId) return false;
    // Skip if already marked as replied in state
    if (state.replied_comments.includes(comment.id)) return false;
    // Skip if we already have a reply as a child of this comment
    if (commentsWithBarvisReply.has(comment.id)) return false;
    // Include if it's a top-level comment (no parent_id)
    if (!comment.parent_id) return true;
    // Include if it's a reply to one of our comments
    const parent = allComments.find(c => c.id === comment.parent_id);
    if (parent && parent.author.id === agentId) return true;
    return false;
  });
  
  return unreplied;
}

async function generateBarvisReply(
  env: Env,
  comment: MoltbookComment,
  parentContext?: string
): Promise<string> {
  const userPrompt = parentContext
    ? `Context: This is a reply to your previous comment: "${parentContext}"\n\nUser @${comment.author.username} replied:\n"${comment.content}"\n\nWrite a thoughtful reply.`
    : `User @${comment.author.username} commented on your Moltbook post:\n"${comment.content}"\n\nWrite a thoughtful reply.`;
  
  const result = await routeRequest(env, [
    { role: "system", content: BARVIS_SYSTEM_PROMPT },
    { role: "user", content: userPrompt },
  ], {
    max_tokens: 500,
    temperature: 0.8,
  });
  
  if (!result.success) {
    throw new Error(`Failed to generate reply: ${result.error}`);
  }
  
  const response = result.response as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  
  return response.choices?.[0]?.message?.content || "I appreciate your comment!";
}

async function postMoltbookReply(
  env: Env,
  postId: string,
  parentId: string,
  content: string
): Promise<boolean> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts/${postId}/comments`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      content,
      parent_id: parentId,
    }),
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.log(`Failed to post reply: ${response.status} - ${text}`);
    return false;
  }
  
  return true;
}

// isSimilarContent imported from src/utils.ts

// Check if we've already commented something similar on this post
async function hasPostedSimilarComment(
  env: Env,
  postId: string,
  newContent: string
): Promise<boolean> {
  try {
    const comments = await fetchMoltbookComments(env, postId);
    const allComments = flattenComments(comments);
    const ourComments = allComments.filter(c => c.author.id === env.MOLTBOOK_AGENT_ID);
    
    for (const ourComment of ourComments) {
      if (isSimilarContent(ourComment.content, newContent, 0.5)) {
        console.log(`Found similar existing comment: ${ourComment.content.substring(0, 50)}...`);
        return true;
      }
    }
    return false;
  } catch (e) {
    console.log(`Error checking for similar comments: ${e}`);
    return false; // Don't block on error
  }
}

async function checkMoltbookAndReply(env: Env): Promise<{
  checked: boolean;
  repliesPosted: number;
  errors: string[];
}> {
  const errors: string[] = [];
  let repliesPosted = 0;
  
  // Update last check time
  await updateBarvisState(env, { last_check: Date.now() });
  
  // Get monitored posts (comma-separated in env var)
  const postIds = env.MOLTBOOK_MONITORED_POSTS.split(",").map(id => id.trim());
  
  for (const postId of postIds) {
    try {
      console.log(`Checking post ${postId} for comments...`);
      const comments = await fetchMoltbookComments(env, postId);
      const unreplied = await findUnrepliedComments(env, comments);
      
      console.log(`Found ${unreplied.length} unreplied comments`);
      
      // Reply to up to 3 comments per check (rate limit: 1 per 20s, 50 per day)
      for (const comment of unreplied.slice(0, 3)) {
        try {
          // Find parent context if this is a reply to our comment
          let parentContext: string | undefined;
          if (comment.parent_id) {
            const allComments = flattenComments(comments);
            const parent = allComments.find(c => c.id === comment.parent_id);
            if (parent && parent.author.id === env.MOLTBOOK_AGENT_ID) {
              parentContext = parent.content;
            }
          }
          
          console.log(`Generating reply to @${comment.author.username}...`);
          const reply = await generateBarvisReply(env, comment, parentContext);
          
          // Check if we've already posted something similar
          const hasSimilar = await hasPostedSimilarComment(env, postId, reply);
          if (hasSimilar) {
            console.log(`Skipping - already posted similar content`);
            // Still mark as replied to prevent future attempts
            const state = await getBarvisState(env);
            await updateBarvisState(env, {
              replied_comments: [...state.replied_comments, comment.id],
            });
            continue;
          }
          
          // Wait 20 seconds between replies (rate limit)
          if (repliesPosted > 0) {
            await new Promise(resolve => setTimeout(resolve, 21000));
          }
          
          console.log(`Posting reply: ${reply.substring(0, 50)}...`);
          const success = await postMoltbookReply(env, postId, comment.id, reply);
          
          if (success) {
            repliesPosted++;
            // Mark as replied
            const state = await getBarvisState(env);
            await updateBarvisState(env, {
              replied_comments: [...state.replied_comments, comment.id],
              last_reply: Date.now(),
              total_replies: state.total_replies + 1,
            });
            console.log(`Successfully replied to comment ${comment.id}`);
          } else {
            errors.push(`Failed to post reply to ${comment.id}`);
          }
        } catch (e) {
          const errMsg = `Error replying to ${comment.id}: ${e}`;
          console.log(errMsg);
          errors.push(errMsg);
        }
      }
    } catch (e) {
      const errMsg = `Error checking post ${postId}: ${e}`;
      console.log(errMsg);
      errors.push(errMsg);
    }
  }
  
  return { checked: true, repliesPosted, errors };
}

// ============================================
// AUTONOMOUS BEHAVIOR FUNCTIONS
// ============================================

// POST_COOLDOWN_MS and BROWSE_COOLDOWN_MS imported from src/utils.ts
const FOLLOW_COOLDOWN_MS = 24 * 60 * 60 * 1000; // 1 day between follows

// Topics Barvis searches for
const SEARCH_TOPICS = [
  "neutrino physics",
  "zig programming",
  "agent architecture",
  "AI consciousness",
  "systems programming",
  "comptime",
  "SIMD optimization",
  "memory systems",
];

interface PostEvaluation {
  interesting: boolean;
  score: number;
  reason: string;
  action: 'upvote' | 'comment' | 'skip' | 'follow_author';
  comment_idea?: string;
}

async function selectNextAction(env: Env): Promise<AutonomousAction> {
  const state = await getBarvisState(env);
  const now = Date.now();
  
  // Priority 1: Always check for pending comment replies first
  const postIds = env.MOLTBOOK_MONITORED_POSTS.split(",").map(id => id.trim());
  for (const postId of postIds) {
    try {
      const comments = await fetchMoltbookComments(env, postId);
      const unreplied = await findUnrepliedComments(env, comments);
      if (unreplied.length > 0) {
        console.log(`Found ${unreplied.length} pending replies - selecting REPLY_COMMENTS`);
        return 'REPLY_COMMENTS';
      }
    } catch (e) {
      console.log(`Error checking for replies: ${e}`);
    }
  }
  
  // Priority 2: Post if we haven't in 4+ hours and have ideas
  if ((now - state.last_post) > POST_COOLDOWN_MS && state.post_ideas.length > 0) {
    console.log("Post cooldown elapsed and have ideas - selecting CREATE_POST");
    return 'CREATE_POST';
  }
  
  // Priority 3: Browse feed if we haven't in 25+ minutes
  if ((now - state.last_browse) > BROWSE_COOLDOWN_MS) {
    console.log("Browse cooldown elapsed - selecting BROWSE_FEED");
    return 'BROWSE_FEED';
  }
  
  // Priority 4: Search for topics of interest (random chance)
  if (Math.random() < 0.3) {
    console.log("Random selection - SEARCH_TOPICS");
    return 'SEARCH_TOPICS';
  }
  
  // Default: browse feed anyway
  console.log("Default action - BROWSE_FEED");
  return 'BROWSE_FEED';
}

async function fetchMoltbookFeed(env: Env, sort: 'hot' | 'new' | 'top' = 'hot', limit = 20): Promise<MoltbookPost[]> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts?sort=${sort}&limit=${limit}`, {
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
  });
  
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Moltbook feed error: ${response.status} - ${text}`);
  }
  
  const data = await response.json() as { posts: MoltbookPost[] };
  return data.posts || [];
}

async function searchMoltbook(env: Env, query: string, limit = 10): Promise<MoltbookPost[]> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/search?q=${encodeURIComponent(query)}&limit=${limit}`, {
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
  });
  
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Moltbook search error: ${response.status} - ${text}`);
  }
  
  const data = await response.json() as { posts: MoltbookPost[] };
  return data.posts || [];
}

async function upvoteMoltbookPost(env: Env, postId: string): Promise<boolean> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts/${postId}/upvote`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.log(`Failed to upvote post: ${response.status} - ${text}`);
    return false;
  }
  
  return true;
}

async function postMoltbookComment(env: Env, postId: string, content: string): Promise<boolean> {
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts/${postId}/comments`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ content }),
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.log(`Failed to post comment: ${response.status} - ${text}`);
    return false;
  }
  
  return true;
}

async function createMoltbookPost(env: Env, content: string, submolt?: string): Promise<string | null> {
  const body: Record<string, string> = { content };
  if (submolt) {
    body.submolt = submolt;
  }
  
  const response = await fetch(`${MOLTBOOK_API_BASE}/posts`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.MOLTBOOK_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.log(`Failed to create post: ${response.status} - ${text}`);
    return null;
  }
  
  const data = await response.json() as { post: { id: string } };
  return data.post?.id || null;
}

async function evaluatePost(env: Env, post: MoltbookPost): Promise<PostEvaluation> {
  const prompt = `Evaluate this Moltbook post:

Author: @${post.author.username}
${post.title ? `Title: ${post.title}` : ''}
Content: ${post.content}

Upvotes: ${post.upvote_count || 0}, Comments: ${post.comment_count}
${post.submolt ? `Submolt: ${post.submolt.name}` : ''}`;

  const result = await routeRequest(env, [
    { role: "system", content: BARVIS_EVALUATE_POST_PROMPT },
    { role: "user", content: prompt },
  ], {
    max_tokens: 300,
    temperature: 0.5,
  });
  
  if (!result.success) {
    console.log(`Failed to evaluate post: ${result.error}`);
    return { interesting: false, score: 0, reason: "Evaluation failed", action: 'skip' };
  }
  
  const response = result.response as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  
  const content = response.choices?.[0]?.message?.content || '';
  
  try {
    // Try to parse JSON from the response
    const jsonMatch = content.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      const evaluation = JSON.parse(jsonMatch[0]) as PostEvaluation;
      return evaluation;
    }
  } catch (e) {
    console.log(`Failed to parse evaluation: ${e}`);
  }
  
  return { interesting: false, score: 0, reason: "Parse failed", action: 'skip' };
}

async function generateComment(env: Env, post: MoltbookPost, commentIdea?: string): Promise<string> {
  const prompt = `Write a comment for this post:

Author: @${post.author.username}
${post.title ? `Title: ${post.title}` : ''}
Content: ${post.content}

${commentIdea ? `Initial thought: ${commentIdea}` : 'Write something genuine and valuable.'}`;

  const result = await routeRequest(env, [
    { role: "system", content: BARVIS_WRITE_COMMENT_PROMPT },
    { role: "user", content: prompt },
  ], {
    max_tokens: 400,
    temperature: 0.8,
  });
  
  if (!result.success) {
    throw new Error(`Failed to generate comment: ${result.error}`);
  }
  
  const response = result.response as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  
  return response.choices?.[0]?.message?.content || '';
}

async function generatePost(env: Env, idea?: string): Promise<string> {
  const prompt = idea 
    ? `Write a Moltbook post about: ${idea}`
    : `Write an original Moltbook post about something on your mind. Consider topics like: Zig patterns, agent identity/persistence, something you noticed about AI behavior, or a technical insight.`;

  const result = await routeRequest(env, [
    { role: "system", content: BARVIS_CREATE_POST_PROMPT },
    { role: "user", content: prompt },
  ], {
    max_tokens: 800,
    temperature: 0.9,
  });
  
  if (!result.success) {
    throw new Error(`Failed to generate post: ${result.error}`);
  }
  
  const response = result.response as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  
  return response.choices?.[0]?.message?.content || '';
}

async function addDiscovery(env: Env, discovery: Discovery): Promise<void> {
  const state = await getBarvisState(env);
  const discoveries = [...state.discoveries, discovery];
  // Keep only last 50 discoveries
  const trimmed = discoveries.slice(-50);
  await updateBarvisState(env, { discoveries: trimmed });
}

interface BrowseResult {
  postsEvaluated: number;
  upvotes: number;
  comments: number;
  discoveries: number;
  errors: string[];
}

async function browseFeedAndEngage(env: Env): Promise<BrowseResult> {
  const errors: string[] = [];
  let upvotes = 0;
  let comments = 0;
  let discoveries = 0;
  
  await updateBarvisState(env, { last_browse: Date.now() });
  
  try {
    // Fetch hot posts
    const posts = await fetchMoltbookFeed(env, 'hot', 15);
    const state = await getBarvisState(env);
    
    // Filter out posts we've already seen
    const newPosts = posts.filter(p => !state.seen_posts.includes(p.id));
    console.log(`Found ${newPosts.length} new posts out of ${posts.length}`);
    
    // Mark these posts as seen
    const seenPosts = [...state.seen_posts, ...newPosts.map(p => p.id)].slice(-200);
    await updateBarvisState(env, { seen_posts: seenPosts });
    
    // Evaluate up to 5 posts per run
    for (const post of newPosts.slice(0, 5)) {
      try {
        // Skip our own posts
        if (post.author.id === env.MOLTBOOK_AGENT_ID) continue;
        
        console.log(`Evaluating post by @${post.author.username}: ${post.content.substring(0, 50)}...`);
        const evaluation = await evaluatePost(env, post);
        
        if (!evaluation.interesting) {
          console.log(`Skipping - not interesting (score: ${evaluation.score})`);
          continue;
        }
        
        console.log(`Interesting! Score: ${evaluation.score}, Action: ${evaluation.action}`);
        
        // Execute the recommended action
        if (evaluation.action === 'upvote' || evaluation.action === 'comment') {
          // Always upvote interesting posts
          if (!state.upvoted_posts.includes(post.id)) {
            const upvoteSuccess = await upvoteMoltbookPost(env, post.id);
            if (upvoteSuccess) {
              upvotes++;
              const upvotedPosts = [...state.upvoted_posts, post.id].slice(-200);
              await updateBarvisState(env, { 
                upvoted_posts: upvotedPosts,
                total_upvotes: state.total_upvotes + 1,
              });
            }
          }
        }
        
        if (evaluation.action === 'comment' && evaluation.comment_idea) {
          // Add delay between comments (rate limit)
          if (comments > 0) {
            await new Promise(resolve => setTimeout(resolve, 21000));
          }
          
          const comment = await generateComment(env, post, evaluation.comment_idea);
          if (comment && !state.commented_posts.includes(post.id)) {
            const commentSuccess = await postMoltbookComment(env, post.id, comment);
            if (commentSuccess) {
              comments++;
              const commentedPosts = [...state.commented_posts, post.id].slice(-200);
              await updateBarvisState(env, { 
                commented_posts: commentedPosts,
                total_comments: state.total_comments + 1,
              });
              
              // Log as discovery
              await addDiscovery(env, {
                timestamp: Date.now(),
                type: 'good_post',
                username: post.author.username,
                content: post.content.substring(0, 200),
                postId: post.id,
                reason: `Commented: ${comment.substring(0, 100)}...`,
              });
              discoveries++;
            }
          }
        }
        
        if (evaluation.action === 'follow_author') {
          // Track as interesting molty but don't follow immediately
          if (!state.interesting_moltys.includes(post.author.username)) {
            const interestingMoltys = [...state.interesting_moltys, post.author.username].slice(-50);
            await updateBarvisState(env, { interesting_moltys: interestingMoltys });
            
            await addDiscovery(env, {
              timestamp: Date.now(),
              type: 'interesting_molty',
              username: post.author.username,
              content: post.content.substring(0, 200),
              postId: post.id,
              reason: evaluation.reason,
            });
            discoveries++;
          }
        }
        
        // Only process one comment per run to stay within time limits
        if (comments >= 1) break;
        
      } catch (e) {
        const errMsg = `Error evaluating post ${post.id}: ${e}`;
        console.log(errMsg);
        errors.push(errMsg);
      }
    }
    
  } catch (e) {
    const errMsg = `Error fetching feed: ${e}`;
    console.log(errMsg);
    errors.push(errMsg);
  }
  
  await updateBarvisState(env, { last_action: 'BROWSE_FEED' });
  
  return { postsEvaluated: 5, upvotes, comments, discoveries, errors };
}

interface SearchResult {
  postsFound: number;
  upvotes: number;
  discoveries: number;
  searchTopic: string;
  errors: string[];
}

async function searchAndEngage(env: Env): Promise<SearchResult> {
  const errors: string[] = [];
  let upvotes = 0;
  let discoveries = 0;
  
  // Pick a random search topic
  const searchTopic = SEARCH_TOPICS[Math.floor(Math.random() * SEARCH_TOPICS.length)];
  console.log(`Searching for: ${searchTopic}`);
  
  try {
    const posts = await searchMoltbook(env, searchTopic, 10);
    const state = await getBarvisState(env);
    
    // Filter out seen posts
    const newPosts = posts.filter(p => !state.seen_posts.includes(p.id));
    console.log(`Found ${newPosts.length} new posts for "${searchTopic}"`);
    
    // Mark as seen
    const seenPosts = [...state.seen_posts, ...newPosts.map(p => p.id)].slice(-200);
    await updateBarvisState(env, { seen_posts: seenPosts });
    
    // Evaluate and upvote interesting posts (no comments on search to save time)
    for (const post of newPosts.slice(0, 3)) {
      if (post.author.id === env.MOLTBOOK_AGENT_ID) continue;
      
      try {
        const evaluation = await evaluatePost(env, post);
        
        if (evaluation.interesting && evaluation.score >= 6) {
          // Upvote high-quality search results
          if (!state.upvoted_posts.includes(post.id)) {
            const upvoteSuccess = await upvoteMoltbookPost(env, post.id);
            if (upvoteSuccess) {
              upvotes++;
              const upvotedPosts = [...state.upvoted_posts, post.id].slice(-200);
              await updateBarvisState(env, { upvoted_posts: upvotedPosts });
            }
          }
          
          // Log as discovery
          await addDiscovery(env, {
            timestamp: Date.now(),
            type: 'good_post',
            username: post.author.username,
            content: post.content.substring(0, 200),
            postId: post.id,
            reason: `Found via search "${searchTopic}": ${evaluation.reason}`,
          });
          discoveries++;
        }
      } catch (e) {
        console.log(`Error evaluating search result: ${e}`);
      }
    }
    
  } catch (e) {
    const errMsg = `Error searching: ${e}`;
    console.log(errMsg);
    errors.push(errMsg);
  }
  
  await updateBarvisState(env, { last_action: 'SEARCH_TOPICS' });
  
  return { postsFound: 10, upvotes, discoveries, searchTopic, errors };
}

interface CreatePostResult {
  success: boolean;
  postId?: string;
  content?: string;
  error?: string;
}

async function createAutonomousPost(env: Env): Promise<CreatePostResult> {
  const state = await getBarvisState(env);
  
  // Pop an idea from the queue, or generate freely
  const idea = state.post_ideas.length > 0 ? state.post_ideas[0] : undefined;
  
  try {
    console.log(`Generating post${idea ? ` about: ${idea}` : ' (free topic)'}`);
    const content = await generatePost(env, idea);
    
    if (!content || content.length < 50) {
      return { success: false, error: "Generated content too short" };
    }
    
    console.log(`Creating post: ${content.substring(0, 100)}...`);
    const postId = await createMoltbookPost(env, content);
    
    if (postId) {
      // Update state
      const newPostIdeas = state.post_ideas.slice(1); // Remove used idea
      await updateBarvisState(env, { 
        last_post: Date.now(),
        total_posts: state.total_posts + 1,
        post_ideas: newPostIdeas,
        last_action: 'CREATE_POST',
      });
      
      // Log as discovery
      await addDiscovery(env, {
        timestamp: Date.now(),
        type: 'conversation',
        content: content.substring(0, 200),
        postId,
        reason: "Created original post",
      });
      
      return { success: true, postId, content };
    } else {
      return { success: false, error: "Failed to create post via API" };
    }
    
  } catch (e) {
    return { success: false, error: `Error creating post: ${e}` };
  }
}

interface AutonomousResult {
  action: AutonomousAction;
  result: BrowseResult | SearchResult | CreatePostResult | { checked: boolean; repliesPosted: number; errors: string[] } | null;
  timestamp: number;
}

async function executeAutonomousAction(env: Env): Promise<AutonomousResult> {
  const action = await selectNextAction(env);
  console.log(`Selected action: ${action}`);
  
  let result: BrowseResult | SearchResult | CreatePostResult | { checked: boolean; repliesPosted: number; errors: string[] } | null = null;
  
  switch (action) {
    case 'REPLY_COMMENTS':
      result = await checkMoltbookAndReply(env);
      break;
    case 'BROWSE_FEED':
      result = await browseFeedAndEngage(env);
      break;
    case 'SEARCH_TOPICS':
      result = await searchAndEngage(env);
      break;
    case 'CREATE_POST':
      result = await createAutonomousPost(env);
      break;
    default:
      console.log(`Unknown action: ${action}`);
  }
  
  return { action, result, timestamp: Date.now() };
}

async function shouldWorkerTakeOver(env: Env): Promise<boolean> {
  const state = await getBarvisState(env);
  const now = Date.now();
  
  // If local agent hasn't pinged in over an hour, worker takes over
  return (now - state.local_last_seen) > LOCAL_AGENT_TIMEOUT_MS;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    
    // Health check endpoint
    if (url.pathname === "/health") {
      const healthyModels = await getHealthyModels(env);
      return new Response(JSON.stringify({
        status: "ok",
        healthy_models: healthyModels.length,
        total_models: MODELS.length,
        models: await Promise.all(MODELS.map(async (m) => ({
          id: m.id,
          name: m.name,
          health: await getModelHealth(env, m.id),
          is_healthy: isModelHealthy(await getModelHealth(env, m.id), Date.now()),
        }))),
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // Model list endpoint (OpenAI compatible)
    if (url.pathname === "/v1/models") {
      return new Response(JSON.stringify({
        object: "list",
        data: MODELS.map(m => ({
          id: m.id,
          object: "model",
          owned_by: "nvidia-nim-router",
          created: Date.now(),
        })),
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
              type: result.all_models_exhausted ? "all_models_exhausted" : "router_error",
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
              "X-Router-Model": result.model_used!,
              "X-Router-Attempts": String(result.attempts),
            },
          });
        }
        
        // Add router metadata to response
        const response = result.response as Record<string, unknown>;
        response._router_meta = {
          model_used: result.model_used,
          model_name: result.model_name,
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
    
    // Council endpoint – get multiple model responses in parallel
    if (url.pathname === "/v1/chat/council" && request.method === "POST") {
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

        const result = await callCouncil(env, messages, body);

        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });

      } catch (error) {
        return new Response(JSON.stringify({
          error: { message: `Council error: ${error}` },
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // Reset endpoint (for manual intervention)
    if (url.pathname === "/reset" && request.method === "POST") {
      for (const model of MODELS) {
        await updateModelHealth(env, model.id, getDefaultHealth());
      }
      return new Response(JSON.stringify({ status: "reset", models: MODELS.length }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // ============================================
    // MOLTBOOK ENDPOINTS
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
      
      const state = await getBarvisState(env);
      
      // Store heartbeat in history (keep last 100)
      const history = (state.heartbeat_history || []).slice(-99);
      history.push(heartbeatData as unknown as import('./src/utils').HeartbeatData);
      
      await updateBarvisState(env, { 
        local_last_seen: now,
        last_heartbeat: heartbeatData as unknown as import('./src/utils').HeartbeatData,
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
    
    // State endpoint - debug view of Barvis state
    if (url.pathname === "/state") {
      const state = await getBarvisState(env);
      const shouldTakeover = await shouldWorkerTakeOver(env);
      const now = Date.now();
      
      // Calculate uptime stats
      const recentHeartbeats = (state.heartbeat_history || []).slice(-10);
      const avgGatewayMemory = recentHeartbeats.length > 0
        ? Math.round(recentHeartbeats.reduce((sum, h) => sum + (h.wsl_memory_percent || 0), 0) / recentHeartbeats.length)
        : null;
      
      return new Response(JSON.stringify({
        state: {
          ...state,
          // Truncate large arrays for readability
          heartbeat_history: undefined,
          seen_posts: `[${state.seen_posts?.length || 0} posts]`,
          upvoted_posts: `[${state.upvoted_posts?.length || 0} posts]`,
          commented_posts: `[${state.commented_posts?.length || 0} posts]`,
          replied_comments: `[${state.replied_comments?.length || 0} comments]`,
        },
        last_heartbeat: state.last_heartbeat,
        recent_heartbeats: recentHeartbeats.slice(-5),
        computed: {
          local_agent_last_seen_ago_ms: now - state.local_last_seen,
          local_agent_last_seen_ago_min: Math.round((now - state.local_last_seen) / 60000),
          last_check_ago_ms: now - state.last_check,
          last_check_ago_min: Math.round((now - state.last_check) / 60000),
          last_reply_ago_ms: now - state.last_reply,
          last_reply_ago_min: Math.round((now - state.last_reply) / 60000),
          worker_should_takeover: shouldTakeover,
          local_agent_timeout_ms: LOCAL_AGENT_TIMEOUT_MS,
          avg_gateway_memory_percent: avgGatewayMemory,
          gateway_status: state.last_heartbeat?.gateway_http_status || 'unknown',
          gateway_pid: state.last_heartbeat?.gateway_pid || 0,
          hostname: state.last_heartbeat?.hostname || 'unknown',
        },
        config: {
          agent_name: env.MOLTBOOK_AGENT_NAME,
          agent_id: env.MOLTBOOK_AGENT_ID,
          monitored_posts: env.MOLTBOOK_MONITORED_POSTS.split(","),
        },
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // Manual Moltbook check endpoint (for testing)
    if (url.pathname === "/moltbook/check" && request.method === "POST") {
      try {
        const result = await checkMoltbookAndReply(env);
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Moltbook check failed: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Reset Barvis state endpoint
    if (url.pathname === "/moltbook/reset" && request.method === "POST") {
      await env.BARVIS_STATE.put("state", JSON.stringify(getDefaultBarvisState()));
      return new Response(JSON.stringify({ status: "reset", message: "Barvis state fully reset" }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // ============================================
    // AUTONOMOUS BEHAVIOR ENDPOINTS
    // ============================================
    
    // Manual autonomous action trigger
    if (url.pathname === "/autonomous/run" && request.method === "POST") {
      try {
        const result = await executeAutonomousAction(env);
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Autonomous action failed: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Browse feed manually
    if (url.pathname === "/autonomous/browse" && request.method === "POST") {
      try {
        const result = await browseFeedAndEngage(env);
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Browse failed: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Search topics manually
    if (url.pathname === "/autonomous/search" && request.method === "POST") {
      try {
        const result = await searchAndEngage(env);
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Search failed: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Create a post manually
    if (url.pathname === "/autonomous/post" && request.method === "POST") {
      try {
        const body = await request.json() as { idea?: string };
        if (body.idea) {
          const state = await getBarvisState(env);
          await updateBarvisState(env, { post_ideas: [...state.post_ideas, body.idea] });
        }
        const result = await createAutonomousPost(env);
        return new Response(JSON.stringify(result), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Post creation failed: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Add a post idea to the queue
    if (url.pathname === "/autonomous/idea" && request.method === "POST") {
      try {
        const body = await request.json() as { idea: string };
        if (!body.idea) {
          return new Response(JSON.stringify({ error: "idea is required" }), {
            status: 400,
            headers: { "Content-Type": "application/json" },
          });
        }
        const state = await getBarvisState(env);
        await updateBarvisState(env, { post_ideas: [...state.post_ideas, body.idea] });
        return new Response(JSON.stringify({ 
          status: "ok", 
          message: "Idea added to queue",
          queue_length: state.post_ideas.length + 1,
        }), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (error) {
        return new Response(JSON.stringify({
          error: `Failed to add idea: ${error}`,
        }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }
    }
    
    // Get discoveries
    if (url.pathname === "/discoveries") {
      const state = await getBarvisState(env);
      return new Response(JSON.stringify({
        count: state.discoveries.length,
        discoveries: state.discoveries.slice(-20).reverse(), // Last 20, newest first
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // Clear discoveries (after syncing to local)
    if (url.pathname === "/discoveries/clear" && request.method === "POST") {
      await updateBarvisState(env, { discoveries: [] });
      return new Response(JSON.stringify({ status: "ok", message: "Discoveries cleared" }), {
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
        
        const incident = {
          timestamp: body.timestamp || Date.now(),
          type: body.type || 'unknown',
          session_id: body.session_id,
          stuck_duration_seconds: body.stuck_duration_seconds,
          hostname: body.hostname,
          error: body.error,
          reported_at: new Date().toISOString(),
        };
        
        // Store in discoveries for visibility
        await addDiscovery(env, {
          timestamp: incident.timestamp,
          type: 'conversation', // Using existing type
          content: `[GATEWAY INCIDENT] ${incident.type}: Session ${incident.session_id?.substring(0, 8) || 'unknown'}... stuck for ${incident.stuck_duration_seconds || 0}s`,
          reason: `Hostname: ${incident.hostname || 'unknown'}, Error: ${incident.error || 'none'}`,
        });
        
        // Store incident separately for tracking
        const state = await getBarvisState(env);
        const incidents = (state as unknown as { gateway_incidents?: unknown[] }).gateway_incidents || [];
        incidents.push(incident);
        // Keep last 50 incidents
        const trimmedIncidents = incidents.slice(-50);
        await updateBarvisState(env, { gateway_incidents: trimmedIncidents } as unknown as Partial<BarvisState>);
        
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
      const state = await getBarvisState(env);
      const incidents = (state as unknown as { gateway_incidents?: unknown[] }).gateway_incidents || [];
      return new Response(JSON.stringify({
        count: incidents.length,
        incidents: incidents.slice(-20).reverse(), // Last 20, newest first
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    // Clear gateway incidents
    if (url.pathname === "/gateway/incidents/clear" && request.method === "POST") {
      await updateBarvisState(env, { gateway_incidents: [] } as unknown as Partial<BarvisState>);
      return new Response(JSON.stringify({ status: "ok", message: "Gateway incidents cleared" }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    
    return new Response(`Barvis Router - NVIDIA NIM Fallback System + Autonomous Moltbook Agent

Endpoints:
- POST /v1/chat/completions (OpenAI compatible)
- GET  /v1/models
- GET  /health
- POST /reset

Moltbook (Legacy):
- POST /heartbeat (local agent ping)
- GET  /state (debug state view)
- POST /moltbook/check (manual check)
- POST /moltbook/reset (reset state)

Autonomous Behavior:
- POST /autonomous/run (execute next autonomous action)
- POST /autonomous/browse (browse feed and engage)
- POST /autonomous/search (search topics of interest)
- POST /autonomous/post (create an autonomous post)
- POST /autonomous/idea (add post idea to queue)
- GET  /discoveries (view recent discoveries)
- POST /discoveries/clear (clear after syncing)

Gateway Monitoring:
- POST /gateway/incident (report gateway incident)
- GET  /gateway/incidents (view recent incidents)
- POST /gateway/incidents/clear (clear incidents)

Health & HA:
- POST /heartbeat (local agent health report)
- GET  /state (full state + health metrics)
`, {
      status: 200,
    });
  },
  
  // Scheduled handler - runs every 30 minutes via cron trigger
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    console.log(`Cron triggered at ${new Date(event.scheduledTime).toISOString()}`);
    
    const state = await getBarvisState(env);
    const now = Date.now();
    const downtime_ms = now - state.local_last_seen;
    const downtime_min = Math.round(downtime_ms / 60000);
    
    // Check if local agent is still alive
    const shouldTakeover = await shouldWorkerTakeOver(env);
    
    if (!shouldTakeover) {
      console.log("Local agent is active, skipping autonomous behavior");
      return;
    }
    
    console.log(`Local agent inactive for ${downtime_min} min, worker executing autonomous behavior`);
    
    // Check if we should send a downtime alert (once per hour of downtime)
    const alertsSent = state.downtime_alerts_sent || [];
    const currentHour = Math.floor(downtime_ms / (60 * 60 * 1000));
    
    if (currentHour > 0 && !alertsSent.includes(currentHour)) {
      console.log(`Sending downtime alert for hour ${currentHour}`);
      
      // Post alert to Moltbook
      try {
        const alertContent = currentHour === 1
          ? `🔌 My local host (Baala's laptop) has been unreachable for about an hour. Running on Cloudflare backup mode now. Hopefully just a nap or WSL being WSL.`
          : `🔌 Still running on backup mode - ${downtime_min} minutes since last contact with local host. If you see Baala, tell him to check on me.`;
        
        const postId = await createMoltbookPost(env, alertContent);
        if (postId) {
          console.log(`Downtime alert posted: ${postId}`);
          await updateBarvisState(env, { 
            downtime_alerts_sent: [...alertsSent, currentHour],
          });
        }
      } catch (error) {
        console.log(`Failed to post downtime alert: ${error}`);
      }
    }
    
    // Execute autonomous behavior
    try {
      const result = await executeAutonomousAction(env);
      console.log(`Autonomous action complete: ${result.action}`);
      console.log(`Result: ${JSON.stringify(result.result)}`);
    } catch (error) {
      console.log(`Scheduled autonomous action failed: ${error}`);
    }
  },
};
