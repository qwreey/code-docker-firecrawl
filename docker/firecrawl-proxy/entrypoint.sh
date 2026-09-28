#!/bin/sh
set -eu

# firecrawl-front's entrypoint. Not nginx-unprivileged's own default entrypoint (which
# does its own envsubst-on-templates pass) because that pass has no way to fail closed
# when FIRECRAWL_TOKEN is unset - envsubst just substitutes an empty string, and an empty
# string inside a naive `Authorization: Bearer ${FIRECRAWL_TOKEN}` comparison would make
# the expected header "Bearer " (trailing space, nothing else) rather than "reject
# everything", which is not the same thing as fail-closed. So the branch below is
# explicit instead of relying on template substitution to get an empty value "right" by
# accident.

CONF_DIR=/etc/nginx/conf.d
mkdir -p "$CONF_DIR"

if [ -z "${FIRECRAWL_TOKEN:-}" ]; then
    echo "firecrawl-front: FIRECRAWL_TOKEN is empty - serving 401 for every request (fail closed)"
    cat > "$CONF_DIR/default.conf" <<'EOF'
server {
    listen 3002;
    location / {
        return 401;
    }
}
EOF
else
    # Plain substitution, not nginx's own envsubst-on-templates step - same file, just
    # invoked explicitly so the empty-token branch above can run first. `sed` with `/` as
    # the delimiter assumes the token itself never contains `/` - true for anything
    # ootb.sh's OOTB_GENERATE_SECRETS produces (openssl rand -hex, so [0-9a-f] only); if
    # you set FIRECRAWL_TOKEN by hand to something containing `/`, pick a different
    # delimiter here or use a plain alphanumeric token instead.
    sed "s/__FIRECRAWL_TOKEN__/$FIRECRAWL_TOKEN/g" /firecrawl-front/firecrawl.conf.template > "$CONF_DIR/default.conf"
    echo "firecrawl-front: bearer-token gate active, proxying to firecrawl-api:3002"
fi

exec nginx -g "daemon off;"
