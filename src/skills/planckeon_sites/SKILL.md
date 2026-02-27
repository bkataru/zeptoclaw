---
name: planckeon-sites
version: 1.0.0
description: Deploy planckeon physics sites — Zola static sites, GitHub Pages, LaTeX/KaTeX rendering.
author: Baala Kataru
category: deployment
triggers:
  - type: mention
    patterns:
      - "deploy"
      - "github pages"
      - "zola"
      - "site"
  - type: command
    commands:
      - "deploy-site"
      - "build-site"
      - "zola-serve"
      - "zola-build"
  - type: pattern
    patterns:
      - ".*deploy.*site.*"
      - ".*github pages.*"
      - ".*zola.*"
config:
  properties:
    sites_dir:
      type: string
      default: "~/planckeon"
      description: "Path to planckeon sites directory"
    gh_pages_branch:
      type: string
      default: "gh-pages"
      description: "GitHub Pages branch name"
  required: []
---

# Planckeon Sites Deployment

Deploy Baala's physics visualization and documentation sites to GitHub Pages.

## Sites Overview

| Site | Tech | URL |
|------|------|-----|
| planckeon.github.io | Static HTML | https://planckeon.github.io |
| itn | React + TS + Vite | https://planckeon.github.io/itn/ |
| attn-as-bilinear-form | Zola + KaTeX | https://planckeon.github.io/attn-as-bilinear-form/ |
| nufast (docs) | Zig autodocs | TBD |

## Zola Static Sites

Zola is a fast static site generator. Used for physics papers with LaTeX math.

### Commands

```bash
# Serve locally with live reload
zola serve

# Build for production
zola build

# Check links and build
zola check
```

### Project Structure

```
site/
├── config.toml          # Site config
├── content/
│   ├── _index.md        # Homepage
│   └── section/
│       └── page.md      # Content pages
├── templates/
│   ├── base.html        # Base template
│   ├── index.html       # Homepage template
│   └── page.html        # Page template
├── static/
│   └── css/style.css    # Static assets
└── themes/              # Optional themes
```

### ⚠️ LaTeX Rendering Gotcha (Issue #5)

**Problem:** Underscores in LaTeX get interpreted as Markdown emphasis in Zola's CommonMark parser.

**Symptom:** `P_{\mu\mu}` becomes `P<em>{\mu</em>{\mu}` — broken math.

**Fix:** Escape underscores with HTML entities:

```markdown
<!-- Wrong -->
$P_{\mu\mu}$

<!-- Right -->
$P&#95;{\mu\mu}$

<!-- Or use double underscores if in display math -->
$$
P_{\mu\mu}  <!-- Usually works in $$ blocks -->
$$
```

**Alternative:** Use a custom shortcode for math blocks.

### KaTeX Integration

Add to base template:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"
    onload="renderMathInElement(document.body);"></script>
```

### SRI Hash Issues

**Problem:** CDN resources fail to load silently due to SRI hash mismatch.

**Symptom:** CSS/JS not loading, no console errors (blocked by browser).

**Fix:** Remove `integrity` attribute or update hash:

```html
<!-- Remove integrity if causing issues -->
<link rel="stylesheet" href="https://cdn.example.com/style.css">

<!-- Instead of -->
<link rel="stylesheet" href="https://cdn.example.com/style.css"
      integrity="sha384-WRONGHASH" crossorigin="anonymous">
```

## GitHub Pages Deployment

### Option 1: gh-pages Branch (Recommended)

```bash
# Build
zola build

# Deploy using gh-pages
bunx gh-pages -d public

# Or with npm
npx gh-pages -d public
```

Then set GitHub Pages source to `gh-pages` branch via API or UI:

```bash
gh api repos/planckeon/REPO/pages -X PUT \
  -f source='{"branch":"gh-pages","path":"/"}'
```

### Option 2: GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Zola
        run: |
          wget -q -O zola.tar.gz https://github.com/getzola/zola/releases/download/v0.22.1/zola-v0.22.1-x86_64-unknown-linux-gnu.tar.gz
          tar -xzf zola.tar.gz
          sudo mv zola /usr/local/bin/

      - name: Build
        run: zola build

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: ./public

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

### GitHub Actions Stuck?

**Problem:** Deploy workflow queued but never runs.

**Fix:** Deploy manually and switch Pages source:

```bash
# Build and deploy manually
zola build
bunx gh-pages -d public

# Switch Pages source to gh-pages branch
gh api repos/planckeon/REPO/pages -X PUT \
  -F source[branch]=gh-pages \
  -F source[path]=/
```

## React/Vite Sites (ITN)

### Build & Deploy

```bash
# Install deps
bun install

# Dev server
bun run dev

# Build for production
bun run build

# Preview production build
bun run preview

# Deploy to gh-pages
bunx gh-pages -d dist
```

### Vite Config for GitHub Pages

```typescript
// vite.config.ts
export default defineConfig({
  base: '/repo-name/',  // Important for subpath
  build: {
    outDir: 'dist',
  },
});
```

## Typst Papers

For academic papers (like nufast benchmark):

```bash
# Compile to PDF
typst compile paper.typ

# Watch mode
typst watch paper.typ

# With custom fonts
typst compile --font-path ./fonts paper.typ
```

## Citation Sections

All planckeon repos should have a Citation section in README:

```markdown
## Citation

If you use this software, please cite:

```bibtex
@software{nufast2026,
  author = {Kataru, Baalateja},
  title = {nufast: Fast Neutrino Oscillation Probabilities},
  year = {2026},
  url = {https://github.com/planckeon/nufast}
}
```

For the underlying algorithm:
```bibtex
@article{Denton:2023,
  author = {Denton, Peter B. and Parke, Stephen J.},
  title = {Simple and Precise Factorization...},
  journal = {Phys. Rev. D},
  year = {2023}
}
```
```

## Commands

### `deploy-site <site-name>`

Deploy a site to GitHub Pages.

**Example:**
```
deploy-site attn-as-bilinear-form
```

**Response:**
```
Deploying attn-as-bilinear-form...

Building with Zola...
zola build
Building site...
Done in 0.23s.

Deploying to gh-pages...
bunx gh-pages -d public
Published to https://planckeon.github.io/attn-as-bilinear-form/

Done!
```

### `build-site <site-name>`

Build a site locally.

**Example:**
```
build-site attn-as-bilinear-form
```

**Response:**
```
Building attn-as-bilinear-form...

zola build
Building site...
Done in 0.23s.

Output: public/
```

### `zola-serve <site-name>`

Serve a Zola site locally with live reload.

**Example:**
```
zola-serve attn-as-bilinear-form
```

**Response:**
```
Serving attn-as-bilinear-form...

zola serve
Building site...
Done in 0.23s.
Listening at http://127.0.0.1:1111

Press Ctrl+C to stop.
```

### `zola-build <site-name>`

Build a Zola site for production.

**Example:**
```
zola-build attn-as-bilinear-form
```

**Response:**
```
Building attn-as-bilinear-form for production...

zola build
Building site...
Done in 0.23s.

Output: public/
Ready to deploy!
```

## Configuration

### `sites_dir`

Path to planckeon sites directory. Default: `~/planckeon`

### `gh_pages_branch`

GitHub Pages branch name. Default: `gh-pages`

## Checklist for New Planckeon Site

1. [ ] Create repo with README, LICENSE (MIT)
2. [ ] Add .github/workflows/deploy.yml if using Actions
3. [ ] Configure base path in build config
4. [ ] Add KaTeX/MathJax for LaTeX if needed
5. [ ] Test LaTeX rendering (watch for underscore issue)
6. [ ] Add Citation section
7. [ ] Enable GitHub Pages in repo settings
8. [ ] Verify deployment at planckeon.github.io/repo/
