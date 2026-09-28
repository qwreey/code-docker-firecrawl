#!/bin/sh
set -eu

# firecrawl-front's logic, ported from the old multi-container docker/firecrawl-proxy/
# entrypoint.sh - not nginx's own default entrypoint (its envsubst-on-templates pass has
# no way to fail closed when FIRECRAWL_TOKEN is unset: envsubst just substitutes an empty
# string, and an empty string inside a naive `Authorization: Bearer ${FIRECRAWL_TOKEN}`
# comparison would make the expected header "Bearer " rather than "reject everything",
# which is not fail-closed). The branch below is explicit instead.

CONF_DIR=/etc/nginx/conf.d
GATE_PORT="${FIRECRAWL_GATE_PORT:-3002}"
API_PORT="${FIRECRAWL_API_PORT:-3902}"

mkdir -p "${CONF_DIR}"
rm -f /etc/nginx/sites-enabled/default

if [ -z "${FIRECRAWL_TOKEN:-}" ]; then
	echo "[nginx-gate] FIRECRAWL_TOKEN is empty - serving 401 for every request (fail closed, no 'auth off' mode)"
	cat > "${CONF_DIR}/firecrawl.conf" <<EOF
server {
    listen ${GATE_PORT};
    location / {
        return 401;
    }
}
EOF
else
	# Plain sed, not nginx's envsubst-on-templates step - same reasoning as the empty-
	# token branch above needing an explicit check first. `/` as the sed delimiter
	# assumes the token itself never contains `/`, true for anything ootb.sh's
	# OOTB_GENERATE_SECRETS produces (openssl rand -hex).
	sed \
		-e "s/__FIRECRAWL_TOKEN__/${FIRECRAWL_TOKEN}/g" \
		-e "s/__GATE_PORT__/${GATE_PORT}/g" \
		-e "s/__API_PORT__/${API_PORT}/g" \
		/etc/code-docker-firecrawl/nginx/firecrawl.conf.template > "${CONF_DIR}/firecrawl.conf"
	echo "[nginx-gate] bearer-token gate active on 0.0.0.0:${GATE_PORT}, proxying to 127.0.0.1:${API_PORT}"
fi

exec nginx -g "daemon off;"
