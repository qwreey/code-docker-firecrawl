#!/usr/bin/env bash
set -eu

# This container's side of the shared dns-local program - see code-docker-chrome's own
# copy of this wrapper (config/supervisor/dns-local-service.sh there) for the fuller
# writeup of the bug it exists for. Short version: this container sits on an
# `internal: true` network behind router, where Docker's embedded DNS (127.0.0.11)
# answers same-network names fine but returns an immediate, definitive SERVFAIL for
# anything else - and Node's own resolver (what firecrawl-api and playwright-service both
# are) never retries past that onto a second nameserver. dns-local runs a strict-order
# local dnsmasq and repoints this container's own /etc/resolv.conf at it.
#
# Defaults to on, same as chrome: this image has no deployment without router in front of
# it, unlike roblox-studio-docker's standalone mode.
export DNS_LOCAL_ENABLED="${DNS_LOCAL_ENABLED:-true}"
export NETSHARE_DIR="${NETSHARE_DIR:-/etc/code-docker-firecrawl/router-client/netshare}"

exec /etc/code-docker-firecrawl/router-client/dns-local/dns-local.sh
