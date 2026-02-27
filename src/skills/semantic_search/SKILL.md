---
name: semantic-search
version: 1.0.0
description: Local semantic search for memory using Ollama embeddings.
author: Baala Kataru
category: search
triggers:
  - type: mention
    patterns:
      - "search"
      - "find"
      - "embed"
      - "vector"
  - type: command
    commands:
      - "embed-index"
      - "embed-search"
      - "embed-model"
  - type: pattern
    patterns:
      - ".*search.*memory.*"
      - ".*find.*in.*memory.*"
      - ".*semantic.*search.*"
config:
  properties:
    ollama_url:
      type: string
      default: "http://localhost:11434"
      description: "Ollama API URL"
    embedding_model:
      type: string
      default: "nomic-embed-text"
      description: "Ollama embedding model"
    embeddings_file:
      type: string
      default: "memory/embeddings.json"
      description: "Path to embeddings file"
    top_results:
      type: integer
      default: 5
      description: "Number of results to return"
  required: []
---

# Semantic Search Skill

Local semantic search for memory using Ollama embeddings.

## Overview

This skill provides vector-based semantic search across memory files without requiring cloud APIs. It uses Ollama's local embedding models to generate vectors and stores them locally.

## Requirements

### Ollama Setup

1. **Install Ollama** (if not installed):
   ```bash
   # Linux/WSL
   curl -fsSL https://ollama.com/install.sh | sh

   # Or download from https://ollama.com/download
   ```

2. **Pull an embedding model**:
   ```bash
   # Recommended (good balance of quality/size)
   ollama pull nomic-embed-text

   # Alternatives:
   ollama pull mxbai-embed-large      # Higher quality, larger
   ollama pull qwen3-embedding:0.6b   # Lightweight
   ```

3. **Start Ollama server**:
   ```bash
   ollama serve
   # Or it may already be running as a service
   ```

4. **Verify it's running**:
   ```bash
   curl http://localhost:11434/api/tags
   ```

## Usage

```bash
# Index all memory files (run after adding new memories)
embed-index

# Search for content
embed-search "nufast benchmarks"
embed-search "what did I work on yesterday"

# Specify number of results (default: 5)
embed-search "project ideas" --top 10

# Use a different embedding model
embed-index --model mxbai-embed-large
```

## Memory Sources

The following sources are indexed:

| Source | Description |
|--------|-------------|
| `MEMORY.md` | Long-term curated memories |
| `memory/*.md` | Daily logs and notes |
| `memory/relationships.json` | People and relationships (as text) |

## How It Works

1. **Chunking**: Files are split by paragraphs or sections (headers)
2. **Embedding**: Each chunk is sent to Ollama's embedding API
3. **Storage**: Vectors are stored in `memory/embeddings.json`
4. **Search**: Query is embedded, then cosine similarity finds matches

### Embeddings Storage Format

```json
{
  "model": "nomic-embed-text",
  "indexed_at": "2026-02-04T00:30:00Z",
  "chunks": [
    {
      "id": "MEMORY.md:15",
      "source": "MEMORY.md",
      "line": 15,
      "text": "Chunk text here...",
      "vector": [0.123, -0.456, ...]
    }
  ]
}
```

## Commands

### `embed-index`

Build or update the embeddings index.

**Example:**
```
embed-index
```

**Response:**
```
Indexing memory files...

Reading MEMORY.md...
  - Found 42 chunks
Reading memory/2026-02-03.md...
  - Found 18 chunks
Reading memory/relationships.json...
  - Found 5 chunks

Generating embeddings with nomic-embed-text...
  - 42/65 chunks embedded
  - 65/65 chunks embedded

Saved to: memory/embeddings.json
Index size: 1.2 MB
```

### `embed-search <query>`

Search memory using semantic embeddings.

**Example:**
```
embed-search "nufast benchmarks"
```

**Response:**
```
Searching for: "nufast benchmarks"

Found 5 matches:

1. MEMORY.md:15 (similarity: 0.89)
   "nufast v0.5.0 achieves 25ns vacuum oscillations with Zig SIMD..."

2. memory/2026-02-03.md:42 (similarity: 0.82)
   "Benchmarked nufast against Rust and Python implementations..."

3. MEMORY.md:120 (similarity: 0.78)
   "Performance comparison: Zig SIMD 25ns, Rust 61ns, Python 14,700ns..."

4. memory/2026-02-02.md:15 (similarity: 0.71)
   "Ran benchmarks on nufast Zig implementation..."

5. MEMORY.md:85 (similarity: 0.68)
   "nufast uses Denton & Parke's NuFast algorithm..."
```

### `embed-model`

Show or change the embedding model.

**Example:**
```
embed-model
```

**Response:**
```
Current model: nomic-embed-text
Dimensions: 768

Available models:
- nomic-embed-text (768 dims) - Good balance
- mxbai-embed-large (1024 dims) - Higher quality
- qwen3-embedding:0.6b (768 dims) - Lightweight

To change model: embed-index --model <model-name>
```

## Configuration

### `ollama_url`

Ollama API URL. Default: `http://localhost:11434`

### `embedding_model`

Ollama embedding model. Default: `nomic-embed-text`

### `embeddings_file`

Path to embeddings file. Default: `memory/embeddings.json`

### `top_results`

Number of results to return. Default: `5`

## Troubleshooting

### "Ollama not reachable"

- Ensure Ollama is running: `ollama serve` or check if the service is active
- Check the URL is correct (default: `http://localhost:11434`)
- **WSL users**: The tool auto-detects Windows host IP, but ensure Ollama is bound to `0.0.0.0`:
  - Set `OLLAMA_HOST=0.0.0.0` before starting Ollama on Windows
  - Or use: `OLLAMA_URL=http://<windows-ip>:11434` in WSL

### "Model not found"

- Pull the model: `ollama pull nomic-embed-text`
- List available models: `ollama list`

### "embeddings.json is stale"

- Re-index: `embed-index`
- Index is rebuilt from scratch each time (incremental coming later)

## Notes

- Embedding dimensions vary by model (nomic-embed-text: 768, mxbai-embed-large: 1024)
- Large memory files may take a few seconds to index
- embeddings.json can get large; consider .gitignore if needed

## Model Selection Guide

### By RAM Available

| RAM | Recommended Models |
|-----|-------------------|
| 4GB | qwen3-embedding:0.6b |
| 8GB | nomic-embed-text |
| 16GB | mxbai-embed-large |

### By Use Case

| Use Case | Models |
|---------|--------|
| General search | nomic-embed-text |
| High accuracy | mxbai-embed-large |
| Fast indexing | qwen3-embedding:0.6b |
