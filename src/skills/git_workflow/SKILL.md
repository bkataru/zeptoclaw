---
name: git-workflow
version: 1.0.0
description: Git advanced workflows — rebase, force-push safety, branch management, PR templates, history rewriting.
metadata: {"zeptoclaw":{"emoji":"🔀"}}
---

# Git Workflow

Baala has 233 repos. Git is constant. This skill covers advanced patterns and safety.

## Daily Commands

```bash
# Status check
git status -sb

# Quick commit
git add -A && git commit -m "feat: description"

# Push
git push origin main

# Pull with rebase (avoid merge commits)
git pull --rebase origin main
```

## Commit Message Convention

Follow Conventional Commits:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types:**
- `feat` — New feature
- `fix` — Bug fix
- `docs` — Documentation only
- `refactor` — Code change (no feat/fix)
- `test` — Adding tests
- `chore` — Maintenance (deps, CI, etc.)
- `perf` — Performance improvement

**Examples:**
```bash
git commit -m "feat(nufast): add PREM Earth model"
git commit -m "fix(gateway): handle stuck sessions"
git commit -m "docs: update README with new features"
```

## Branch Management

```bash
# Create new branch
git checkout -b feature/new-feature

# List branches
git branch -a

# Delete branch (local)
git branch -d feature/old-feature

# Delete branch (remote)
git push origin --delete feature/old-feature

# Rename branch
git branch -m old-name new-name
```

## Rebase and History Rewriting

```bash
# Interactive rebase (last 3 commits)
git rebase -i HEAD~3

# Squash commits
# In rebase editor, change 'pick' to 'squash' for commits to squash

# Rebase onto main
git checkout feature-branch
git rebase main

# Abort rebase if things go wrong
git rebase --abort

# Continue rebase after resolving conflicts
git rebase --continue
```

## Force-Push Safety

**NEVER force-push to shared branches!**

```bash
# Safe: force-push to your own feature branch
git push origin feature-branch --force-with-lease

# NEVER: force-push to main/master
# git push origin main --force  # DON'T DO THIS!
```

## Triggers

command: /git-status
command: /git-commit
command: /git-push
command: /git-pull
command: /git-branch
pattern: *git commit*
pattern: *git push*

## Configuration

default_branch (string): Default branch name (default: main)
enable_rebase (boolean): Enable rebase workflows (default: true)
force_push_protection (boolean): Protect against force-push to main (default: true)

## Usage

### Check git status
```
/git-status
```

### Commit changes
```
/git-commit "feat: add new feature"
```

### Push changes
```
/git-push
```

### Pull with rebase
```
/git-pull
```

### Create branch
```
/git-branch feature/new-feature
```

## Implementation Notes

This skill provides Git workflow support. It:
1. Manages Git operations safely
2. Enforces commit message conventions
3. Handles branch management
4. Provides rebase workflows
5. Protects against dangerous operations

## Dependencies

- Git
