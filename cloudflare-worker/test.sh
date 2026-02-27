#!/bin/bash
# Test script for ZeptoClaw Cloudflare Worker

echo "=========================================="
echo "ZeptoClaw Cloudflare Worker Test"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check file structure
echo "📁 Checking file structure..."
required_files=(
    "worker.ts"
    "src/utils.ts"
    "wrangler.toml"
    "package.json"
    "tsconfig.json"
    "README.md"
    "deploy.sh"
    ".gitignore"
)

all_files_exist=true
for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✅ $file"
    else
        echo "  ❌ $file (missing)"
        all_files_exist=false
    fi
done

if [ "$all_files_exist" = false ]; then
    echo ""
    echo "❌ Some required files are missing"
    exit 1
fi

echo ""
echo "📊 File sizes:"
for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        size=$(wc -c < "$file")
        lines=$(wc -l < "$file")
        echo "  $file: $size bytes, $lines lines"
    fi
done

echo ""
echo "🔍 Checking worker.ts for key endpoints..."
endpoints=(
    "/health"
    "/v1/chat/completions"
    "/v1/models"
    "/heartbeat"
    "/state"
    "/gateway/incident"
)

for endpoint in "${endpoints[@]}"; do
    if grep -q "\"$endpoint\"" worker.ts; then
        echo "  ✅ $endpoint"
    else
        echo "  ❌ $endpoint (not found)"
    fi
done

echo ""
echo "🔍 Checking wrangler.toml configuration..."
if grep -q "name = \"zeptoclaw-router\"" wrangler.toml; then
    echo "  ✅ Worker name configured"
else
    echo "  ❌ Worker name not configured"
fi

if grep -q "GATEWAY_HEALTH" wrangler.toml; then
    echo "  ✅ GATEWAY_HEALTH KV namespace configured"
else
    echo "  ❌ GATEWAY_HEALTH KV namespace not configured"
fi

if grep -q "ZEPTOCLAW_STATE" wrangler.toml; then
    echo "  ✅ ZEPTOCLAW_STATE KV namespace configured"
else
    echo "  ❌ ZEPTOCLAW_STATE KV namespace not configured"
fi

if grep -q "ZEPTOCLAW_GATEWAY_URL" wrangler.toml; then
    echo "  ✅ ZEPTOCLAW_GATEWAY_URL configured"
else
    echo "  ❌ ZEPTOCLAW_GATEWAY_URL not configured"
fi

echo ""
echo "🔍 Checking package.json scripts..."
scripts=(
    "dev"
    "deploy"
    "tail"
    "typecheck"
)

for script in "${scripts[@]}"; do
    if grep -q "\"$script\"" package.json; then
        echo "  ✅ $script"
    else
        echo "  ❌ $script (not found)"
    fi
done

echo ""
echo "=========================================="
echo "✅ Test complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Install dependencies: npm install"
echo "2. Run type check: npm run typecheck"
echo "3. Create KV namespaces (see README.md)"
echo "4. Deploy: ./deploy.sh"
echo ""
