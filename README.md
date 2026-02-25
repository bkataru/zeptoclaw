# Zeptoclaw

> **The world's tiniest AI agent framework.**  
> Zig-powered, NVIDIA NIM-native. Built for [Barvis](https://github.com/bkataru/barvis). 🦀⚡

## What is this?

Zeptoclaw is a custom, from-scratch AI agent framework written in **Zig 0.15.2+**. It's designed as a lean, purpose-built alternative to frameworks like NullClaw and KrillClaw, optimized specifically for the Barvis ecosystem.

**Key features:**
- 🚀 **NVIDIA NIM native** - OpenAI-compatible API integration with `qwen/qwen3.5-397b-a17b`
- 🦀 **Zero bloat** - Built from scratch, no fork inheritance
- 🔧 **UTCP-ready** - Universal Tool Calling Protocol support
- 📦 **Modular** - Clean separation: providers, agents, channels, tools

## Installation

```bash
git clone https://github.com/bkataru/zeptoclaw.git
cd zeptoclaw
zig build
```

## Usage

Set your API key:
```bash
export NVIDIA_API_KEY=nvapi-xxx
```

Run the agent:
```bash
zig build run
```

## Architecture

```
src/
├── main.zig              # Entry point
├── root.zig              # Library root with exports
├── config.zig            # Configuration (env vars)
├── providers/
│   ├── types.zig         # OpenAI-compatible types
│   └── nim.zig           # NVIDIA NIM HTTP client
├── agent/
│   ├── message.zig       # Message utilities
│   ├── tools.zig         # Tool registry
│   └── loop.zig          # Agent loop (LLM → parse → dispatch)
└── channels/
    └── cli.zig           # CLI channel (interactive mode)
```

## Dependencies

- [utcp](https://github.com/bkataru/zig-utcp) - Universal Tool Calling Protocol
- [mcp.zig](https://github.com/bkataru/mcp.zig) - Model Context Protocol
- [raikage](https://github.com/bkataru/raikage) - Encryption
- [hf-hub-zig](https://github.com/bkataru/hf-hub-zig) - HuggingFace Hub
- [niza](https://github.com/bkataru/niza) - [dependency]
- [zenmap](https://github.com/bkataru/zenmap) - [dependency]
- [zeitgeist](vendor/zeitgeist) - Time-series memory (vendored)
- [comprezz](vendor/comprezz) - Compression (vendored)

## Development

```bash
# Build
zig build

# Run tests
zig build test

# Run executable
./zig-out/bin/zeptoclaw
```

## Why "Zeptoclaw"?

- **Zepto** = 10⁻²¹ (smaller than nano, pico, femto...)
- **Claw** = Part of the "Claw" family (NullClaw, KrillClaw, TinyClaw)
- **Z** = Starts with Z, like Zig 🎯

## License

MIT - Same as the rest of the Claw family.

---

**Status:** Phase 2 Complete ✅  
**Core:** NVIDIA NIM provider + Agent loop implemented and tested.
