---
name: web-qa
version: 1.0.0
description: Web app debugging — Chrome headless screenshots, CDN issues, SRI hash fixes, Canvas quirks.
metadata: {"zeptoclaw":{"emoji":"🌐"}}
---

# Web App QA & Troubleshooting

Techniques for debugging web apps when you don't have direct browser access.

## Chrome Headless Screenshots

### From WSL (Windows Chrome)
```powershell
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command "
  & 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
    --headless `
    --screenshot='C:\path\to\output.png' `
    --window-size=1920,1080 `
    --virtual-time-budget=8000 `
    'https://your-url.com'
"
```

**Key flags:**
- `--headless` — No visible window
- `--screenshot=PATH` — Save screenshot (use Windows path)
- `--window-size=W,H` — Viewport dimensions
- `--virtual-time-budget=MS` — Wait for JS execution (crucial for SPAs)
- `--disable-gpu` — Sometimes needed for stability

### Reading Screenshots in WSL
```bash
# Windows paths accessible via /mnt/c/
cat /mnt/c/Users/user/Pictures/Screenshots/screenshot.png
```

## CDN Resource Debugging

### Check if resource loads
```bash
curl -sI "https://cdn.example.com/lib.css" | head -5
curl -sI "https://cdn.example.com/lib.css" | grep -i 'content-type\|etag'
```

### Verify resource is in HTML
```bash
curl -s "https://site.com/" | grep -i "library-name"
```

### Check SRI hashes
```bash
# Generate hash
openssl dgst -sha384 -binary lib.js | openssl base64 -A

# Compare with HTML
curl -s "https://site.com/" | grep -A1 "lib.js"
```

## Canvas Quirks

### Common Issues

1. **High DPI displays** — Canvas looks blurry
   ```javascript
   const dpr = window.devicePixelRatio || 1;
   canvas.width = rect.width * dpr;
   canvas.height = rect.height * dpr;
   ctx.scale(dpr, dpr);
   ```

2. **Image CORS** — Can't read pixel data
   ```javascript
   img.crossOrigin = "anonymous";
   ```

3. **Offscreen canvas** — Better performance
   ```javascript
   const offscreen = new OffscreenCanvas(width, height);
   const offCtx = offscreen.getContext('2d');
   ```

## Triggers

command: /web-screenshot
command: /web-check-cdn
command: /web-check-sri
pattern: *screenshot*
pattern: *cdn check*

## Configuration

chrome_path (string): Path to Chrome executable (default: C:\Program Files\Google\Chrome\Application\chrome.exe)
screenshot_dir (string): Directory for screenshots (default: /mnt/c/Users/user/Pictures/Screenshots)
default_viewport (string): Default viewport size (default: 1920x1080)
virtual_time_budget (integer): JS execution wait time in ms (default: 8000)

## Usage

### Take screenshot
```
/web-screenshot https://example.com
```

### Check CDN resources
```
/web-check-cdn https://cdn.example.com/lib.js
```

### Check SRI hash
```
/web-check-sri https://site.com lib.js
```

## Implementation Notes

This skill provides web app QA and troubleshooting tools. It:
1. Takes screenshots via Chrome headless
2. Debugs CDN resource loading
3. Verifies SRI hashes
4. Handles Canvas quirks
5. Provides debugging guidance

## Dependencies

- Chrome (Windows)
- PowerShell (WSL)
- curl
- openssl
