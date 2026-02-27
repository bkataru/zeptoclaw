---
name: rust-cargo
version: 1.0.0
description: Rust/Cargo workflow — build, test, publish to crates.io, benchmarks, cross-compile.
metadata: {"zeptoclaw":{"emoji":"🦀"}}
---

# Rust & Cargo Development

Baala's secondary language. Used for production systems (ares, ehb, daedra, thulp) and when ecosystem matters.

## Quick Reference

### Build Commands

```bash
# Debug build
cargo build

# Release build (optimized)
cargo build --release

# Check (fast compile check, no binary)
cargo check

# Run
cargo run
cargo run --release

# Run specific binary in workspace
cargo run -p crate-name --bin binary-name

# Tests
cargo test
cargo test -- --nocapture    # Show println! output
cargo test test_name         # Run specific test
cargo test --workspace       # All crates in workspace

# Benchmarks (requires nightly or criterion)
cargo bench

# Docs
cargo doc --open
cargo doc --no-deps          # Skip dependency docs
```

### Workspace Structure (Baala's convention)

```
project/
├── Cargo.toml               # Workspace root
├── Cargo.lock
├── crates/
│   ├── crate-a/
│   │   ├── Cargo.toml
│   │   └── src/
│   └── crate-b/
│       ├── Cargo.toml
│       └── src/
└── target/                  # Build output
```

### Publishing to crates.io

```bash
# Login
cargo login

# Dry run (check if publishable)
cargo publish --dry-run

# Publish
cargo publish

# Publish specific crate in workspace
cargo publish -p crate-name
```

## Triggers

command: /cargo-build
command: /cargo-test
command: /cargo-publish
command: /cargo-clean
pattern: *cargo build*
pattern: *cargo test*

## Configuration

cargo_path (string): Path to cargo executable (default: cargo)
workspace_root (string): Workspace root directory (default: .)
enable_benchmarks (boolean): Enable benchmark support (default: true)
publish_dry_run (boolean): Always dry-run before publish (default: true)

## Usage

### Build project
```
/cargo-build
```

### Run tests
```
/cargo-test
```

### Publish to crates.io
```
/cargo-publish
```

### Clean build artifacts
```
/cargo-clean
```

## Implementation Notes

This skill provides Rust/Cargo development workflow support. It:
1. Manages Cargo build configurations
2. Runs tests and benchmarks
3. Handles workspace management
4. Supports publishing to crates.io
5. Manages dependencies

## Dependencies

- Rust toolchain (cargo)
