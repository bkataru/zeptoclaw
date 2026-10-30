# Planckeon Sites

## Overview

Command skill for Planckeon static-site workflows: Zola build/serve simulation and GitHub Pages deploy narrative. Commands require a site name in `ctx.args`. Site list and LaTeX notes are in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — exported skill struct; default `sites_dir` and `gh_pages_branch`.
- `skill.zig:skill.init` — no-op.
- `skill.zig:skill.execute` — requires `ctx.command`; routes `deploy-site`, `build-site`, `zola-serve`, `zola-build`, `help`; errors on missing command, unknown command, or missing `ctx.args` where required.
- `skill.zig:skill.deinit` — no-op.
- `skill.zig:skill.getMetadata` — name `planckeon-sites`, category `deployment`, triggers for deploy/Zola/GitHub Pages mentions and commands.

## Invariants

- `skill.zig:parseConfig` — reads optional JSON `sites_dir` and `gh_pages_branch` over defaults.
- `skill.zig:handleDeploy` — requires `ctx.args` as site name; printed deploy URL uses `https://planckeon.github.io/{site_name}/` and `cfg.gh_pages_branch`.
- `skill.zig:handleBuild` / `handleZolaServe` / `handleZolaBuild` — require site name argument; output describes `zola build` or `zola serve` with fixed timing and paths.
- `skill.zig:handleHelp` — lists four commands and static site overview without executing Zola.

## Side Effects

- `skill.zig:skill.execute` — returns owned message buffers only; does not run `zola` or `gh-pages`.
- None — no channel `respond` calls in this file.

## Verification

- Run: `zig build test`
