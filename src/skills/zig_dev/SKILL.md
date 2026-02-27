---
name: zig-dev
version: 1.0.0
description: Zig development workflow — build, test, WASM, benchmarks, release. Baala's primary language.
metadata: {"zeptoclaw":{"emoji":"⚡"}}
---

# Zig Development

Baala's primary language as of 2026-02-03. "Zig matches how I think about computation."

## Why Zig Won

From the nufast benchmark session:
- **2.4× faster than Rust** for vacuum oscillations
- **1.8× faster than C++** for matter calculations
- comptime + explicit allocators = pure compute speed
- WASM SIMD128 works out of the box with `@Vector`

## Quick Reference

### Build Commands

```bash
# Debug build
zig build

# Release (optimized)
zig build -Doptimize=ReleaseFast

# Release with safety checks
zig build -Doptimize=ReleaseSafe

# Small binary (for WASM)
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Run specific test
zig build test -- "test name pattern"

# Generate docs
zig build docs

# Cross-compile
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
```

### Project Structure

```
project/
├── build.zig              # Build configuration
├── build.zig.zon          # Dependencies
├── src/
│   └── main.zig           # Entry point
├── tests/
│   └── test_main.zig      # Tests
└── zig-cache/             # Build cache
```

### Common Patterns

#### Error Handling
```zig
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Try to allocate
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    // Or handle error
    const result = someOperation() catch |err| {
        std.log.err("Operation failed: {}", .{err});
        return err;
    };
}
```

#### Comptime
```zig
// Comptime-known values
const SIZE = 1024;

// Comptime functions
fn factorial(comptime n: u32) u32 {
    if (n == 0) return 1;
    return n * factorial(n - 1);
}

// Comptime blocks
comptime {
    std.debug.assert(factorial(5) == 120);
}
```

#### Generics
```zig
fn Stack(comptime T: type) type {
    return struct {
        items: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .items = std.ArrayList(T).init(allocator),
            };
        }
    };
}
```

## Triggers

command: /zig-build
command: /zig-test
command: /zig-docs
command: /zig-clean
pattern: *zig build*
pattern: *zig test*

## Configuration

zig_path (string): Path to zig executable (default: zig)
optimize_mode (string): Default optimize mode (default: ReleaseFast)
target_triple (string): Default target triple (default: native)
enable_wasm (boolean): Enable WASM support (default: true)

## Usage

### Build project
```
/zig-build
```

### Run tests
```
/zig-test
```

### Generate documentation
```
/zig-docs
```

### Clean build artifacts
```
/zig-clean
```

## Implementation Notes

This skill provides Zig development workflow support. It:
1. Manages Zig build configurations
2. Runs tests and benchmarks
3. Generates documentation
4. Handles cross-compilation
5. Supports WASM builds

## Dependencies

- Zig compiler (0.15.2+)
