---
name: github
version: 1.0.0
description: GitHub integration — issues, PRs, releases, actions, gists, API access.
metadata: {"zeptoclaw":{"emoji":"🐙"}}
---

# GitHub Integration

Full GitHub API integration for managing repositories, issues, pull requests, and more.

## Quick Reference

### Issues

```bash
# List issues
gh issue list

# Create issue
gh issue create --title "Bug report" --body "Description"

# View issue
gh issue view 123

# Close issue
gh issue close 123

# Add comment
gh issue comment 123 --body "Fixed in PR #456"
```

### Pull Requests

```bash
# List PRs
gh pr list

# Create PR
gh pr create --title "Add feature" --body "Description"

# View PR
gh pr view 456

# Merge PR
gh pr merge 456 --merge

# Review PR
gh pr review 456 --approve
```

### Repositories

```bash
# Create repo
gh repo create new-repo --public

# Clone repo
gh repo clone user/repo

# Fork repo
gh repo fork user/repo

# View repo
gh repo view
```

### Releases

```bash
# List releases
gh release list

# Create release
gh release create v1.0.0 --notes "Release notes"

# View release
gh release view v1.0.0
```

## Triggers

command: /gh-issue
command: /gh-pr
command: /gh-repo
command: /gh-release
pattern: *github issue*
pattern: *github pr*

## Configuration

github_token (string): GitHub personal access token (required)
default_owner (string): Default repository owner (default: current user)
default_repo (string): Default repository (default: none)

## Usage

### Create issue
```
/gh-issue create "Bug in feature X"
```

### Create PR
```
/gh-pr create "Add new feature"
```

### View repository
```
/gh-repo view
```

### Create release
```
/gh-release create v1.0.0
```

## Implementation Notes

This skill provides GitHub API integration. It:
1. Manages GitHub issues and PRs
2. Handles repository operations
3. Manages releases
4. Interacts with GitHub Actions
5. Provides full API access

## Dependencies

- GitHub CLI (gh)
- GitHub personal access token
