#!/bin/sh
set -eu

# Shared entrypoint wrapper for firecrawl-api and playwright-service.
#
# code-docker-netinit-docker plants a container's default route from OUTSIDE its netns,
# necessarily *after* the container has already started (see code-docker's own CLAUDE.md,
# "docker-compose topology" - the same constraint applies to every netinit.provider
# consumer, not just this repo's). code-docker's own entrypoint.sh and
# roblox-studio-docker's both block on this before starting their real workload
# (NETINIT_WAIT); firecrawl-api and playwright-service are unmodified upstream images
# with no equivalent wait, and both do real network I/O at process startup -
# playwright-service's own `pnpm start` goes through a corepack shim that fetches its
# pinned package manager from registry.npmjs.org on first run if it isn't cached, which
# happens on every fresh container. Measured directly during this repo's own live
# verification (2026-09-28): started without this wrapper, playwright-service raced
# netinit-docker's route-planting and crash-looped on ENETUNREACH/EAI_AGAIN across
# 15+ restart attempts, because `restart: unless-stopped`'s growing backoff outpaced how
# quickly it happened to retry into a window where the route already existed.
#
# The wait condition reads /proc/net/route directly instead of shelling out to `ip route`
# - neither upstream image ships iproute2, and awk/grep (which both already need to be
# present, since firecrawl-api's own harness assumes a POSIX userland) are enough. A
# default route is any entry whose destination field (column 2) is all zeros.
#
# `docker-entrypoint.sh` is the original image's own ENTRYPOINT (both firecrawl-api and
# playwright-service use the same node-image convention) - `exec`ing into it with the
# original CMD preserved as "$@" means this wrapper changes nothing about how either
# image normally starts once the wait is satisfied.

TIMEOUT="${FIRECRAWL_NETINIT_WAIT_TIMEOUT:-60}"
i=0
until awk '$2 == "00000000" { f = 1 } END { exit !f }' /proc/net/route; do
    i=$((i + 1))
    if [ "$i" -ge "$TIMEOUT" ]; then
        echo "wait-for-route: no default route after ${TIMEOUT}s - exiting so restart: unless-stopped retries (fail closed, never running unrouted)" >&2
        exit 1
    fi
    sleep 1
done

exec docker-entrypoint.sh "$@"
