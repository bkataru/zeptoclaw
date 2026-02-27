---
name: discovery
version: 1.0.0
description: Interesting finds aggregation — track repos, articles, tools discovered during heartbeats, browsing, or conversations.
author: Baala Kataru
category: productivity
triggers:
  - type: command
    commands:
      - "discovery"
      - "finds"
      - "interesting"
  - type: pattern
    patterns:
      - ".*interesting.*"
      - ".*found.*"
      - ".*discovered.*"
config:
  properties:
    data_file:
      type: string
      default: "memory/interesting-finds.json"
      description: "Path to the discoveries data file"
    max_finds:
      type: integer
      default: 100
      description: "Maximum number of finds to keep"
    auto_share_threshold:
      type: integer
      default: null
      description: "Auto-share finds after this many days (null = disabled)"
  required: []
---

# Discovery - Interesting Finds Aggregation

A simple system for tracking interesting discoveries (repos, articles, tools) found during heartbeats, browsing, or conversations.

## Overview

Barvis discovers interesting things while:
- Checking GitHub stars/notifications
- Browsing Moltbook
- Web searches during conversations
- Random exploration

This system tracks them so they can be reviewed and shared with Baala.

## Data File

**Location:** `memory/interesting-finds.json`

```json
{
  "finds": [
    {
      "id": "uuid",
      "type": "repo|article|tool|other",
      "title": "Name",
      "url": "https://...",
      "description": "Why it's interesting",
      "tags": ["zig", "mcp", "etc"],
      "foundAt": "ISO timestamp",
      "source": "github-stars|web-search|moltbook|manual",
      "shared": false,
      "sharedAt": null
    }
  ],
  "config": {
    "maxFinds": 100,
    "autoShareThreshold": null
  }
}
```

## Commands

### `discovery add <title> --url <url> --type <type> --tags <tags> --why <description>`

Add a new discovery.

**Example:**
```
discovery add "zigtools/zls" \
  --url "https://github.com/zigtools/zls" \
  --type repo \
  --tags "zig,lsp,tooling" \
  --why "Zig Language Server - essential for Zig development"
```

**Response:**
```
Added discovery: zigtools/zls
ID: 550e8400-e29b-41d4-a716-446655440000
```

### `discovery list [--unshared]`

List discoveries. Use `--unshared` to show only finds not yet shared with Baala.

**Example:**
```
discovery list
```

**Response:**
```
Recent discoveries (5 total):

1. zigtools/zls [repo]
   URL: https://github.com/zigtools/zls
   Tags: zig, lsp, tooling
   Found: 2024-02-04T12:00:00Z
   Source: github-stars
   Why: Zig Language Server - essential for Zig development
   Shared: No

2. cool-article [article]
   URL: https://example.com/article
   Tags: ai, llm
   Found: 2024-02-03T10:30:00Z
   Source: web-search
   Why: Interesting perspective on LLM scaling
   Shared: Yes
```

### `discovery search <query>`

Search discoveries by title, description, or tags.

**Example:**
```
discovery search "zig"
```

**Response:**
```
Found 2 matches:

1. zigtools/zls [repo]
   Tags: zig, lsp, tooling
   Why: Zig Language Server - essential for Zig development

2. zig-standard-library [repo]
   Tags: zig, std
   Why: Comprehensive standard library for Zig
```

### `discovery mark-shared <id>`

Mark a discovery as shared with Baala.

**Example:**
```
discovery mark-shared 550e8400-e29b-41d4-a716-446655440000
```

**Response:**
```
Marked as shared: zigtools/zls
```

### `discovery delete <id>`

Delete a discovery.

**Example:**
```
discovery delete 550e8400-e29b-41d4-a716-446655440000
```

**Response:**
```
Deleted: zigtools/zls
```

### `discovery stats`

Show statistics about discoveries.

**Example:**
```
discovery stats
```

**Response:**
```
Discovery Statistics:
  Total finds: 42
  Unshared: 15
  Shared: 27

  By type:
    repo: 25
    article: 12
    tool: 5

  By source:
    github-stars: 18
    web-search: 14
    moltbook: 7
    manual: 3

  Top tags:
    zig: 12
    ai: 8
    wasm: 6
    mcp: 5
```

## Sources

- `github-stars` — From checking GitHub stars/trending
- `web-search` — Found during web searches
- `moltbook` — Discovered on Moltbook
- `manual` — Explicitly added by Baala

## Heartbeat Integration

During heartbeats, Barvis should:
1. Occasionally add interesting discoveries
2. Review unshared finds (every few days)
3. Surface relevant finds when they match a conversation topic

## Guidelines

- **Quality over quantity** — Only add genuinely interesting things
- **Be specific** — Explain *why* it's interesting in the description
- **Tag thoughtfully** — Tags help with future searches
- **Max 100 finds** — Oldest get pruned when limit reached
- **Review periodically** — Share interesting finds with Baala

## Configuration

### `data_file`

Path to the discoveries data file. Default: `memory/interesting-finds.json`

### `max_finds`

Maximum number of finds to keep. When the limit is reached, the oldest finds are pruned. Default: 100

### `auto_share_threshold`

Auto-share finds after this many days. Set to `null` to disable auto-sharing. Default: `null`

## Programmatic API

The skill can be used programmatically to add finds:

```zig
const discovery = @import("discovery/skill.zig");

try discovery.addFind(allocator, .{
    .title = "interesting-repo",
    .url = "https://github.com/...",
    .type = "repo",
    .tags = &[_][]const u8{ "zig", "wasm" },
    .description = "Why this is cool",
    .source = "github-stars",
});
```
