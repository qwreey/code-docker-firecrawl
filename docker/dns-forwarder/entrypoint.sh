#!/bin/sh
set -eu

# firecrawl-dns: a shared, network-visible strict-order DNS forwarder for every
# container on the `firecrawl` internal network.
#
# ## The problem
#
# firecrawl-api and playwright-service need to resolve two different classes of name:
# same-network compose service names (redis, rabbitmq, nuq-postgres) AND arbitrary
# external hostnames (whatever URL a scrape/crawl job is given). Docker's own embedded
# DNS (127.0.0.11) answers the first class fine but answers the second with an
# immediate, *definitive* SERVFAIL rather than a timeout, because an `internal: true`
# network gives it no route to forward the query over. Node's own DNS resolution (both
# firecrawl-api and playwright-service are Node processes) does not retry past that
# SERVFAIL onto a second `nameserver` line the way glibc's NSS stack (`getent`) does -
# this is the exact same bug code-docker's own dns-local, roblox-studio-docker and
# code-docker-dind each independently hit against router; see code-docker's own
# CLAUDE.md ("netshare" section) and qwreey/router-docker-client's dns-local/dns-local.sh
# for the fuller writeup and the measurements (0/15 external lookups without this fix,
# 15/15 with it, on the equivalent code-docker-internal case).
#
# ## Why a shared sidecar instead of code-docker's own dns-local
#
# dns-local is a supervisord program that rewrites the /etc/resolv.conf of the SAME
# container it runs inside. firecrawl-api/playwright-service are upstream Firecrawl
# images with no supervisord (or any process manager) to hang a copy of that script off
# of, and rebuilding them just to add one is more moving parts than this needs. Instead,
# this one dnsmasq listens on the network itself (not just 127.0.0.1) at a fixed,
# hand-picked IP (see code-docker-firecrawl.yml's `firecrawl` network comment on why the
# subnet is pinned), and firecrawl-api/playwright-service each point their compose-level
# `dns:` field directly at it - Compose's `dns:` only accepts IP literals, which is the
# whole reason the address has to be known in advance rather than resolved by name.
#
# ## The fix itself
#
# Exactly dns-local's own recipe: dnsmasq in --strict-order mode with 127.0.0.11 (this
# network's own embedded DNS, for compose names) and router's own IP (for everything
# else) as its two --server entries. --strict-order makes dnsmasq retry the second
# server on a SERVFAIL from the first - the retry that Node's own resolver never does -
# so every client downstream sees exactly one nameserver and gets a real answer or a
# real failure. Without --strict-order this would be actively worse than doing nothing:
# dnsmasq's default "fastest responder wins" always prefers 127.0.0.11's instant bogus
# SERVFAIL over a real round trip to router.

ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-router}"

DNSMASQ_PID=""
LAST_ROUTER_IP=""

start_dnsmasq() {
    router_ip="$(getent hosts "$ROUTER_HOSTNAME" 2>/dev/null | awk '{ print $1; exit }')"
    [ -z "$router_ip" ] && return 1
    dnsmasq --no-daemon --no-resolv --strict-order \
        --listen-address=0.0.0.0 --bind-interfaces \
        --server=127.0.0.11 --server="$router_ip" &
    DNSMASQ_PID=$!
    LAST_ROUTER_IP="$router_ip"
}

trap 'kill "$DNSMASQ_PID" 2>/dev/null; exit 0' TERM INT

echo "firecrawl-dns: waiting for '$ROUTER_HOSTNAME' to resolve..."
i=0
until getent hosts "$ROUTER_HOSTNAME" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo >&2 "firecrawl-dns: could not resolve '$ROUTER_HOSTNAME' after 60s - starting anyway, will keep retrying"
        break
    fi
    sleep 2
done

until start_dnsmasq; do
    sleep 2
done
echo "firecrawl-dns: forwarding 127.0.0.11 + router($LAST_ROUTER_IP), strict-order"

# router's own IP isn't stable across recreates (its container can be recreated by a
# rebuild or a network change) - re-resolve every 5s and restart dnsmasq on a change,
# same upkeep loop dns-local runs. A restart-based swap (rather than a SIGHUP/
# --servers-file reload) is a deliberately simple trade: this only happens when router
# itself is recreated, a rare event, for a ~1s DNS blip.
while true; do
    sleep 5
    router_ip="$(getent hosts "$ROUTER_HOSTNAME" 2>/dev/null | awk '{ print $1; exit }')"
    if [ -n "$router_ip" ] && [ "$router_ip" != "$LAST_ROUTER_IP" ]; then
        echo "firecrawl-dns: router IP changed ($LAST_ROUTER_IP -> $router_ip), restarting"
        kill "$DNSMASQ_PID" 2>/dev/null
        wait "$DNSMASQ_PID" 2>/dev/null || true
        start_dnsmasq
    fi
done
