---
name: memory-tree-search
version: 1.0.0
description: Vectorless, reasoning-based search over memory files using tree indices (PageIndex-inspired).
author: Baala Kataru
category: search
triggers:
  - type: mention
    patterns:
      - "memory"
      - "remember"
      - "recall"
      - "what did we"
  - type: command
    commands:
      - "memory-index"
      - "memory-search"
      - "memory-tree"
      - "summarize-transcripts"
  - type: pattern
    patterns:
      - ".*what did we decide.*"
      - ".*what did I work on.*"
      - ".*do you remember.*"
      - ".*in my memory.*"
config:
  properties:
    index_path:
      type: string
      default: "memory/.tree-index.json"
      description: "Path to the tree index file"
    memory_files:
      type: array
      default: ["MEMORY.md", "memory/*.md", "memory/relationships.json"]
      description: "Memory files to index"
    auto_reindex:
      type: boolean
      default: false
      description: "Automatically reindex when files change"
  required: []
---

# Memory Tree Search

Reasoning-based memory retrieval without embeddings or vector databases.

## Concept

Inspired by [PageIndex](https://github.com/VectifyAI/PageIndex):
- **No embeddings needed** — uses document structure + LLM reasoning
- **No chunking artifacts** — natural sections based on markdown headers
- **Human-like retrieval** — "Where would this info be?" reasoning

## How It Works

### 1. Index Building (on demand)

Parse markdown files into tree structure:
```
MEMORY.md
├── ## Custom Skills Created
│   └── content about skills...
├── ## Conventions
│   └── content about conventions...
├── ## Who I Am
│   └── content about identity...
└── ## nufast v0.5.0
    └── content about nufast...
```

### 2. Tree Search (when querying)

Given a query like "What did we decide about nufast?":

1. **Show tree to LLM** with section titles + brief summaries
2. **LLM reasons**: "nufast info would be under '## nufast v0.5.0'"
3. **Retrieve that section** and answer

### 3. Multi-hop Search

For complex queries spanning multiple sections:
1. LLM identifies multiple relevant sections
2. Retrieve all relevant sections
3. Synthesize answer from combined context

## Usage

### Build the Index

```bash
memory-index
```

Creates `memory/.tree-index.json` with file tree and header structure.

### Search Memory

```bash
memory-search "query"
```

Searches the tree index and retrieves relevant sections.

### Show Tree Structure

```bash
memory-tree
```

Displays the tree structure of indexed memory files.

### Summarize Transcripts

```bash
summarize-transcripts [--days <days>]
```

Summarizes old session transcripts for MEMORY.md curation.

## Commands

### `memory-index`

Build or update the memory tree index.

**Example:**
```
memory-index
```

**Response:**
```
Building memory tree index...
Indexing MEMORY.md...
Indexing memory/2026-02-03.md...
Indexing memory/relationships.json...

Indexed 3 files
Found 42 sections
Saved to: memory/.tree-index.json
```

### `memory-search <query>`

Search memory using tree-based reasoning.

**Example:**
```
memory-search "What did we decide about nufast?"
```

**Response:**
```
Searching memory tree...

Found relevant section: MEMORY.md > "## nufast v0.5.0"

Content:
## nufast v0.5.0

Released nufast v0.5.0 with Zig implementation achieving 25ns vacuum oscillations.
Key decisions:
- Switched to Zig as primary language
- Added PREM Earth model support
- Implemented 4-flavor sterile neutrinos

[Full section content...]
```

### `memory-tree`

Display the tree structure of indexed memory files.

**Example:**
```
memory-tree
```

**Response:**
```
MEMORY.md
├── ## Custom Skills Created (12 skills, locations)
├── ## Conventions (citation sections)
├── ## Who I Am (name: Barvis)
├── ## Who Baala Is (background, preferences)
├── ## Core Projects (dirmacs, planckeon)
├── ## Tools & Setup (CLI tools, Ollama models)
├── ## Troubleshooting Learned (SRI hash, WSL, etc.)
├── ## nufast v0.5.0 (marathon session details)
├── ## imagining-the-neutrino (ITN project)
└── ## NVIDIA NIM Fallback System (router details)

memory/2026-02-03.md
├── ## Session Summary (skills, nufast, auto-sync, moltbook)
├── ## Key Config Changes
├── ## Operational Incidents
└── ## Next Session

memory/relationships.json
└── Contact info and last interactions
```

### `summarize-transcripts [--days <days>]`

Summarize old session transcripts.

**Example:**
```
summarize-transcripts --days 7
```

**Response:**
```
Summarizing sessions older than 7 days...

### Session: 2026-02-03 (10:28 - 23:54, 806min)
**Messages:** 248 user, 979 assistant
**Topics:** Physics/Neutrinos, Rust Development, Git Operations...

**Outcomes:**
- Released nufast v0.5.0
- Deployed ITN v1.6.0 with Zig WASM

**Decisions:**
- Switching to Zig as primary language

**Significant Actions:**
- Created/modified: src/nufast.zig
- Git: git push origin main

_Session ID: 778c9e6e-f6b6-4995-abea-cd2d72380f10_
```

## Benefits

- **Fast** — Don't read entire MEMORY.md for simple queries
- **Accurate** — Reasoning > similarity matching
- **Explainable** — "I found this in section X"
- **No external deps** — Works with any LLM, no vector DB

## Limitations

- **Requires structure** — Works best with well-organized markdown
- **LLM cost** — Tree reasoning uses some tokens (but less than reading everything)
- **Not for unstructured** — Plain text without headers needs chunking

## Configuration

### `index_path`

Path to the tree index file. Default: `memory/.tree-index.json`

### `memory_files`

List of memory files to index. Default: `["MEMORY.md", "memory/*.md", "memory/relationships.json"]`

### `auto_reindex`

When enabled, automatically reindex when files change. Default: `false`

## Files to Index

Priority memory files:
1. `MEMORY.md` — Long-term curated memory
2. `memory/YYYY-MM-DD.md` — Daily logs (recent ones)
3. `memory/relationships.json` — Contact tracking
4. `memory/security-incidents.md` — Security events
5. `memory/heartbeat-state.json` — System state

## Index Structure

```json
{
  "indexedAt": "2026-02-04T00:30:00Z",
  "files": [
    {
      "path": "MEMORY.md",
      "size": 12345,
      "sections": [
        {
          "level": 2,
          "title": "Custom Skills Created",
          "line": 15,
          "preview": "Created 12 custom skills for OpenClaw..."
        }
      ]
    }
  ]
}
```
