#!/usr/bin/env bash
set -euo pipefail

# Everything past the exec at the bottom is supervisord's job (config/supervisord.conf +
# config/supervisord.d/*.conf). This script only does what must happen once, before any
# program starts - same split code-docker-chrome's entrypoint.sh uses, and the same
# reasoning: this image only ever exists as a code-docker provider sitting behind router,
# so NETINIT_WAIT defaults to on rather than off (there is no standalone deployment of
# this image today).

# Block until code-docker's netinit-docker (host-side agent, matched by the
# netinit.provider label in code-docker-firecrawl.yml) has planted this container's
# default route. That agent necessarily runs *after* the container starts, so without
# this wait firecrawl-api/playwright-service could start fetching before the egress
# policy exists.
#
# Fail-closed: exit non-zero so `restart: unless-stopped` retries, rather than continuing
# unrouted. Reading `ip route` needs no capability; only the provider needs NET_ADMIN,
# and it deliberately lives outside this container.
if [[ "${NETINIT_WAIT:-true}" == "true" ]]; then
	timeout_s="${NETINIT_WAIT_TIMEOUT:-60}"
	waited=0
	while ! ip route show default 2>/dev/null | grep -q .; do
		if (( waited >= timeout_s )); then
			echo >&2 "entrypoint: no default route after ${timeout_s}s - the netinit provider never planted one. Refusing to start Firecrawl unrouted; exiting so restart: unless-stopped retries."
			exit 1
		fi
		if (( waited == 0 )); then
			echo "entrypoint: waiting for the netinit provider to plant a default route..."
		fi
		sleep 2
		waited=$(( waited + 2 ))
	done
	echo "entrypoint: default route present ($(ip route show default | head -1)) - continuing"
fi

# The postgres data directory lives on a volume (see code-docker-firecrawl.yml), which
# Docker hands to a fresh container as a root-owned, empty directory - postgres-service.sh
# runs as the unprivileged `postgres` user (see config/supervisord.d/postgres.conf) and
# cannot chown it itself. This is the one piece of root-only setup this image needs;
# CAP_CHOWN is the only capability it costs (see CLAUDE.md's capability accounting).
#
# Only the directory itself, and only when postgres doesn't already own it: after the
# first boot initdb leaves it postgres-owned and mode 0700, and root without
# CAP_DAC_READ_SEARCH (dropped - cap_drop: ALL) can't even list it, so a recursive
# chown on every start failed and crash-looped the container on its first restart.
PGDATA_DIR="${PGDATA:-/data/postgres}"
mkdir -p "${PGDATA_DIR}"
pg_uid="$(id -u postgres)"
dir_uid="$(stat -c %u "${PGDATA_DIR}")"
if [ "$dir_uid" != "$pg_uid" ]; then
	if [ "$dir_uid" != 0 ]; then
		# Owned by some other uid: data from a different postgres (e.g. this repo's older
		# multi-container layout used the official image, uid 999). Re-owning it would
		# only hand this postgres files it can't necessarily use - say so and stop.
		echo "entrypoint: ${PGDATA_DIR} belongs to uid $dir_uid, not this image's postgres ($pg_uid) - it holds another postgres install's data. Remove the volume (docker volume rm <prefix>code-docker-firecrawl-postgres-data) to start fresh."
		exit 1
	fi
	chown postgres:postgres "${PGDATA_DIR}"
fi

# /var/run/postgresql is where postgres puts its Unix socket - also root-owned on a fresh
# container if it isn't already there from the image layer (it usually is, from the apt
# package's own postinst, but a defensive mkdir+chown costs nothing).
mkdir -p /var/run/postgresql
chown -R postgres:postgres /var/run/postgresql

echo "[entrypoint] handing off to supervisord"
exec supervisord -n -c /etc/code-docker-firecrawl/supervisord.conf
