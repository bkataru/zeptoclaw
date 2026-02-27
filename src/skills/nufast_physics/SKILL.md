---
name: nufast-physics
version: 1.0.0
description: Work on nufast neutrino oscillation library — Rust/Zig, WASM, benchmarks, physics background.
author: Baala Kataru
category: physics
triggers:
  - type: mention
    patterns:
      - "nufast"
      - "neutrino"
      - "oscillation"
      - "physics"
  - type: command
    commands:
      - "nufast-build"
      - "nufast-test"
      - "nufast-bench"
      - "nufast-wasm"
  - type: pattern
    patterns:
      - ".*neutrino.*oscillation.*"
      - ".*pmns.*matrix.*"
      - ".*nufast.*"
config:
  properties:
    repo_path:
      type: string
      default: "~/nufast"
      description: "Path to nufast repository"
    zig_path:
      type: string
      default: "~/nufast/benchmarks/zig"
      description: "Path to Zig implementation"
    wasm_output:
      type: string
      default: "~/nufast/benchmarks/zig/wasm"
      description: "Path for WASM output"
  required: []
---

# NuFast Neutrino Physics

nufast is a neutrino oscillation probability library. Port of Denton & Parke's NuFast algorithm.

**Repo:** https://github.com/planckeon/nufast
**crates.io:** https://crates.io/crates/nufast
**Live demo (ITN):** https://planckeon.github.io/itn/

## Project Structure

```
nufast/
├── src/                    # Rust library
│   ├── lib.rs
│   ├── vacuum.rs           # Vacuum oscillations
│   ├── matter.rs           # Matter effects
│   └── types.rs
├── benchmarks/zig/         # Zig implementation (faster!)
│   ├── build.zig
│   ├── build.zig.zon
│   ├── src/
│   │   ├── nufast.zig      # Main library
│   │   ├── sterile.zig     # 4-flavor
│   │   ├── nsi.zig         # Non-standard interactions
│   │   ├── prem.zig        # Earth model
│   │   ├── c_exports.zig   # C FFI
│   │   └── wasm_exports.zig
│   └── wasm/               # WASM output
├── bindings/python/        # Python ctypes wrapper
├── paper/                  # Typst benchmark paper
├── Cargo.toml
└── README.md
```

## Physics Background

### What It Computes

Neutrino oscillation probabilities: the chance that a neutrino of flavor α becomes flavor β after traveling distance L with energy E.

**Flavors:** electron (e), muon (μ), tau (τ)

**Key formula:** P(να → νβ) = f(θ₁₂, θ₁₃, θ₂₃, δ_CP, Δm²₂₁, Δm²₃₁, L, E, ρ)

### PMNS Matrix Parameters

| Parameter | Description | Typical Value |
|-----------|-------------|---------------|
| θ₁₂ | Solar angle | 33.4° |
| θ₁₃ | Reactor angle | 8.6° |
| θ₂₃ | Atmospheric angle | 49° |
| δ_CP | CP phase | -90° to +90° |
| Δm²₂₁ | Solar mass splitting | 7.5×10⁻⁵ eV² |
| Δm²₃₁ | Atm mass splitting | 2.5×10⁻³ eV² |

### Experiment Presets

Built-in configurations for major experiments:

| Experiment | Baseline | Energy | Channel |
|------------|----------|--------|---------|
| T2K | 295 km | ~0.6 GeV | νμ→νe |
| NOvA | 810 km | ~2 GeV | νμ→νe |
| DUNE | 1300 km | ~3 GeV | νμ→νe |
| Hyper-K | 295 km | ~0.6 GeV | νμ→νe |
| JUNO | 53 km | ~3 MeV | ν̄e→ν̄e |
| Daya Bay | 1.6 km | ~3 MeV | ν̄e→ν̄e |
| KamLAND | 180 km | ~3 MeV | ν̄e→ν̄e |

## Commands

### `nufast-build`

Build the nufast library (Rust and Zig).

**Example:**
```
nufast-build
```

**Response:**
```
Building Rust library...
cargo build --release
   Compiling nufast v0.5.0
    Finished release [optimized] target(s) in 2.3s

Building Zig implementation...
cd benchmarks/zig
zig build -Doptimize=ReleaseFast
Build successful!
```

### `nufast-test`

Run tests for nufast.

**Example:**
```
nufast-test
```

**Response:**
```
Running Rust tests...
cargo test
test result: ok. 42 passed; 0 failed

Running Zig tests...
zig build test
All 38 tests passed!
```

### `nufast-bench`

Run benchmarks to measure performance.

**Example:**
```
nufast-bench
```

**Response:**
```
Running Rust benchmarks...
cargo bench

Running Zig benchmarks...
zig build bench
./zig-out/bin/benchmark

Results:
| Implementation | Vacuum | Matter |
|---------------|--------|--------|
| Zig SIMD f64  | 25 ns  | 56 ns  |
| Zig scalar    | 42 ns  | 108 ns |
| Rust          | 61 ns  | 95 ns  |
| Python        | 14,700 ns | 21,900 ns |
```

### `nufast-wasm`

Build WASM version for web deployment.

**Example:**
```
nufast-wasm
```

**Response:**
```
Building WASM...
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

Output in wasm/:
- nufast.wasm (~10.5 KB)
- nufast.js
- nufast.d.ts

Ready to deploy to ITN!
```

## Working with Rust

### Build & Test

```bash
cd nufast
cargo build --release
cargo test
cargo bench
```

### API Usage

```rust
use nufast::{OscParams, VacuumBatch, MatterBatch};

let params = OscParams::default();

// Vacuum
let prob = nufast::vacuum(params, 1.0, 295.0, 0, 1); // νe→νμ

// Matter (with density)
let prob = nufast::matter(params, 1.0, 295.0, 0, 1, 2.6); // ρ = 2.6 g/cm³

// Batch computation
let energies: Vec<f64> = (1..1000).map(|i| i as f64 * 0.01).collect();
let probs = VacuumBatch::new(&params, &energies, 295.0, 0, 1).compute();
```

### Publish to crates.io

```bash
# Update version in Cargo.toml
# Update CHANGELOG.md
cargo publish --dry-run
cargo publish
git tag v0.x.0
git push --tags
```

## Working with Zig (Faster!)

### Build & Test

```bash
cd benchmarks/zig
zig build
zig build test

# Release build
zig build -Doptimize=ReleaseFast

# WASM build
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

### Performance

| Implementation | Vacuum | Matter |
|---------------|--------|--------|
| Zig SIMD f64  | **25 ns** | **56 ns** |
| Zig scalar    | 42 ns | 108 ns |
| Rust          | 61 ns | 95 ns |
| Python        | 14,700 ns | 21,900 ns |

### API Usage (Zig)

```zig
const nufast = @import("nufast");

// Create parameters
var params = nufast.OscParams.default();

// Vacuum oscillation
const prob = nufast.vacuum(params, 1.0, 295.0, .e, .mu);

// Matter oscillation
const prob = nufast.matter(params, 1.0, 295.0, .e, .mu, 2.6, 2);

// PREM Earth model
const prob = nufast.prem_oscillation(params, 1.0, 8000.0, .mu, .e, true);
```

### WASM Build

```bash
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

# Output in wasm/
ls wasm/
# nufast.wasm (~10.5 KB)
# nufast.js
# nufast.d.ts
```

## ITN Integration

ITN (Imagining the Neutrino) uses the Zig WASM build.

**Files:**
- `public/wasm/nufast.wasm` — Zig WASM binary
- `src/physics/nufast.js` — JS loader
- `src/physics/wasmBridge.ts` — TypeScript bridge

### Updating ITN with New WASM

```bash
# Build WASM
cd nufast/benchmarks/zig
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

# Copy to ITN
cp wasm/nufast.wasm ../../../itn/public/wasm/
cp wasm/nufast.js ../../../itn/src/physics/
cp wasm/nufast.d.ts ../../../itn/src/physics/

# Update ITN version
cd ../../../itn
# bump version in package.json
bun run build
bunx gh-pages -d dist
```

## Extended Features (Zig only)

### PREM Earth Model

6-layer density model for long-baseline experiments:

```zig
// Calculate probability through Earth
const prob = nufast.prem_oscillation(
    params,
    energy_GeV,
    baseline_km,
    .mu,    // from flavor
    .e,     // to flavor
    true,   // is_neutrino (false for antineutrino)
);
```

### 4-Flavor Sterile Neutrinos

Vacuum-only (matter would need exact diagonalization):

```zig
const sterile = @import("sterile");

var params4 = sterile.SterileParams.default();
params4.theta_14 = 0.1;
params4.dm2_41 = 1.0;

const prob = sterile.vacuum_4flavor(params4, E, L, .e, .e);
```

### Non-Standard Interactions (NSI)

Complex ε matrix modifying matter potential:

```zig
const nsi = @import("nsi");

var eps = nsi.NsiParams.zero();
eps.eps_ee = 0.1;
eps.eps_emu = std.math.complex(0.05, 0.02);

const prob = nsi.matter_nsi(params, E, L, .mu, .e, rho, eps);
```

## Benchmarking

### Run Benchmarks

```bash
# Rust
cargo bench

# Zig
zig build bench
./zig-out/bin/benchmark
```

### Benchmark Paper

Located in `paper/nufast-benchmark.typ`:

```bash
typst compile nufast-benchmark.typ
```

## Configuration

### `repo_path`

Path to nufast repository. Default: `~/nufast`

### `zig_path`

Path to Zig implementation. Default: `~/nufast/benchmarks/zig`

### `wasm_output`

Path for WASM output. Default: `~/nufast/benchmarks/zig/wasm`

## Troubleshooting

**Tests fail with floating point differences**
- Use `expectApproxEqAbs` with tolerance ~1e-10
- Physics validation: compare against Python reference

**WASM too large**
- Use `-Doptimize=ReleaseSmall`
- Strip debug info
- Check for unused imports

**Matter calculation unstable**
- Increase `n_newton` iterations
- Check for very low densities (< 0.1 g/cm³)
- Validate energy is in GeV, baseline in km

## Related Projects

- **ITN:** Interactive visualization using nufast WASM
- **pytrino:** Original Python implementation (Baala's undergrad)
- **NuPy:** Earlier Python library (capstone)
- **nosc:** Older Rust neutrino engine
