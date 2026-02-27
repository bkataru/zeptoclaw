---
name: local-llm
version: 1.0.0
description: Local LLM inference — Ollama, GGUF models, quantization, hardware matching, igllama.
author: Baala Kataru
category: ai
triggers:
  - type: command
    commands:
      - "llm"
      - "ollama"
      - "local-llm"
  - type: pattern
    patterns:
      - ".*ollama.*"
      - ".*local.*llm.*"
      - ".*gguf.*"
      - ".*quantiz.*"
config:
  properties:
    ollama_host:
      type: string
      default: "http://localhost:11434"
      description: "Ollama API host"
    default_model:
      type: string
      default: "qwen3:4b"
      description: "Default model for inference"
    num_threads:
      type: integer
      default: 6
      description: "Number of CPU threads for inference"
    num_ctx:
      type: integer
      default: 4096
      description: "Context length"
  required: []
---

# Local LLM Inference

Run LLMs locally for privacy, speed, and offline access. Baala has 41+ models in Ollama.

## Hardware Context

**Baala's Setup:**
- **Desktop (threadripper):** High-end, can run large models
- **Laptop:** AMD Ryzen 5 5600U, 18GB RAM, integrated Radeon (CPU-only inference)

## Ollama (Primary)

### Basic Commands

```bash
# List local models
ollama list

# Pull a model
ollama pull qwen3:4b
ollama pull llama3.2:3b

# Run interactive chat
ollama run qwen3:4b

# Run with prompt
ollama run qwen3:4b "Explain quantum entanglement briefly"

# Run with system prompt
ollama run qwen3:4b --system "You are a physics expert"

# Show model info
ollama show qwen3:4b

# Remove model
ollama rm model-name

# Copy/rename model
ollama cp qwen3:4b my-qwen

# Create custom model
ollama create my-model -f Modelfile
```

### API Usage

```bash
# Generate (one-shot)
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3:4b",
  "prompt": "Hello",
  "stream": false
}'

# Chat (multi-turn)
curl http://localhost:11434/api/chat -d '{
  "model": "qwen3:4b",
  "messages": [
    {"role": "user", "content": "Hello"}
  ]
}'

# Embeddings
curl http://localhost:11434/api/embeddings -d '{
  "model": "nomic-embed-text",
  "prompt": "Text to embed"
}'
```

### Modelfile (Custom Models)

```dockerfile
FROM qwen3:4b

# Set parameters
PARAMETER temperature 0.7
PARAMETER num_ctx 8192
PARAMETER stop ""

# System prompt
SYSTEM """You are a helpful physics assistant."""

# Template (optional)
TEMPLATE """{{ .System }}

{{ .Prompt }}"""
```

Build: `ollama create my-model -f Modelfile`

## Model Selection Guide

### By RAM Available

| RAM | Recommended Models |
|-----|-------------------|
| 4GB | qwen3:0.6b, gemma3:270m, granite4:350m |
| 8GB | qwen3:1.7b, gemma3:1b, phi4-mini, cogito:3b |
| 16GB | qwen3:4b, llama3.2:3b, deepseek-r1:8b |
| 32GB | qwen3:8b, llama3.2:7b, mistral:7b |
| 64GB+ | qwen3-coder:30b, mixtral:8x7b, llama3:70b |

### By Task

| Task | Models |
|------|--------|
| Fast chat | qwen3:4b, phi4-mini |
| Coding | qwen3-coder:30b, deepseek-coder |
| Reasoning | deepseek-r1:8b, qwen3:4b-thinking |
| Vision | qwen3-vl:2b, llava, granite3.2-vision |
| Embeddings | nomic-embed-text, qwen3-embedding |
| Translation | translategemma |
| Function calling | functiongemma, gpt-oss |

### Baala's Installed Models

**Embeddings:** qwen3-embedding:8b, qwen3-embedding:0.6b, nomic-embed-text-v2-moe, mxbai-embed-large

**Chat:** qwen3:0.6b/1.7b/4b, gemma3:270m/1b, phi4-mini, cogito:3b, deepseek-r1:8b

**Vision:** qwen3-vl:2b, granite3.2-vision, deepseek-ocr

**Special:** functiongemma (tool calling), translategemma, gpt-oss (13GB)

## GGUF Models (Manual)

For models not in Ollama registry, use GGUF files directly.

### Download from HuggingFace

```bash
# Using huggingface-cli
huggingface-cli download TheBloke/Mistral-7B-v0.1-GGUF mistral-7b-v0.1.Q4_K_M.gguf

# Using hf-hub-zig (Baala's tool)
hf-hub-zig download TheBloke/Mistral-7B-v0.1-GGUF -f mistral-7b-v0.1.Q4_K_M.gguf
```

### Quantization Levels

| Quant | Size | Quality | Use Case |
|-------|------|---------|----------|
| Q2_K | ~25% | Low | Desperate / testing |
| Q4_K_M | ~45% | Good | **Best balance** |
| Q5_K_M | ~55% | Better | If RAM allows |
| Q6_K | ~65% | Great | Near-FP16 |
| Q8_0 | ~80% | Excellent | Minimal loss |
| F16 | 100% | Full | Reference |

**Rule of thumb:** Q4_K_M is the sweet spot for most use cases.

### Run with llama.cpp

```bash
# Interactive chat
llama-cli -m model.gguf -c 4096 -ngl 0 -i

# Single prompt
llama-cli -m model.gguf -p "Hello, world" -n 100

# With GPU layers (if CUDA)
llama-cli -m model.gguf -ngl 35

# Server mode
llama-server -m model.gguf --host 0.0.0.0 --port 8080
```

## igllama (Baala's Project)

Zig-based Ollama alternative. Lighter weight, uses llama.cpp.zig bindings.

```bash
# Build
cd igllama
zig build -Doptimize=ReleaseFast

# Run (API TBD based on current state)
./zig-out/bin/igllama serve
```

## RAM Estimation

**Formula:** `RAM ≈ (params × bytes_per_param) + context_overhead`

For Q4_K_M:
- 7B model: ~4-5GB
- 13B model: ~8-10GB
- 30B model: ~18-22GB
- 70B model: ~40-45GB

**Context overhead:** ~2MB per 1K context tokens for 7B model.

## Performance Tuning

### CPU-Only (Laptop)

```bash
# Set thread count (match physical cores)
OLLAMA_NUM_THREADS=6 ollama run qwen3:4b

# Or in Modelfile
PARAMETER num_thread 6
```

### GPU Offloading

```bash
# Check GPU memory
nvidia-smi

# Offload layers (more = faster, needs VRAM)
OLLAMA_GPU_LAYERS=35 ollama run llama3.2:7b

# Full GPU (if fits)
OLLAMA_GPU_LAYERS=999 ollama run qwen3:4b
```

### Context Length

```bash
# Set context length
OLLAMA_NUM_CTX=8192 ollama run qwen3:4b

# In Modelfile
PARAMETER num_ctx 8192
```

**Warning:** Longer context = more RAM. 32K context on 7B model can add 2-3GB.

## Fallback Strategy (Laptop)

When cloud APIs fail, use local models:

1. **Primary:** GPT-OSS 20B (MoE, only 3.6B active, ~14GB RAM)
2. **Backup:** Qwen3-8B (~5GB, 8-12 tok/s)
3. **Minimal:** Qwen3-4B (~3GB, 15+ tok/s)

Configure OpenClaw fallback:
```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "github-copilot/claude-opus-4.5",
        "fallback": "ollama/qwen3:4b"
      }
    }
  }
}
```

## Commands

### `llm list`

List all available Ollama models.

**Example:**
```
llm list
```

**Response:**
```
Available models:

Chat:
  qwen3:0.6b (0.6B)
  qwen3:1.7b (1.7B)
  qwen3:4b (4.0B)
  gemma3:270m (270M)
  phi4-mini (3.8B)

Embeddings:
  qwen3-embedding:8b (8.0B)
  nomic-embed-text-v2-moe (1.1B)

Vision:
  qwen3-vl:2b (2.0B)
  granite3.2-vision (3.0B)
```

### `llm run <model> [prompt]`

Run a model with optional prompt.

**Example:**
```
llm run qwen3:4b "Explain quantum entanglement briefly"
```

**Response:**
```
Quantum entanglement is a phenomenon where two or more particles become correlated...
```

### `llm chat <model>`

Start an interactive chat session with a model.

**Example:**
```
llm chat qwen3:4b
```

### `llm pull <model>`

Pull a model from Ollama registry.

**Example:**
```
llm pull qwen3:4b
```

### `llm recommend [--ram <GB>] [--task <task>]`

Recommend a model based on RAM or task.

**Example:**
```
llm recommend --ram 16
```

**Response:**
```
Recommended models for 16GB RAM:

- qwen3:4b (4.0B) - Fast chat, ~3GB RAM
- llama3.2:3b (3.0B) - Balanced, ~2.5GB RAM
- deepseek-r1:8b (8.0B) - Reasoning, ~5GB RAM

Best choice: qwen3:4b
```

### `llm estimate <model> [--ctx <tokens>]`

Estimate RAM usage for a model.

**Example:**
```
llm estimate qwen3:4b --ctx 8192
```

**Response:**
```
RAM estimation for qwen3:4b:

Model size (Q4_K_M): ~2.4GB
Context overhead (8K tokens): ~16MB
Total: ~2.4GB

Recommended: 4GB+ RAM available
```

## Troubleshooting

**"CUDA out of memory"**
- Reduce GPU layers: `OLLAMA_GPU_LAYERS=20`
- Use smaller quantization: Q4_K_S instead of Q4_K_M
- Close other GPU apps

**Slow generation**
- Check thread count matches CPU cores
- Use smaller model or lower quant
- Reduce context length

**Model not found**
- Check `ollama list`
- Pull with `ollama pull model:tag`
- Check model name spelling

**Server won't start**
- Check port 11434 not in use
- Check `systemctl status ollama`
- Check logs: `journalctl -u ollama`

## Configuration

### `ollama_host`

Ollama API host. Default: `http://localhost:11434`

### `default_model`

Default model for inference. Default: `qwen3:4b`

### `num_threads`

Number of CPU threads for inference. Default: `6`

### `num_ctx`

Context length. Default: `4096`
