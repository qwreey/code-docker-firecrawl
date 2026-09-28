#!/bin/sh
set -eu

# firecrawl-front is now a plain network bridge, not an auth gate - the AIO `firecrawl`
# container does its own bearer-token check on its own nginx-gate supervisord program
# (see ../../config/supervisor/nginx-gate-service.sh) before this even runs. This
# container's only reason to exist is that the AIO container stays on the isolated
# `firecrawl` network alone (no route to code-docker-internal, same isolation the old
# fetcher containers had) - something still has to sit on both networks for
# code-docker's agent to reach it at all.
#
# TODO: whether this separate bridge container is the right long-term shape - versus
# putting the AIO container directly on code-docker-internal with its own gate doing the
# whole job, or exposing it through a router vhost instead - is intentionally left open.
# See CLAUDE.md.
#
# Not templated with FIRECRAWL_TOKEN at all (unlike the old firecrawl-front) - there is
# nothing to check here anymore, so there is no fail-closed branch to get wrong either.

CONF_DIR=/etc/nginx/conf.d
GATE_PORT="${FIRECRAWL_GATE_PORT:-3002}"

mkdir -p "${CONF_DIR}"
sed "s/__GATE_PORT__/${GATE_PORT}/g" \
    /firecrawl-front/firecrawl.conf.template > "${CONF_DIR}/default.conf"

echo "[firecrawl-front] bridging code-docker-internal:${GATE_PORT} -> firecrawl:${GATE_PORT} (auth is the AIO container's own job now)"
exec nginx -g "daemon off;"
