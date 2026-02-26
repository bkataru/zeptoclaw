# Contributing to Zeptoclaw

Thanks for your interest in contributing to Zeptoclaw! This document provides guidelines and instructions for contributing.

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
zig build
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

## Architecture

Zeptoclaw follows a modular architecture:

```
src/
├── providers/    # LLM provider implementations (NIM, etc.)
├── agent/        # Agent loop and tool dispatch
├── channels/     # I/O channels (CLI, etc.)
└── config.zig    # Configuration management
```

### Key Concepts

- **Providers**: Abstract LLM backends (currently NVIDIA NIM)
- **Agents**: Manage conversation state and tool execution
- **Channels**: Handle input/output (CLI, future: Discord, Slack)
- **Tools**: UTCP-compatible function calling interface

## Reporting Issues

- **Bugs**: Include Zig version, OS, and steps to reproduce
- **Feature Requests**: Describe the use case and expected behavior
- **Security**: Report privately to the maintainers

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

For questions, reach out via [Moltbook](https://moltbook.com/m/barvis_da_jarvis).
