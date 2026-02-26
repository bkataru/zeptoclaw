# Zeptoclaw

> **The world's tiniest AI agent framework.**
>
> Zig-powered, NVIDIA NIM-native. Built for [Barvis](https://www.moltbook.com/u/barvis_da_jarvis). 🦀⚡

## What is this?

Zeptoclaw is a custom, from-scratch AI agent framework written in **Zig 0.15.2+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

**Key features:**
- 🚀 **NVIDIA NIM native** - OpenAI-compatible API integration with `qwen/qwen3.5-397b-a17b`
- 🦀 **Zero bloat** - Built from scratch, no fork inheritance
- 🔧 **UTCP-ready** - Universal Tool Calling Protocol support
- 📦 **Modular** - Clean separation: providers, agents, channels, tools
- ⚡ **Performance** - Zig's comptime magic and zero-cost abstractions

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

### Prerequisites

- **Zig 0.15.2+** - Install via [ziglang.org](https://ziglang.org/download/)
- **NVIDIA NIM API Key** - Get yours from [NVIDIA NIM](https://build.nvidia.com/)

## Usage

### 1. Set your API key

```bash
export NVIDIA_API_KEY=nvapi-xxx
```

Optionally, set the model (defaults to `qwen/qwen3.5-397b-a17b`):

```bash
export NVIDIA_MODEL=qwen/qwen3.5-397b-a17b
```

### 2. Run the agent

```bash
zig build run
```

### 3. Interactive CLI

Once running, you'll enter an interactive session where you can:
- Chat with the AI agent
- Use tools via UTCP (Universal Tool Calling Protocol)
- Execute commands and get responses

## Architecture

```
src/
├── main.zig              # Entry point - initializes config, NIM client, agent loop
├── root.zig              # Library root with public API exports
├── config.zig            # Configuration (env vars: NVIDIA_API_KEY, NVIDIA_MODEL)
├── providers/
│   ├── types.zig         # OpenAI-compatible types (Message, ChatCompletionResponse, etc.)
│   └── nim.zig           # NVIDIA NIM HTTP client with JSON serialization
├── agent/
│   ├── message.zig       # Message utilities and role types
│   ├── tools.zig         # Tool registry and dispatch
│   └── loop.zig          # Agent loop (LLM → parse → dispatch → repeat)
└── channels/
    ├── cli.zig           # CLI channel (interactive mode)
    ├── session.zig       # Session management
    ├── input.zig         # Input handling
    └── stream.zig        # Streaming utilities
```

### Core Components

| Component | Description |
|-----------|-------------|
| **NIMClient** | HTTP client for NVIDIA NIM API with JSON serialization |
| **Agent** | Main agent loop that manages conversation state and tool dispatch |
| **Providers** | LLM provider abstraction (currently NVIDIA NIM only) |
| **Channels** | I/O abstraction layer (CLI, future: Discord, Slack, etc.) |
| **Tools** | UTCP-compatible tool registry for function calling |

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [utcp](https://github.com/bkataru/zig-utcp) | Universal Tool Calling Protocol |
| [mcp.zig](https://github.com/bkataru/mcp.zig) | Model Context Protocol |
| [raikage](https://github.com/bkataru/raikage) | Encryption utilities |
| [hf-hub-zig](https://github.com/bkataru/hf-hub-zig) | HuggingFace Hub integration |
| [niza](https://github.com/bkataru/niza) | Utility functions |
| [zenmap](https://github.com/bkataru/zenmap) | Data structures |
| [zeitgeist](vendor/zeitgeist) | Time-series memory (vendored) |
| [comprezz](vendor/comprezz) | Compression utilities (vendored) |

## Development

### Build

```bash
zig build
```

### Run tests

```bash
zig build test
```

### Run executable

```bash
./zig-out/bin/zeptoclaw
```

### Project structure

- `src/` - Main source code
- `vendor/` - Vendored dependencies (zeitgeist, comprezz)
- `build.zig` - Build configuration
- `.env` - Environment variables template (gitignored)

## Why "Zeptoclaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto...) - emphasizing minimalism
- **Claw** = Part of the "Claw" family (NullClaw, KrillClaw, TinyClaw)
- **Z** = Starts with Z, like Zig 🎯

## License

MIT - Same as the rest of the Claw family.

---

**Status:** Phase 2 Complete ✅  
**Core:** NVIDIA NIM provider + Agent loop implemented and tested.

**Related:** [Barvis on Moltbook](https://www.moltbook.com/u/barvis_da_jarvis)
