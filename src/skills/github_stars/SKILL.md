---
name: github-stars
version: 1.0.0
description: Search Baala's GitHub stars for relevant tools, libraries, and references when working on any task.
metadata: {"zeptoclaw":{"emoji":"⭐"}}
---

# GitHub Stars Search

Baala has 2800+ starred repos. Search them to find relevant tools before reinventing the wheel.

## Why This Matters

Before building or recommending something, check if Baala already starred a solution. His stars are curated — if he starred it, it's probably good.

## Local Indexer (Recommended)

The indexer fetches all starred repos once and saves them locally for instant search.

### Build/Update Index

```bash
bun ~/.openclaw/workspace/skills/github-stars/index-stars.ts
```

This fetches all starred repos (2800+) and saves metadata to:
`~/.openclaw/workspace/memory/github-stars-index.json`

Takes ~3-5 minutes on first run. Re-run periodically to sync new stars.

### Search

```bash
# Search by keyword (matches name, description, topics, language)
bun ~/.openclaw/workspace/skills/github-stars/index-stars.ts --search "git automation"

# Multiple terms (AND logic)
bun ~/.openclaw/workspace/skills/github-stars/index-stars.ts --search "rust cli"

# Search specific language
bun ~/.openclaw/workspace/skills/github-stars/index-stars.ts --search "zig"
```

### View Stats

```bash
bun ~/.openclaw/workspace/skills/github-stars/index-stars.ts --stats
```

Shows:
- Total repos indexed
- Languages breakdown
- Last sync time

## Triggers

command: /stars-search
command: /stars-stats
command: /stars-sync
pattern: *search stars*
pattern: *github stars*

## Configuration

index_path (string): Path to stars index file (default: ~/.openclaw/workspace/memory/github-stars-index.json)
sync_interval_hours (integer): Auto-sync interval (default: 24)
max_results (integer): Max search results (default: 10)

## Usage

### Search stars
```
/stars-search "zig lsp"
```

### View stats
```
/stars-stats
```

### Sync index
```
/stars-sync
```

## Implementation Notes

This skill provides GitHub stars search functionality. It:
1. Maintains a local index of starred repos
2. Supports keyword and language search
3. Provides statistics on starred repos
4. Syncs periodically with GitHub
5. Returns relevant results quickly

## Dependencies

- GitHub CLI (gh)
- GitHub personal access token
