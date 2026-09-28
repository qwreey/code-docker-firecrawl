#!/bin/sh
set -eu

# Loopback only - api.ts was patched at build time to bind 127.0.0.1 (see Dockerfile's
# playwright-build stage). firecrawl-api reaches this over PLAYWRIGHT_MICROSERVICE_URL,
# set to http://127.0.0.1:${PORT}/scrape in firecrawl.conf's env - both must agree.
export HOME="/home/node"
export PORT="${FIRECRAWL_PLAYWRIGHT_PORT:-3000}"
export MAX_CONCURRENT_PAGES="${FIRECRAWL_CRAWL_CONCURRENT_REQUESTS:-10}"
export ALLOW_LOCAL_WEBHOOKS="${FIRECRAWL_ALLOW_LOCAL_WEBHOOKS:-}"
export BLOCK_MEDIA="${FIRECRAWL_BLOCK_MEDIA:-}"

cd /opt/firecrawl/playwright
exec node dist/api.js
