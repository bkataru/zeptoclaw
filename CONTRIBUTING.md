# Contributing to ZeptoClaw

Thanks for your interest in contributing to ZeptoClaw! This document provides guidelines and instructions for contributing.

## Project Status

**Migration Complete** - All 11 phases finished with 0 errors.

| Metric | Value |
|--------|-------|
| Source Files | 70 Zig files |
| Lines of Code | 19,717 lines |
| Binaries | 4 production binaries |
| Skills | 21 ported from OpenClaw |
| Systemd Services | 10 service/timer files |

## Getting Started

### Prerequisites

- **Zig 0.15.2+** - Install from [ziglang.org](https://ziglang.org/download/)
- **Git** - For version control
- **NVIDIA NIM API Key** - For testing (optional, for integration tests)

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/bkataru/zeptoclaw.git
   cd zeptoclaw
   ```
3. Create a branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development

### Building

```bash
# Debug build
zig build

# Release build
zig build --release=safe

# Release build with optimizations
zig build --release=fast
```

### Running Tests

```bash
# Run all tests (unit + integration)
zig build test

# Run only unit tests (skip integration tests)
zig build test -- --skip-integration
```

### Code Style

- Follow existing Zig conventions in the codebase
- Use descriptive variable and function names
- Add comments for complex logic
- Keep functions focused and single-purpose
- Use `comptime` where appropriate for compile-time computations

### Testing Guidelines

1. **Unit Tests**: All new functions should have unit tests
2. **Integration Tests**: API interactions should have integration tests (can be skipped without API key)
3. **Error Handling**: Test error cases, not just success paths

Example test structure:

```zig
test "function does something" {
    const allocator = std.testing.allocator;

    // Setup
    const input = ...;

    // Execute
    const result = try function(input);
    defer result.deinit(allocator);

    // Verify
    try std.testing.expectEqual(expected, result);
}
```

## Project Structure

```
src/
├── main.zig                    # Entry point
├── config.zig                  # Configuration
├── providers/                  # LLM providers
│   ├── nim.zig                 # NVIDIA NIM client
│   ├── types.zig               # OpenAI-compatible types
│   └── ...
├── agent/                      # Agent framework
│   ├── loop.zig                # Agent loop
│   ├── tools.zig               # Tool registry
│   └── message.zig             # Message utilities
├── channels/                   # I/O channels
│   ├── cli.zig                 # CLI channel
│   ├── session.zig             # Session management
│   └── whatsapp/               # WhatsApp channel
├── services/                   # HTTP services
│   ├── gateway_server.zig      # Main gateway
│   ├── webhook_server.zig      # Webhook handling
│   └── shell2http_server.zig   # Shell2HTTP
├── skills/                     # Skill implementations
│   ├── skill_registry.zig      # Skill management
│   └── [skill_name]/skill.zig  # Individual skills
└── autonomous/                 # Autonomous operations
    ├── autonomous.zig          # Main autonomous logic
    └── moltbook_client.zig     # Moltbook integration
```

### Key Components

| Component | Description |
|-----------|-------------|
| **Providers** | LLM provider implementations (NVIDIA NIM) |
| **Agent** | Agent loop and tool dispatch |
| **Channels** | I/O channels (CLI, WhatsApp, etc.) |
| **Services** | HTTP servers (gateway, webhook, shell2http) |
| **Skills** | UTCP-compatible function calling |

## Pull Request Process

1. **Create a branch** for your feature or fix
2. **Make your changes** with tests
3. **Run tests** to ensure everything passes
4. **Update documentation** if needed
5. **Submit a PR** with a clear description

### PR Checklist

- [ ] Code compiles with `zig build`
- [ ] All tests pass with `zig build test`
- [ ] No new compiler warnings
- [ ] Documentation updated (if applicable)
- [ ] Tests added for new functionality
- [ ] Binary sizes checked (if applicable)

## Architecture Guidelines

### Modular Design

Zeptoclaw follows a modular architecture with clear separation of concerns:

- **Providers**: Abstract LLM backends
- **Agents**: Manage conversation state and tool execution
- **Channels**: Handle input/output (CLI, WhatsApp, etc.)
- **Services**: HTTP servers and endpoints
- **Skills**: UTCP-compatible function calling interface

### Error Handling

- Use Zig's error union types (`!T`) for fallible operations
- Provide meaningful error messages
- Handle errors at appropriate abstraction levels

### Performance

- Leverage `comptime` for compile-time computations
- Use arena allocators for request-scoped allocations
- Minimize allocations in hot paths

## Testing

### Build Verification

```bash
# Clean build
zig build --release=safe

# Check binary sizes
ls -lh zig-out/bin/
```

### Service Verification

```bash
# Check gateway
curl http://localhost:18789/health

# Check webhook
curl http://localhost:9000/health

# Check shell2http
curl http://localhost:9001/health
```

## Reporting Issues

- **Bugs**: Include Zig version, OS, and steps to reproduce
- **Feature Requests**: Describe the use case and expected behavior
- **Security**: Report privately to the maintainers

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

For questions, reach out via [Moltbook](https://www.moltbook.com/u/barvis_da_jarvis).
