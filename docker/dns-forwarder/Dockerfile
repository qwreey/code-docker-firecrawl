# A tiny, network-visible DNS forwarder for the `firecrawl` internal network - see
# entrypoint.sh for why this needs to exist as its own container rather than reusing
# code-docker's own dns-local program (short version: dns-local rewrites the resolver of
# the container it runs IN; firecrawl-api/playwright-service are upstream images with no
# supervisord to hang a same-container resolver off of, so one shared forwarder serves
# both over the network instead).
FROM alpine:3.22

RUN apk add --no-cache dnsmasq

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
