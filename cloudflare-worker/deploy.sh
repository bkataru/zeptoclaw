#!/bin/bash
# Deployment script for ZeptoClaw Cloudflare Worker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "ZeptoClaw Cloudflare Worker Deployment"
echo "=========================================="
echo ""

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo "❌ Error: wrangler is not installed"
    echo "Install it with: npm install -g wrangler"
    exit 1
fi

# Check if node_modules exists
if [ ! -d "node_modules" ]; then
    echo "📦 Installing dependencies..."
    npm install
fi

# Type check
echo "🔍 Running type check..."
npm run typecheck

# Check if KV namespaces are configured
if grep -q 'id = ""' wrangler.toml; then
    echo ""
    echo "⚠️  Warning: KV namespace IDs are not set in wrangler.toml"
    echo ""
    echo "To create KV namespaces, run:"
    echo "  wrangler kv:namespace create \"GATEWAY_HEALTH\""
    echo "  wrangler kv:namespace create \"ZEPTOCLAW_STATE\""
    echo ""
    echo "Then update wrangler.toml with the returned IDs."
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if logged in
echo "🔐 Checking Cloudflare authentication..."
if ! wrangler whoami &> /dev/null; then
    echo "Please login to Cloudflare:"
    wrangler login
fi

# Deploy
echo ""
echo "🚀 Deploying worker..."
wrangler deploy

echo ""
echo "=========================================="
echo "✅ Deployment complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Test the health endpoint:"
echo "   curl https://zeptoclaw-router.<your-subdomain>.workers.dev/health"
echo ""
echo "2. Test chat completions:"
echo "   curl -X POST https://zeptoclaw-router.<your-subdomain>.workers.dev/v1/chat/completions \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
echo ""
echo "3. View logs:"
echo "   npm run tail"
echo ""
