---
name: dirmacs-docs
version: 1.0.0
description: Search indexed documentation from Dirmacs repositories (ares, ehb, thulp).
author: Baala Kataru
category: search
triggers:
  - type: command
    commands:
      - "dirmacs"
      - "dirmacs-docs"
      - "ddocs"
  - type: pattern
    patterns:
      - ".*dirmacs.*"
      - ".*ares.*"
      - ".*ehb.*"
      - ".*thulp.*"
config:
  properties:
    index_path:
      type: string
      default: "memory/dirmacs-docs-index.json"
      description: "Path to the documentation index file"
    dirmacs_path:
      type: string
      default: "~/dirmacs"
      description: "Path to Dirmacs repositories"
    auto_rebuild:
      type: boolean
      default: false
      description: "Automatically rebuild index when docs change"
  required: []
---

# Dirmacs Documentation Search

Search indexed documentation from Baala's Dirmacs repositories (ares, ehb, thulp).

## Quick Reference

Use this skill when you need to answer questions like:
- "How do I configure MCP in ares?"
- "What's the architecture of ehb?"
- "How do skills work in thulp?"

## Indexed Repositories

### ares (Agentic Chatbot Server)

| Document | Topics |
|----------|--------|
| QUICK_REFERENCE.md | CLI commands, just commands, cargo build, Docker, Ollama, API endpoints, troubleshooting |
| MCP.md | MCP server setup, Claude Desktop config, available tools (calculator, web_search, server_stats) |
| PROJECT_STATUS.md | Current implementation status, features, roadmap |
| GGUF_USAGE.md | Loading GGUF models, LlamaCpp setup |
| KNOWN_ISSUES.md | Known bugs and workarounds |
| FUTURE_ENHANCEMENTS.md | Planned features |
| DEPRECATED_AGENTS.md | Old agent types (reference only) |

### ehb (eHealthBuddy - Mental Health AI Microservice)

| Document | Topics |
|----------|--------|
| ARCHITECTURE.md | System design, crate structure, safety guardrails, database schema, API endpoints |
| INTEGRATION.md | How to integrate with ehb APIs |
| DEPLOYMENT.md | Deployment guide |
| IMPLEMENTATION_PLAN.md | Development roadmap |

### thulp (Execution Context Platform)

| Document | Topics |
|----------|--------|
| PROJECT_OVERVIEW.md | Vision, problem statement, core principles, target users |
| ARCHITECTURE.md | Crate structure, rs-utcp integration, data flows, configuration |
| FEATURES.md | MCP client, adapters, skills system, query engine, browser automation |
| API_DESIGN.md | API specification |
| PACKAGES.md | Workspace package details |
| IMPLEMENTATION_STATUS.md | Current progress |
| TESTING_STRATEGY.md | Test approach |
| ROADMAP.md | Future plans |
| VENDOR.md | Dependencies |
| CODE_REVIEW_SUMMARY.md | Review notes |

## How to Search

1. **Load the index**: The skill automatically loads the index from `memory/dirmacs-docs-index.json`
2. **Find relevant section**: Match your question to document topics above
3. **Read the doc**: The skill will display the relevant documentation

## Index File

The structured index lives at: `memory/dirmacs-docs-index.json`

Regenerate with: `dirmacs rebuild`

## Common Queries

| Question | Document(s) to Check |
|----------|---------------------|
| How to run ares? | ares/QUICK_REFERENCE.md |
| MCP server setup | ares/MCP.md |
| ehb safety/guardrails | ehb/ARCHITECTURE.md |
| What is thulp? | thulp/PROJECT_OVERVIEW.md |
| thulp skills format | thulp/FEATURES.md, thulp/ARCHITECTURE.md |
| jq query syntax | thulp/FEATURES.md (F4: Query Engine) |
| ehb database schema | ehb/ARCHITECTURE.md |
| Docker setup | ares/QUICK_REFERENCE.md |

## Commands

### `dirmacs search <query>`

Search the documentation index for a query.

**Example:**
```
dirmacs search "MCP"
```

**Response:**
```
Found 2 matches:

1. ares/MCP.md
   Topics: MCP server setup, Claude Desktop config, available tools

2. thulp/FEATURES.md
   Topics: MCP client, adapters, skills system

Which document would you like to read?
```

### `dirmacs show <repo>/<doc>`

Display a specific document.

**Example:**
```
dirmacs show ares/MCP.md
```

**Response:**
```
# MCP Server Setup

[Full document content...]
```

### `dirmacs list`

List all indexed documents.

**Example:**
```
dirmacs list
```

**Response:**
```
ares:
  - QUICK_REFERENCE.md
  - MCP.md
  - PROJECT_STATUS.md
  - GGUF_USAGE.md
  - KNOWN_ISSUES.md
  - FUTURE_ENHANCEMENTS.md
  - DEPRECATED_AGENTS.md

ehb:
  - ARCHITECTURE.md
  - INTEGRATION.md
  - DEPLOYMENT.md
  - IMPLEMENTATION_PLAN.md

thulp:
  - PROJECT_OVERVIEW.md
  - ARCHITECTURE.md
  - FEATURES.md
  - API_DESIGN.md
  - PACKAGES.md
  - IMPLEMENTATION_STATUS.md
  - TESTING_STRATEGY.md
  - ROADMAP.md
  - VENDOR.md
  - CODE_REVIEW_SUMMARY.md
```

### `dirmacs rebuild`

Rebuild the documentation index.

**Example:**
```
dirmacs rebuild
```

**Response:**
```
Rebuilding documentation index...
Scanning ~/dirmacs/ares/docs/...
Scanning ~/dirmacs/ehb/docs/...
Scanning ~/dirmacs/thulp/docs/...
Index rebuilt: 18 documents indexed
```

### `dirmacs tree`

Show the tree structure of the index.

**Example:**
```
dirmacs tree
```

**Response:**
```
dirmacs-docs-index.json
├── ares
│   ├── QUICK_REFERENCE.md
│   ├── MCP.md
│   ├── PROJECT_STATUS.md
│   ├── GGUF_USAGE.md
│   ├── KNOWN_ISSUES.md
│   ├── FUTURE_ENHANCEMENTS.md
│   └── DEPRECATED_AGENTS.md
├── ehb
│   ├── ARCHITECTURE.md
│   ├── INTEGRATION.md
│   ├── DEPLOYMENT.md
│   └── IMPLEMENTATION_PLAN.md
└── thulp
    ├── PROJECT_OVERVIEW.md
    ├── ARCHITECTURE.md
    ├── FEATURES.md
    ├── API_DESIGN.md
    ├── PACKAGES.md
    ├── IMPLEMENTATION_STATUS.md
    ├── TESTING_STRATEGY.md
    ├── ROADMAP.md
    ├── VENDOR.md
    └── CODE_REVIEW_SUMMARY.md
```

## Configuration

### `index_path`

Path to the documentation index file. Default: `memory/dirmacs-docs-index.json`

### `dirmacs_path`

Path to Dirmacs repositories. Default: `~/dirmacs`

### `auto_rebuild`

When enabled, the skill will automatically rebuild the index when documentation changes are detected.

## Index Format

The index file is a JSON structure:

```json
{
  "version": "1.0.0",
  "last_updated": "2024-02-04T00:00:00Z",
  "repositories": {
    "ares": {
      "path": "~/dirmacs/ares",
      "documents": {
        "QUICK_REFERENCE.md": {
          "topics": ["CLI commands", "cargo build", "Docker", "Ollama", "API endpoints", "troubleshooting"],
          "path": "docs/QUICK_REFERENCE.md"
        },
        "MCP.md": {
          "topics": ["MCP server setup", "Claude Desktop config", "available tools"],
          "path": "docs/MCP.md"
        }
      }
    },
    "ehb": {
      "path": "~/dirmacs/ehb",
      "documents": {
        "ARCHITECTURE.md": {
          "topics": ["System design", "crate structure", "safety guardrails", "database schema", "API endpoints"],
          "path": "docs/ARCHITECTURE.md"
        }
      }
    },
    "thulp": {
      "path": "~/dirmacs/thulp",
      "documents": {
        "PROJECT_OVERVIEW.md": {
          "topics": ["Vision", "problem statement", "core principles", "target users"],
          "path": "docs/PROJECT_OVERVIEW.md"
        }
      }
    }
  }
}
```
