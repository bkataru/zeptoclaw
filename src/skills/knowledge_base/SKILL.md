---
name: knowledge-base
version: 1.0.0
description: Search and reference personal knowledge base stored in Obsidian/Zettelkasten.
author: Baala Kataru
category: search
triggers:
  - type: command
    commands:
      - "kb"
      - "knowledge"
      - "vault"
      - "obsidian"
  - type: pattern
    patterns:
      - ".*knowledge.*base.*"
      - ".*obsidian.*"
      - ".*vault.*"
      - ".*zettelkasten.*"
config:
  properties:
    vault_path:
      type: string
      default: "/mnt/c/Users/user/Documents/Obsidian Vault/"
      description: "Path to Obsidian vault"
    index_path:
      type: string
      default: "memory/vault-index.json"
      description: "Path to the vault index file"
    auto_index:
      type: boolean
      default: false
      description: "Automatically reindex when vault changes"
  required: []
---

# Knowledge Base (Obsidian/Zettelkasten)

Search and reference Baala's personal knowledge base stored in Obsidian.

## Vault Location

**Current:** `/mnt/c/Users/user/Documents/Obsidian Vault/`

This is on the Windows side, accessible from WSL via `/mnt/c/`. Performance may be slightly slower than native Linux paths but works fine for indexing.

### Changing Vault Path

Edit the skill configuration or set `OBSIDIAN_VAULT` environment variable.

## Usage

### Index the Vault

```
kb index
```

Creates `memory/vault-index.json` with file tree and header structure.

### Search Notes

```
kb search <query>
```

Searches file names, folder paths, and headers. Returns matching files with relevant sections.

### Show File

```
kb show <path>
```

Display the full content of a specific note.

### List Files

```
kb list [--folder <folder>]
```

List all indexed notes, optionally filtered by folder.

## Search Approach

**Tree-based search** (similar to memory-tree-search):

1. **Index scan** — Search vault-index.json for matching files/headers
2. **Narrow down** — Identify 1-3 most relevant files
3. **Deep read** — Only read the specific files needed

This avoids loading entire vault into context.

## Privacy Notes

⚠️ **Some notes are personal:**

- `feelings/` — Personal journal entries (treat as private)
- `prompts/` — AI prompts (generally safe)
- `zig/`, `dump/` — Technical notes (safe)

**Guidelines:**
- Don't quote personal content verbatim to others
- In group chats, reference technical notes only
- Ask before sharing anything from `feelings/`

## Index Structure

```json
{
  "vaultPath": "/mnt/c/...",
  "indexedAt": "2026-02-04T00:10:00Z",
  "files": [
    {
      "path": "zig/allocators.md",
      "name": "allocators.md",
      "folder": "zig",
      "headers": [
        { "level": 1, "text": "Allocators in Zig", "line": 1 },
        { "level": 2, "text": "Arena Allocator", "line": 15 }
      ]
    }
  ]
}
```

## WSL Access to Windows Obsidian

If Obsidian is on Windows (common setup), access via `/mnt/c/`:

```bash
# Windows path: C:\Users\user\Documents\Obsidian Vault
# WSL path:     /mnt/c/Users/user/Documents/Obsidian Vault
```

**Performance tip:** For heavy indexing, consider syncing vault to Linux side with:
- Symlink: `ln -s "/mnt/c/Users/user/Documents/Obsidian Vault" ~/obsidian`
- Or rsync periodic copy (one-way, don't modify from Linux side)

## Commands

### `kb index`

Index the Obsidian vault.

**Example:**
```
kb index
```

**Response:**
```
Indexing vault: /mnt/c/Users/user/Documents/Obsidian Vault/
Scanning files...
Indexed 142 notes
Index saved to: memory/vault-index.json
```

### `kb search <query>`

Search the vault index for notes matching the query.

**Example:**
```
kb search "allocator"
```

**Response:**
```
Found 3 matches:

1. zig/allocators.md
   Headers:
   - Allocators in Zig (H1)
   - Arena Allocator (H2)
   - GPA Allocator (H2)

2. zig/memory.md
   Headers:
   - Memory Management (H1)
   - Custom Allocators (H2)

3. dump/allocator-notes.md
   Headers:
   - Allocator Notes (H1)

Which file would you like to read?
```

### `kb show <path>`

Display the full content of a specific note.

**Example:**
```
kb show zig/allocators.md
```

**Response:**
```
# Allocators in Zig

Zig provides several built-in allocators...

## Arena Allocator

Arena allocators are useful for...

[Full note content...]
```

### `kb list [--folder <folder>]`

List all indexed notes, optionally filtered by folder.

**Example:**
```
kb list --folder zig
```

**Response:**
```
Notes in zig/ (12 total):

- allocators.md
- async.md
- comptime.md
- memory.md
- std-lib.md
- testing.md
- ...
```

### `kb tree`

Show the tree structure of the vault.

**Example:**
```
kb tree
```

**Response:**
```
Obsidian Vault/
├── zig/
│   ├── allocators.md
│   ├── async.md
│   └── ...
├── dump/
│   ├── allocator-notes.md
│   └── ...
├── prompts/
│   └── ...
└── feelings/
    └── ...
```

## Configuration

### `vault_path`

Path to Obsidian vault. Default: `/mnt/c/Users/user/Documents/Obsidian Vault/`

### `index_path`

Path to the vault index file. Default: `memory/vault-index.json`

### `auto_index`

When enabled, the skill will automatically reindex when vault changes are detected. Default: `false`

## Privacy Guidelines

When working with the knowledge base:

1. **Technical notes** (`zig/`, `dump/`, etc.) — Safe to share
2. **Prompts** (`prompts/`) — Generally safe, but use discretion
3. **Personal notes** (`feelings/`) — Treat as private, ask before sharing

In group chats or shared contexts, only reference technical notes unless explicitly asked otherwise.
