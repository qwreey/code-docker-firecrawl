#!/bin/bash
set -euo pipefail

# Postgres 17 + pg_cron, running the nuq queue's schema - reproduces what upstream's
# apps/nuq-postgres/Dockerfile bakes into its own image (see that file), except done as a
# first-boot step against a real data volume instead of docker-entrypoint-initdb.d/, since
# there is no separate container here to own that Dockerfile's job.
#
# Idempotent: only runs initdb when PGDATA is empty (PG_VERSION missing), and only runs
# nuq.sql when its own marker file is missing - see CLAUDE.md. The two are checked
# independently, not "initdb happened, therefore assume nuq.sql did too": a marker file
# that's only written after nuq.sql actually succeeds is what lets a partial failure
# between initdb and nuq.sql (found live during this image's own verification - see the
# comment above the temporary pg_ctl start below) surface loudly on the next restart
# instead of silently looking like a completed first boot forever after.

PGDATA="${PGDATA:-/data/postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
PG_BIN="/usr/lib/postgresql/17/bin"
NUQ_SQL_MARKER="${PGDATA}/.code-docker-firecrawl-nuq-sql-applied"

# initdb's --auth=scram-sha-256 below applies to BOTH local (Unix socket) and host (TCP)
# connections - unlike the common assumption that local connections are trusted by
# default, a real password is required even for `psql` connecting over the socket from
# this very script. Found live: without this, `psql`/`createdb` printed "Password for
# user postgres:" to a script with no tty and no stdin, which - being non-interactive -
# failed authentication silently under `set -e`, in the same "exit, get restarted,
# masked by the marker/PG_VERSION check" way the log-path bug above did.
export PGPASSWORD="${POSTGRES_PASSWORD}"

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
	echo "[postgres-service] no existing data directory at ${PGDATA} - running initdb (first boot)"

	pwfile="$(mktemp)"
	printf '%s' "${POSTGRES_PASSWORD}" > "${pwfile}"
	"${PG_BIN}/initdb" -D "${PGDATA}" -U "${POSTGRES_USER}" \
		--pwfile="${pwfile}" --auth=scram-sha-256 --encoding=UTF8
	rm -f "${pwfile}"

	# Loopback-only (see CLAUDE.md's port/capability table) and pg_cron preloaded -
	# shared_preload_libraries can only be set before the FIRST start, which is why this
	# has to happen before the temporary start below rather than after.
	{
		echo ""
		echo "# code-docker-firecrawl"
		echo "listen_addresses = '127.0.0.1'"
		echo "shared_preload_libraries = 'pg_cron'"
		echo "cron.database_name = '${POSTGRES_DB}'"
	} >> "${PGDATA}/postgresql.conf"
else
	echo "[postgres-service] existing data directory found at ${PGDATA} - skipping initdb"
fi

if [ ! -f "${NUQ_SQL_MARKER}" ]; then
	# /tmp, not /var/log/postgres, for pg_ctl's own startup log - that directory is
	# root-owned (created by the Dockerfile before any user exists to chown it to), and
	# this script runs as the unprivileged `postgres` user. supervisord's own stdout/
	# stderr redirection for this program lands in /var/log/postgres fine regardless,
	# because supervisord (root) opens those files itself before dropping privilege for
	# this script - but `pg_ctl -l` here is a second, independent file open done BY this
	# already-unprivileged script, which can't create a new file in a directory it has
	# no write permission on. Found live during this image's own verification: this
	# failed with "Permission denied", which made `pg_ctl start` fail, which (under
	# `set -e`) exited the whole script before nuq.sql ever ran - and because initdb had
	# already completed, supervisord's automatic restart of this program used to take
	# the (then-single) "existing data directory, skip init" branch and start postgres
	# for real anyway, masking the failure completely except for one easy-to-miss log
	# line. The separate marker file below is what closes that gap: a repeat of this
	# class of failure now leaves the marker missing, so the *next* restart retries
	# nuq.sql instead of quietly treating "the data directory exists" as "nuq.sql ran".
	echo "[postgres-service] nuq.sql not yet applied - starting postgres temporarily to run it"
	"${PG_BIN}/pg_ctl" -D "${PGDATA}" -l /tmp/pg-initdb-start.log -w start

	if [ "${POSTGRES_DB}" != "${POSTGRES_USER}" ]; then
		db_exists="$("${PG_BIN}/psql" -tAc \
			"SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}'" \
			-U "${POSTGRES_USER}" -d postgres)"
		if [ "${db_exists}" != "1" ]; then
			"${PG_BIN}/createdb" -U "${POSTGRES_USER}" "${POSTGRES_DB}"
		fi
	fi
	"${PG_BIN}/psql" -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
		-f /opt/firecrawl/nuq.sql

	"${PG_BIN}/pg_ctl" -D "${PGDATA}" -w stop
	touch "${NUQ_SQL_MARKER}"
	echo "[postgres-service] nuq.sql applied"
else
	echo "[postgres-service] nuq.sql marker present - skipping (already applied)"
fi

exec "${PG_BIN}/postgres" -D "${PGDATA}"
