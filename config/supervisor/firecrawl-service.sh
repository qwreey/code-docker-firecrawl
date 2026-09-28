#!/bin/sh
set -eu

# Waits for postgres, then hands off to upstream's own harness (node dist/src/harness.js
# --start-docker), which forks api/worker/extract-worker/the nuq workers/prefetch/
# reconciler itself - see apps/api/src/harness.ts.
#
# POSTGRES_HOST is deliberately NOT the literal string "localhost": harness.ts's
# setupNuqPostgres()/setupNuqRabbitMQ() check `POSTGRES_HOST !== "localhost"` to decide
# whether it's running "in docker-compose" (construct the connection URL and stop) versus
# standalone (try to `docker run`/`podman run` its own postgres/rabbitmq containers,
# which this container has no docker.sock or CLI to do at all). 127.0.0.1 is the same
# address without tripping that check.
export HOST="${FIRECRAWL_API_HOST:-127.0.0.1}"
export PORT="${FIRECRAWL_API_PORT:-3902}"
export ENV=local
export USE_DB_AUTHENTICATION=false

export REDIS_URL="redis://127.0.0.1:6379"
export REDIS_RATE_LIMIT_URL="redis://127.0.0.1:6379"
export PLAYWRIGHT_MICROSERVICE_URL="http://127.0.0.1:${FIRECRAWL_PLAYWRIGHT_PORT:-3000}/scrape"

export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"
export POSTGRES_HOST="127.0.0.1"
export POSTGRES_PORT="5432"

# No rabbitmq in this image - see CLAUDE.md. NUQ_WAIT_MODE=listen makes nuq's
# waitForJob() use postgres LISTEN/NOTIFY instead of an AMQP round trip
# (apps/api/src/services/worker/nuq.ts's nuqWaitMode - `config.NUQ_WAIT_MODE === "listen"
# || config.NUQ_RABBITMQ_URL`), which needs nothing beyond the postgres connection this
# already has.
export NUQ_WAIT_MODE=listen

export NUM_WORKERS_PER_QUEUE="${FIRECRAWL_NUM_WORKERS:-8}"
export CRAWL_CONCURRENT_REQUESTS="${FIRECRAWL_CRAWL_CONCURRENT_REQUESTS:-10}"
export MAX_CONCURRENT_JOBS="${FIRECRAWL_MAX_CONCURRENT_JOBS:-5}"
export BROWSER_POOL_SIZE="${FIRECRAWL_BROWSER_POOL_SIZE:-5}"

# Optional - only used by the LLM-backed /extract endpoint. Unset means that endpoint
# 400s; scrape/crawl/map are unaffected.
export OPENAI_API_KEY="${FIRECRAWL_OPENAI_API_KEY:-}"
export OPENAI_BASE_URL="${FIRECRAWL_OPENAI_BASE_URL:-}"
export MODEL_NAME="${FIRECRAWL_MODEL_NAME:-}"

echo "[firecrawl-service] waiting for postgres..."
i=0
until pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER}" >/dev/null 2>&1; do
	i=$((i + 1))
	if [ "$i" -ge 60 ]; then
		echo "[firecrawl-service] postgres still not ready after 60s - starting anyway, the harness itself will report the real connection error" >&2
		break
	fi
	sleep 1
done
echo "[firecrawl-service] postgres is reachable, starting the harness"

cd /opt/firecrawl/api
exec node dist/src/harness.js --start-docker
