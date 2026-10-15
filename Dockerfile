# Self-hosted Firecrawl (https://github.com/firecrawl/firecrawl) as ONE supervisord-managed
# container, Nextcloud-AIO-style, instead of the seven-container compose stack the previous
# design used (postgres, redis, playwright-service, firecrawl-api, a DNS forwarder sidecar,
# a bearer-token nginx front, plus rabbitmq). See CLAUDE.md for the full "why" - this header
# only orients the stage list below.
#
# Every `apps/<x>` upstream source directory is fetched directly as its own build context,
# pinned to a real git tag (not `main`): Firecrawl publishes no separate "stable" branch,
# so a tag is the only reproducible anchor. `ADD <git-url>#<ref>:<subdir> /` is the same
# mechanism code-docker's own root Dockerfile uses for router-docker-client subdirectories -
# see that file's own comment on the `netshare`/`dns-local` stages. Each upstream app
# directory becomes its own `FROM scratch` stage so a BuildKit named context of the same
# name can replace it later (a local checkout for offline/dev builds), the same override
# hook code-docker's root Dockerfile gives router-docker-client and code-server-autoinstall.
ARG FIRECRAWL_REF=v2.11.408

FROM scratch AS firecrawl-api-src
ARG FIRECRAWL_REF
ADD https://github.com/firecrawl/firecrawl.git#${FIRECRAWL_REF}:apps/api /

FROM scratch AS firecrawl-playwright-src
ARG FIRECRAWL_REF
ADD https://github.com/firecrawl/firecrawl.git#${FIRECRAWL_REF}:apps/playwright-service-ts /

FROM scratch AS firecrawl-nuq-postgres-src
ARG FIRECRAWL_REF
ADD https://github.com/firecrawl/firecrawl.git#${FIRECRAWL_REF}:apps/nuq-postgres /

# dns-local is what gives this container working DNS for the two fetchers (api,
# playwright-service) while it sits on an `internal: true` network behind router - same
# mechanism and same reason code-docker-chrome carries it. Fetched, not vendored, for the
# same reason as there: it isn't specific to this project. Pinned to that repo's release
# tag (see its own CLAUDE.md); code-docker's dev-bump-router-client.sh moves this default.
FROM scratch AS dns-local
ARG ROUTER_CLIENT_REF=v0.1.1
ADD https://github.com/qwreey/router-docker-client.git#${ROUTER_CLIENT_REF}:dns-local /
FROM scratch AS netshare
ARG ROUTER_CLIENT_REF=v0.1.1
ADD https://github.com/qwreey/router-docker-client.git#${ROUTER_CLIENT_REF}:netshare /

# ---- Go shared library (apps/api/sharedLibs/go-html-to-md) ----
# Reproduces apps/api/Dockerfile's `go-build` stage exactly.
FROM golang:1.24 AS go-build
WORKDIR /app
COPY --from=firecrawl-api-src /sharedLibs/go-html-to-md ./sharedLibs/go-html-to-md
RUN cd sharedLibs/go-html-to-md && \
    go mod download && \
    go build -o libhtml-to-markdown.so -buildmode=c-shared html-to-markdown.go

# ---- api build (apps/api/Dockerfile's `build` stage) ----
# node:22-slim/bookworm-slim, matching apps/api/Dockerfile's own `FROM node:22-slim AS
# base` - the final image below is also bookworm-slim, so runtime libs line up.
FROM node:22-bookworm-slim AS api-build
ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH" \
    CI=true
RUN corepack enable && corepack prepare pnpm@11.4.0 --activate
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      build-essential \
      pkg-config \
      python3 \
    && rm -rf /var/lib/apt/lists/*

# FoundationDB client library - only needed so `pnpm install` can build the optional
# `foundationdb` npm dependency's native binding. This image never sets NUQ_BACKEND=fdb
# (nuq-postgres is the only backend wired up here, see CLAUDE.md), and
# apps/api/src/services/worker/nuq-fdb/client.ts only `require("foundationdb")` lazily
# when that backend is actually selected - but skipping this would make `pnpm install`
# itself fail on this dependency, so it stays, matching upstream's own build stage.
ARG FDB_VERSION=7.3.63
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in arm64) FDB_ARCH=aarch64 ;; *) FDB_ARCH=$ARCH ;; esac && \
    curl -fsSL -o /tmp/fdb-clients.deb \
      "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_${FDB_ARCH}.deb" && \
    dpkg -i /tmp/fdb-clients.deb && rm /tmp/fdb-clients.deb

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
    && chmod -R a+w $RUSTUP_HOME $CARGO_HOME

# Dependency inputs first (native/ included - its install script builds the Rust addon),
# so source-only changes below don't invalidate the pnpm install layer.
COPY --from=firecrawl-api-src /pnpm-lock.yaml /pnpm-workspace.yaml /package.json ./
COPY --from=firecrawl-api-src /patches ./patches
COPY --from=firecrawl-api-src /native ./native
RUN --mount=type=cache,id=firecrawl-pnpm,target=/pnpm/store \
    --mount=type=cache,id=firecrawl-cargo,target=/usr/local/cargo/registry \
    --mount=type=cache,id=firecrawl-native-target,target=/app/native/target \
    pnpm install --frozen-lockfile

COPY --from=firecrawl-api-src / .

# Loopback-only patch, not an upstream behavior: apps/api/src/index.ts already binds
# `config.HOST` (which we leave at its "localhost" default below, see firecrawl.conf's
# env - upstream's own compose overrides it to 0.0.0.0 because there the api container is
# reached over the network by a separate nginx container; here nginx is a sibling program
# in the SAME container reaching it over loopback, so that override doesn't apply). But
# every worker started by the harness alongside it - worker, extract-worker, the nuq
# workers, the nuq prefetch/reconciler workers - opens its own small health/metrics HTTP
# server with a bare `app.listen(port)`, no host argument, which Node binds to every
# interface. None of those are meant to be reachable from outside this container at all
# (nginx never proxies to them), so a single-container `ss -ltnp` audit would otherwise
# show several 0.0.0.0 listeners with no gate in front of them. Patched at the TypeScript
# source level, before `tsc` compiles it, rather than left as a runtime env knob, because
# none of these call sites read one. `node -e` throws (failing the build) if a given
# pattern isn't found, rather than silently leaving a listener wide open on a future
# upstream refactor.
RUN node -e ' \
    const fs = require("fs"); \
    const files = [ \
      "src/services/extract-worker.ts", \
      "src/services/queue-worker.ts", \
      "src/services/cclog-worker.ts", \
      "src/services/worker/nuq-worker-runner.ts", \
      "src/services/worker/nuq-prefetch-worker.ts", \
      "src/services/worker/nuq-reconciler-worker.ts", \
    ]; \
    for (const f of files) { \
      const before = fs.readFileSync(f, "utf8"); \
      const after = before.replace(/app\.listen\(\s*([\w.]+),/, "app.listen($1, \"127.0.0.1\","); \
      if (after === before) throw new Error("app.listen(...) pattern not found in " + f + " - upstream may have changed this call site"); \
      fs.writeFileSync(f, after); \
    } \
    console.log("patched " + files.length + " worker listen() calls to bind 127.0.0.1 only"); \
  '

# Third patch, found only by actually running the no-RabbitMQ design end to end (not
# obvious from reading nuq.ts alone - see CLAUDE.md's "Open questions"/surprises list):
# extract-worker.ts's own top-level IIFE calls consumeExtractJobs()/consumeExtractDLQ()
# unconditionally at startup, and apps/api/src/services/extract-queue.ts's getChannel()
# throws "NUQ_RABBITMQ_URL is not configured" the instant that runs with no RabbitMQ
# configured - completely independent of NUQ_WAIT_MODE, which only affects nuq's own
# scrape/crawl queue (postgres-backed here), not the separate RabbitMQ-only queue the
# LLM-backed /extract endpoint uses. Because harness.ts's waitForTermination() does
# `Promise.race()` across every service it started, one crashing service (extract-worker)
# tears down api/worker/every nuq-worker/prefetch/reconciler right along with it - so
# without this patch, the entire harness crash-loops forever the moment RabbitMQ is
# absent, not just the /extract feature. Patched to skip queue consumption (with a clear
# log line) when NUQ_RABBITMQ_URL is unset, instead of adding RabbitMQ back just to keep
# one LLM-only endpoint theoretically reachable - /extract remains genuinely unsupported
# in this image (see CLAUDE.md), the same documented trade-off as the optional OpenAI key.
RUN node -e ' \
    const fs = require("fs"); \
    const f = "src/services/extract-worker.ts"; \
    const before = fs.readFileSync(f, "utf8"); \
    const needle = "  _logger.info(\"Starting extract worker with RabbitMQ...\");\n\n  // Start consuming from both the main queue and the DLQ\n  await Promise.all([\n    consumeExtractJobs(processExtractJob),\n    consumeExtractDLQ(processDLQJob),\n  ]);\n\n  _logger.info(\"Extract worker started, consuming from RabbitMQ\");"; \
    if (!before.includes(needle)) throw new Error("extract-worker.ts IIFE body not found verbatim - upstream may have changed this file"); \
    const replacement = "  if (!config.NUQ_RABBITMQ_URL) {\n    _logger.warn(\"NUQ_RABBITMQ_URL is not configured - extract-worker will not consume jobs; the /extract endpoint is unsupported in this deployment (see code-docker-firecrawl CLAUDE.md). scrape/crawl/map are unaffected.\");\n    return;\n  }\n\n" + needle; \
    fs.writeFileSync(f, before.replace(needle, replacement)); \
    console.log("patched extract-worker.ts to degrade gracefully without RabbitMQ"); \
  '

# Fourth patch, found the same way (a crawl that never left "scraping" in the stack test):
# nuq-prefetch-worker's prefetchJobs() claims up to 500 queued jobs - flips them to
# status 'active' with a fresh lock - and then hands them to RabbitMQ. With no RabbitMQ
# the hand-off only logs "NuQ sender not started", so those jobs sit locked and
# undelivered, while the workers' own postgres fallback (getJobToProcess) only ever
# selects 'queued' rows: every job the prefetcher touched is stranded until its lock
# expires and the reconciler requeues it - for the prefetcher to grab again. Without
# RabbitMQ there is nothing to prefetch into, so the worker idles instead (waits
# forever rather than exiting, since the harness treats any service ending as fatal)
# and the workers poll postgres directly, which is the path nuq falls back to anyway.
RUN node -e ' \
    const fs = require("fs"); \
    const f = "src/services/worker/nuq-prefetch-worker.ts"; \
    const before = fs.readFileSync(f, "utf8"); \
    const needle = "  try {\n    await Promise.all([\n      (async () => {\n        while (true) {\n          await crawlFinishedQueue.prefetchJobs();"; \
    if (!before.includes(needle)) throw new Error("nuq-prefetch-worker.ts prefetch loop not found verbatim - upstream may have changed this file"); \
    const replacement = "  if (!config.NUQ_RABBITMQ_URL) {\n    logger.warn(\"NUQ_RABBITMQ_URL is not configured - prefetch worker idles; workers take jobs straight from postgres (see code-docker-firecrawl CLAUDE.md)\");\n    await new Promise(() => {});\n  }\n\n" + needle; \
    fs.writeFileSync(f, before.replace(needle, replacement)); \
    console.log("patched nuq-prefetch-worker.ts to idle without RabbitMQ"); \
  '

RUN rm -rf dist && pnpm run build
RUN test -s dist/src/harness.js && test -s dist/src/controllers/v0/crawl-status.js
RUN pnpm prune --prod --ignore-scripts

# ---- playwright-service build (apps/playwright-service-ts/Dockerfile) ----
FROM node:22-bookworm-slim AS playwright-build
ENV PNPM_HOME="/pnpm" \
    PATH="/pnpm:$PATH" \
    CI=true
RUN corepack enable && corepack prepare pnpm@11.4.0 --activate
WORKDIR /usr/src/app
COPY --from=firecrawl-playwright-src /package.json /pnpm-lock.yaml /pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY --from=firecrawl-playwright-src / .

ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright
# `--with-deps` does two things in one shot: downloads the chromium build Playwright's
# own version pins to (landing under PLAYWRIGHT_BROWSERS_PATH, copied into the final
# image below) AND apt-installs the OS shared libraries chromium needs (landing in this
# stage's own /usr, NOT copied - the final stage re-runs `playwright install-deps` for
# just the apt half so those shared libraries actually exist there; the point of doing it
# here at all is only to get the deb list into apt's cache/dpkg status quo verified once).
# Same loopback-only reasoning as the api-build stage's patch above: api.ts's
# `app.listen(port)` has no host argument and no env knob for one, and this service is
# only ever meant to be reached from firecrawl-api over loopback (PLAYWRIGHT_MICROSERVICE_
# URL=http://127.0.0.1:3000/scrape - see firecrawl.conf), never from outside this
# container. The SSRF proxy this file also starts (Server({host: '127.0.0.1', ...}))
# already binds loopback on its own; this is the one remaining listener that doesn't.
RUN node -e ' \
    const fs = require("fs"); \
    const before = fs.readFileSync("api.ts", "utf8"); \
    const after = before.replace(/app\.listen\(\s*([\w.]+),/, "app.listen(Number($1), \"127.0.0.1\","); \
    if (after === before) throw new Error("app.listen(...) pattern not found in api.ts - upstream may have changed this call site"); \
    fs.writeFileSync("api.ts", after); \
    console.log("patched playwright-service api.ts to bind 127.0.0.1 only"); \
  '

RUN pnpm exec playwright install chromium --with-deps
RUN pnpm run build

# ---- final image ----
# Debian, not code-docker's usual Arch - PGDG's postgresql-17-cron package and
# Playwright's `playwright install-deps`/`--with-deps` machinery both assume an apt-based
# host; reproducing either from scratch on Arch would mean re-deriving the chromium
# runtime dependency list and pg_cron's build by hand instead of using either project's
# own tooling. node:22-bookworm-slim keeps the runtime's glibc/node build identical to
# both build stages above.
FROM node:22-bookworm-slim

ARG FIRECRAWL_REF=v2.11.408
LABEL org.opencontainers.image.source="https://github.com/firecrawl/firecrawl" \
      org.opencontainers.image.version="${FIRECRAWL_REF}"

# Base tools + the PGDG apt repo (Debian bookworm's own postgres package tops out below
# 17, and the pg_cron combination upstream's own nuq-postgres/Dockerfile relies on needs
# a matching postgresql-<major>-cron build). postgresql-common ships the official
# apt.postgresql.org bootstrap script; running it is the documented way to add the repo
# rather than hand-rolling the sources.list entry + keyring.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release wget \
    && apt-get install -y --no-install-recommends postgresql-common \
    && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
    && apt-get update && apt-get install -y --no-install-recommends \
      postgresql-17 postgresql-client-17 postgresql-17-cron \
      redis-server \
      nginx-light \
      dnsmasq \
      supervisor \
      iproute2 \
      procps \
      git \
    && rm -rf /var/lib/apt/lists/*

# Same FoundationDB client as the api-build stage. Kept at runtime purely for parity with
# upstream's own runtime stage and because apps/api/src/services/worker/nuq-fdb/client.ts
# only lazy-`require`s the npm module (never eagerly, and NUQ_BACKEND stays unset here) -
# see that stage's comment for the fuller reasoning. Small (one .deb), so the safety
# margin is worth the few extra MB.
ARG FDB_VERSION=7.3.63
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in arm64) FDB_ARCH=aarch64 ;; *) FDB_ARCH=$ARCH ;; esac && \
    curl -fsSL -o /tmp/fdb-clients.deb \
      "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_${FDB_ARCH}.deb" && \
    dpkg -i /tmp/fdb-clients.deb && rm /tmp/fdb-clients.deb

ENV PATH="/usr/lib/postgresql/17/bin:${PATH}"

# ---- api runtime artifacts ----
WORKDIR /opt/firecrawl/api
COPY --chown=node:node --from=api-build /app/node_modules ./node_modules
COPY --chown=node:node --from=api-build /app/dist ./dist
COPY --chown=node:node --from=api-build /app/native ./native
COPY --chown=node:node --from=go-build /app/sharedLibs/go-html-to-md/libhtml-to-markdown.so ./sharedLibs/go-html-to-md/
RUN node -e 'const fs = require("fs"); for (const p of ["dist/src/harness.js", "dist/src/controllers/v0/crawl-status.js"]) { if (!fs.statSync(p).size) throw new Error(p + " missing or empty"); }'

# ---- playwright-service runtime artifacts ----
WORKDIR /opt/firecrawl/playwright
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright
COPY --from=playwright-build /usr/local/share/playwright /usr/local/share/playwright
COPY --chown=node:node --from=playwright-build /usr/src/app/node_modules ./node_modules
COPY --chown=node:node --from=playwright-build /usr/src/app/dist ./dist
# The build stage's own `playwright install --with-deps` already proved which packages
# chromium needs and left them in APT's cache metadata; this re-run against the SAME
# node_modules/playwright driver installs only the OS shared libraries (`install-deps`
# never re-downloads the browser itself) into this final layer, which the copied-in
# browser binary above actually needs to execute here.
RUN apt-get update \
    && node_modules/.bin/playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/*
RUN chmod -R a+rX /usr/local/share/playwright

# nuq-postgres' own initdb SQL - the only thing this image needs from that upstream app
# directory (see CLAUDE.md: pg_cron/shared_preload_libraries are configured by this
# image's own postgres-service.sh instead of nuq-postgres/Dockerfile, since we run
# postgres directly rather than via that Dockerfile).
COPY --from=firecrawl-nuq-postgres-src /nuq.sql /opt/firecrawl/nuq.sql

# dns-local + netshare, same layout code-docker-chrome uses.
COPY --from=dns-local / /etc/code-docker-firecrawl/router-client/dns-local/
COPY --from=netshare / /etc/code-docker-firecrawl/router-client/netshare/
RUN chmod +x /etc/code-docker-firecrawl/router-client/dns-local/dns-local.sh

# Per-program rotated log dirs, matching supervisord.d/*.conf's stdout_logfile paths.
# Root-owned, because supervisord (root) is what writes into them, and root here has no
# CAP_DAC_OVERRIDE (cap_drop: ALL): it can't write into a directory some other user owns.
# /var/log/redis comes from the redis package as redis:adm 2750, so mkdir -p alone left
# supervisord unable to create redis's log file - the program went FATAL. For the same
# reason nginx's packaged logs, www-data-owned files it opens as root before reading any
# config, are pointed at stdout/stderr instead (plus `-e` in nginx-gate-service.sh).
RUN mkdir -p /var/log/postgres /var/log/redis /var/log/playwright /var/log/firecrawl \
      /var/log/nginx-gate /var/log/dns-local \
 && chown root:root /var/log/redis && chmod 0755 /var/log/redis \
 && sed -i -e 's|^error_log /var/log/nginx/error.log;|error_log /dev/stderr;|' \
      -e 's|access_log /var/log/nginx/access.log;|access_log /dev/stdout;|' /etc/nginx/nginx.conf \
 && grep -q '^error_log /dev/stderr;' /etc/nginx/nginx.conf

COPY config/supervisord.conf /etc/code-docker-firecrawl/supervisord.conf
COPY config/supervisord.d/ /etc/code-docker-firecrawl/supervisord.d/
COPY config/supervisor/ /etc/code-docker-firecrawl/
COPY config/nginx/firecrawl.conf.template /etc/code-docker-firecrawl/nginx/firecrawl.conf.template
COPY entrypoint.sh /etc/code-docker-firecrawl/entrypoint.sh
RUN chmod +x /etc/code-docker-firecrawl/entrypoint.sh /etc/code-docker-firecrawl/*-service.sh

ENV HOME=/root

ENTRYPOINT ["/etc/code-docker-firecrawl/entrypoint.sh"]
