# CLAUDE.md

## What this is

A **code-docker plugin**, not a Firecrawl distribution - but as of the 2026-09-28 AIO
rewrite, it builds Firecrawl from source (pinned to a git tag) rather than running
upstream's prebuilt images unmodified. [Firecrawl](https://github.com/firecrawl/firecrawl)
(scrape/crawl-to-markdown API) runs as **one** supervisord-managed container
(Nextcloud-AIO style: postgres, redis, playwright-service and the api harness are all
programs inside it), not the seven-container compose stack this repo used before. See
"Why AIO, and what changed" below for the full reasoning.

- `Dockerfile` - multi-stage build. Fetches `apps/api`, `apps/playwright-service-ts` and
  `apps/nuq-postgres` directly from upstream's git repo at a pinned tag (`FIRECRAWL_REF`
  build arg, default `v2.11.408`), reproduces each app's own Dockerfile build recipe in
  its own stage, and assembles the runtime artifacts into one Debian (not code-docker's
  usual Arch) final image. See "Why Debian" below.
- `entrypoint.sh` + `config/` - the supervisord layout. Same shape as
  `code-docker-chrome`: `config/supervisord.conf` + `config/supervisord.d/*.conf` (one
  `[program:...]` per file) + `config/supervisor/*.sh` (the actual service scripts) +
  `config/nginx/`.
- `code-docker-firecrawl.yml` - the compose overlay code-docker's `EXTRA_INCLUDE` chain
  pulls in. No standalone `docker-compose.yml`, same asymmetry as `code-docker-trilium`.
- `docker/firecrawl-proxy/` - `firecrawl-front`, now a plain network bridge (no auth logic
  of its own - see below).
- `ootb-manifest.env` - read by code-docker's `ootb.sh`/`migrate.sh`.

`README.md` is the user-facing doc and the single source of truth for setup and what the
token actually protects - keep it in sync when changing the overlay.

## Why AIO, and what changed

The previous design ran upstream's own images unmodified, each as its own container:
`firecrawl-api`, `playwright-service`, `redis`, `rabbitmq`, `nuq-postgres`, plus two
non-upstream containers this repo had to invent (`firecrawl-dns`, a DNS forwarder
sidecar, and `firecrawl-front`, a bearer-token gate). That worked, but it meant carrying
real infrastructure (a pinned subnet, a static-IP DNS forwarder, a route-wait wrapper
script around two upstream entrypoints) purely to compensate for upstream images having
no process manager of their own to hang code-docker's usual house tricks off of.

Building from source removes that constraint: once this repo controls the build, it can
put a real init system (supervisord) inside the fetcher container itself, and every one
of those workarounds either disappears or turns into the same mechanism code-docker's
other providers already use:

| Old design | AIO design |
|---|---|
| `rabbitmq` container (NUQ_RABBITMQ_URL) | Gone. `NUQ_WAIT_MODE=listen` makes nuq's own `waitForJob()` use postgres `LISTEN`/`NOTIFY` instead (`apps/api/src/services/worker/nuq.ts`'s `nuqWaitMode`) - verified this still completes real crawl/scrape jobs, see "Verification" below. |
| `firecrawl-dns` sidecar + pinned subnet + `ip_range` | Gone. `dns-local` (the same program `code-docker-chrome` runs) rewrites the AIO container's *own* `/etc/resolv.conf` - no separate container, no static IP, no reason to pin the network's subnet anymore. |
| `docker/wait-for-route.sh` wrapping both fetchers' entrypoints | Gone. `entrypoint.sh` blocks on `NETINIT_WAIT` **before supervisord starts anything**, same as `code-docker-chrome` - by the time any program inside runs, the route already exists. The old wrapper existed because upstream's images started fetching immediately on their own, with nothing else in the container able to gate that. |
| `redis`/`nuq-postgres` as separate containers, `firecrawl-api` reaching them by compose service name | `redis-server`/`postgres` as supervisord programs, reached over `127.0.0.1` - no network hop, no DNS needed for them at all. |
| `firecrawl-front` checks the bearer token | The AIO container's own `nginx-gate` program checks it, right in front of the api's own (now internal-only) port. `firecrawl-front` is now a dumb bridge - see its own section below. |

Firecrawl's own `docker-compose.yaml` is still the reference for defaults (env var names,
concurrency knobs, resource limits) - this repo just runs the same processes inside one
container instead of several.

## Why this still lives outside dind, not inside

Unchanged from before: Firecrawl's fetchers (the api harness's worker processes and
playwright-service) exist to fetch **attacker-influenced URLs**, including redirects they
follow themselves. `code-docker-internal` is not a safe place for that: `dind:2375` is an
unauthenticated Docker API there, and code-docker's nginx (code-server, webmanager - no
login by default) answers there too. A private network only isolates because router's
front door refuses every network but its outward-facing one (router-docker v0.1.1) -
before that, `http://router/` from this network reached code-server. And dind's nested containers all share one daemon/bridge with no cheap way to carve
out per-container egress the way code-docker's own `netinit.provider`/`netinit.gateway`
labels do. So the AIO container still gets its own sibling-level `internal: true` network
(`firecrawl`), not a construct living inside dind.

## Why Debian, not Arch

Every other code-docker provider (`code-docker-chrome`, code-docker itself) is Arch-based.
This one isn't, for two concrete reasons rather than a general policy change:

- **PGDG's `postgresql-17-cron` package** is what upstream's own `apps/nuq-postgres/
  Dockerfile` builds on (`FROM postgres:17` + `apt-get install postgresql-17-cron`).
  Reproducing that combination on Arch would mean hand-building `pg_cron` from source
  against Arch's own postgres package version, re-deriving something PGDG already
  maintains and version-matches.
- **Playwright's `playwright install chromium --with-deps` / `playwright install-deps`**
  machinery is apt-based - it knows exactly which Debian/Ubuntu packages a given
  chromium build needs and installs them itself. Arch has no equivalent tooling; getting
  this right by hand means tracking Playwright's own dependency list release over
  release.

`node:22-bookworm-slim` is the base for every stage (build and final) so the runtime's
glibc/node build matches what was actually compiled/tested against.

## The build

`ARG FIRECRAWL_REF=v2.11.408` pins the exact upstream commit; `apps/api`,
`apps/playwright-service-ts` and `apps/nuq-postgres` are each fetched as their own
`FROM scratch` stage via `ADD https://github.com/firecrawl/firecrawl.git#${FIRECRAWL_REF}:
<subdir> /` - the same git-context mechanism code-docker's own root Dockerfile uses for
router-docker-client subdirectories, except pinned to a real tag instead of a floating
`#main` ref (Firecrawl publishes no separate "stable" branch to float against - see "Open
questions" below on what that tag actually means upstream).

Each app's own Dockerfile build recipe is reproduced as closely as possible in its own
stage (`go-build` for the Go html-to-markdown shared library, `api-build`, `playwright-
build`), then only the runtime artifacts (`node_modules`, `dist`, the Go `.so`, the
Playwright browser cache) are copied into the single final stage - `apps/nuq-postgres`
contributes only its `nuq.sql` (this image runs postgres directly rather than via that
app's own Dockerfile, since pg_cron/`shared_preload_libraries` setup happens in
`postgres-service.sh` instead - see below).

### Four source patches - the one place this repo deviates from "upstream code
unmodified"

All three are applied to the TypeScript source, before `tsc` compiles it, and all three
are mechanical (`node -e` scripts that `throw` if the expected pattern isn't found, so an
upstream refactor fails the build loudly rather than silently losing the fix):

- **`apps/api`, loopback binding**: every harness-spawned worker that exposes its own
  small health/metrics HTTP endpoint (`worker`, `extract-worker`, the nuq worker/
  prefetch/reconciler processes) calls a bare `app.listen(port)` with no host argument,
  which Node binds to every interface. None of these are meant to be reachable from
  outside the container at all (nginx never proxies to them) - patched to
  `app.listen(port, "127.0.0.1")`. The main api process itself (`apps/api/src/index.ts`)
  already reads `config.HOST`, so it needs no source patch - just leaving `HOST` at its
  own default (see "Ports" below).
- **`apps/playwright-service-ts`, loopback binding**: `api.ts`'s own `app.listen(port)`
  has the same problem and no env knob for a host. Its SSRF proxy
  (`Server({host: '127.0.0.1', ...})`) already binds loopback correctly on its own.
- **`apps/api`, extract-worker's unconditional RabbitMQ dependency**: found only by
  actually running the no-RabbitMQ design end to end, not by reading `nuq.ts` - see the
  "Upstream-behavior surprises" entry under "Verification" below for the full mechanism.
  `extract-worker.ts`'s startup IIFE is patched to skip `consumeExtractJobs()`/
  `consumeExtractDLQ()` (with a clear log line) when `NUQ_RABBITMQ_URL` is unset, instead
  of crash-looping the entire harness.

Everything else is byte-for-byte upstream source.

## Ports and process list (inside the AIO container)

| Program | Bind | Notes |
|---|---|---|
| `dns-local` | rewrites `/etc/resolv.conf`, dnsmasq on `127.0.0.1:53` | priority 5 |
| `postgres` | `127.0.0.1:5432` | priority 10, runs as `postgres` |
| `redis` | `127.0.0.1:6379` | priority 10, runs as `redis`, no persistence |
| `playwright` | `127.0.0.1:3000` (`FIRECRAWL_PLAYWRIGHT_PORT`) | priority 20, runs as `node` |
| `firecrawl` (api harness) | api on `127.0.0.1:3902` (`FIRECRAWL_API_PORT`); worker/extract-worker/nuq-workers/prefetch/reconciler also loopback-only (see the source patch above) | priority 30, runs as `node` |
| `nginx-gate` | `0.0.0.0:3002` (`FIRECRAWL_GATE_PORT`) | priority 80, runs as root (nginx's own package drops to `www-data` internally) |

`FIRECRAWL_GATE_PORT` (3002) is the only thing meant to be reachable from outside this
container - verified with `ss -ltnp` (see "Verification" below). The api's own `PORT`
moved off upstream's default 3002 specifically so nginx-gate could keep that number: `PORT
3002` on `0.0.0.0` and `PORT 3902` on `127.0.0.1` can't coexist on the same host (a
wildcard bind on a port conflicts with a more specific bind on the same port), so one of
the two had to move, and nginx-gate is the one callers actually need to find at a stable,
documented number.

## Capabilities

`cap_drop: [ALL]` plus a specific `cap_add` list, rather than either running fully
capable or trying for `cap_drop: ALL` with nothing added back:

- **`CHOWN`** - `entrypoint.sh` chowns the postgres data volume (and
  `/var/run/postgresql`) to the `postgres` user on first boot. A fresh named volume is
  root-owned; `postgres-service.sh` itself runs as `postgres` and has no permission to
  fix this itself.
- **`SETUID`/`SETGID`** - supervisord runs as root (PID 1's child) and drops each program
  to its own unprivileged user via its `user=` directive (`postgres`, `redis`, `node` -
  see `config/supervisord.d/*.conf`). Without these two, `cap_drop: ALL` would break
  every one of those drops, not just harden the container.
- **`NET_BIND_SERVICE`** - `dns-local`'s dnsmasq binds `127.0.0.1:53`, a privileged port,
  while running as root (same as `code-docker-chrome`'s own `dns-local` - it also needs
  root to rewrite `/etc/resolv.conf`, which isn't a capability but is why it isn't given
  its own unprivileged user like the others).

`no-new-privileges:true` is still set. It doesn't conflict with `cap_add` here (it only
blocks *gaining* privilege beyond what `execve` started with - via setuid-bit binaries or
file capabilities - not capabilities the container already holds from `cap_add`).

playwright-service's own chromium launch already passes `--no-sandbox` (upstream's own
`api.ts`, not something this repo adds), so running it as the unprivileged `node` user
needed no extra capability (`CAP_SYS_ADMIN`, a relaxed seccomp profile, or similar) the
way `code-docker-chrome`'s browser does.

## Postgres: idempotent first-boot init

`postgres-service.sh` reproduces what upstream's `apps/nuq-postgres/Dockerfile` bakes
into its own image at build time (postgres 17 + `postgresql-17-cron`,
`shared_preload_libraries = 'pg_cron'`, `cron.database_name` set, `nuq.sql` run at
initdb) as a first-boot runtime step instead, since there's no separate container here to
own that Dockerfile's job:

1. If `${PGDATA}/PG_VERSION` doesn't exist (first boot, or a fresh volume): `initdb`
   with a real password (`--pwfile`, `--auth=scram-sha-256` - not upstream's typical
   trust-auth default, since every consumer here already carries a password), append
   `listen_addresses`/`shared_preload_libraries`/`cron.database_name` to
   `postgresql.conf` (must happen before the *first* start - `shared_preload_libraries`
   can't be changed after), start postgres temporarily, create the database if it isn't
   named `postgres`, run `nuq.sql`, stop.
2. Otherwise: skip straight to `exec postgres -D "${PGDATA}"` - a container restart never
   re-runs any of the above.

Verified live (see "Verification" below): a restart after data existed did not touch the
schema and the queue kept working.

## `firecrawl-front`: now a plain bridge, not a gate

The bearer-token check used to live in `firecrawl-front` (the only container on both
`code-docker-internal` and `firecrawl`). It now lives inside the AIO container's own
`nginx-gate` program instead, because the AIO design put a real process manager inside
the fetcher container for the first time. `firecrawl-front` still exists only because the
AIO container stays off `code-docker-internal` entirely (same isolation the old fetcher
containers had) - something still has to sit on both networks, but that something no
longer needs to know the token at all; it just `proxy_pass`es everything through
(`docker/firecrawl-proxy/`).

**TODO, deliberately left open** (per this rewrite's own scope): whether a separate
bridge container is still the right shape here, versus putting the AIO container
directly on `code-docker-internal` (its own gate already does the whole auth job, so the
extra hop buys only "one fewer container on the shared network" - a real but modest
win), or exposing it through a router vhost instead. See the TODO comments in
`code-docker-firecrawl.yml` and `docker/firecrawl-proxy/entrypoint.sh`.

## Verification (standalone, `--allow-test` style: docker build/run only, no compose)

Run 2026-09-28, on a throwaway bridge network (`docker network create`, no `internal:
true` - unlike the real deployment, this test network needed real internet access, which
`internal: true` would have removed), `FIRECRAWL_REF=v2.11.408`, `NETINIT_WAIT=false` +
`DNS_LOCAL_ENABLED=false` (the standalone-test equivalent of `code-docker-chrome`'s same
two switches - nothing here depends on `code-docker-netinit-docker`/router existing):

- **Build**: `docker build --no-cache` (a genuinely cold build, no BuildKit cache reuse
  at all): **3m50s**. A warm-cache rebuild after a config-only change (no source-affecting
  layer invalidated) drops to well under a minute.
- **Image size**: **3.6 GB** (`docker image inspect --format '{{.Size}}'`:
  4718053580 → 3604232365 bytes after the `--chown` fix below; `docker images`' own
  "content size" column reports 863MB, i.e. the compressed/deduplicated transfer size).
  Biggest contributors by layer (`docker history`): api's `node_modules` (815MB),
  the playwright browser cache (652MB), the apt install of postgres/redis/nginx/dnsmasq/
  supervisor (476MB), `playwright install-deps` (249MB), the FoundationDB client .deb
  (187MB - see "Open questions" on why it's kept anyway).
- 401 with no `Authorization` header; a real `POST /v1/scrape` against `https://
  example.com` returned markdown with the token; `https://quotes.toscrape.com/js/`
  (JS-rendered) returned the rendered quotes verbatim - proof playwright-service actually
  ran, not just the static HTML; a `POST /v1/crawl` (`limit: 2`) on `example.com`
  completed end to end polling its status (`scraping` → `completed`, `completed: 1,
  total: 1`, real markdown in the result) - the strongest proof the no-rabbitmq/
  `NUQ_WAIT_MODE=listen` design works, since crawl status polling exercises the nuq
  queue's own completion-signaling path, not just per-request scraping. The crawl took
  roughly a minute to move off `scraping` - see the surprise below on why that's slower
  than RabbitMQ would have been, and still fine for this use case.
- A restart (`docker restart`, not recreate - same container, same writable layer/named
  volume) after that crawl's data existed: `postgres-service.sh` logged "existing data
  directory found ... skipping initdb" and "nuq.sql marker present - skipping", the
  previously-completed crawl was still queryable both directly (`SELECT count(*) FROM
  nuq.queue_crawl_finished`) and through `/v1/crawl/<id>` afterward.
- `ss -ltnp` inside the running container: only `0.0.0.0:3002` (nginx-gate) listens on
  every interface; postgres (5432), redis (6379), the api (3902), playwright (3000), and
  every nuq worker/prefetch/reconciler port (3004-3012 range) are all `127.0.0.1`-only.

### Upstream-behavior surprises found only by running this end to end

Not obvious from reading `nuq.ts`/`harness.ts` in isolation - worth keeping visible so a
future re-verification isn't surprised twice:

- **`extract-worker` hard-depends on RabbitMQ, completely independent of
  `NUQ_WAIT_MODE`.** `apps/api/src/services/extract-queue.ts`'s `getChannel()` throws
  `"NUQ_RABBITMQ_URL is not configured"` the instant `extract-worker.ts`'s top-level IIFE
  calls `consumeExtractJobs()`/`consumeExtractDLQ()` at startup - this is a *second,
  entirely separate* RabbitMQ-only queue for the LLM-backed `/extract` endpoint, not
  something nuq's postgres LISTEN/NOTIFY path touches at all. Because
  `harness.ts`'s `waitForTermination()` does a `Promise.race()` across every service it
  started, one crashing service takes the *entire* harness down with it - so without a
  fix, dropping RabbitMQ didn't just disable `/extract`, it crash-looped the whole
  container (api, worker, every nuq-worker, all of it) forever. Fixed with the third
  source patch above (see "Three source patches") that makes `extract-worker` log a
  warning and idle instead of crashing when `NUQ_RABBITMQ_URL` is unset.
  **`/extract` is consequently unsupported in this image**, a stronger statement than the
  original plan's "optional, needs an OpenAI key" - it needs RabbitMQ first, which this
  design deliberately doesn't have. Calling it will 500 rather than the friendlier 400 an
  unset OpenAI key alone would have produced; not separately hardened, since it's already
  out of scope.
- **Two silent-masking bugs in `postgres-service.sh` itself, both root-caused to "this
  script runs as an unprivileged user and something it shells out to assumed otherwise"**:
  `pg_ctl -l /var/log/postgres/...` failed with `Permission denied` (that directory is
  root-owned; supervisord's own log redirection for this program works fine regardless,
  since supervisord opens those files itself as root before dropping to `user=postgres`,
  but this script's own nested `pg_ctl` call is a second, independent file open done by
  the already-unprivileged process) - fixed by redirecting to `/tmp` instead. Separately,
  `psql`/`createdb` printed `Password for user postgres:` to a script with no tty and no
  stdin (because `initdb --auth=scram-sha-256` applies to *local* Unix-socket connections
  too, not just TCP - the common assumption that same-machine connections are trusted by
  default doesn't hold once a real auth method is chosen) - fixed by exporting
  `PGPASSWORD`. Both failures were **silently masked** by supervisord's `autorestart`: the
  script exited under `set -e`, supervisord restarted it, and the second run saw
  `PG_VERSION` already present and skipped straight to a real, working `postgres` -
  which is what made this look like a clean start with nothing in the logs pointing at
  the actual problem except one easy-to-miss line, and is exactly why the nuq.sql-applied
  marker (see "Postgres: idempotent first-boot init" above) is a *separate* check from
  "does `PG_VERSION` exist" rather than one flag standing in for both steps.

### Found only in the real stack (2026-09-28, after the standalone run above)

The standalone verification ran `docker run` without the overlay's `cap_drop: [ALL]`,
so these only surfaced once the container ran under code-docker's compose. Each was
fixed; the list is here so the next change is tested the same way (in the stack, with
the overlay's own capabilities), not with a bare `docker run`.

- **Postgres crash-looped on its first restart.** The entrypoint did `chown -R` on the
  data directory every start; after initdb that directory is postgres-owned 0700, and
  root without `CAP_DAC_READ_SEARCH` can't list it. Now only the directory itself is
  chowned, and only when root still owns it (a fresh volume); a directory owned by some
  other uid - another postgres install's data - stops the container with a message
  instead of being re-owned.
- **`redis` and `nginx-gate` went FATAL.** Root without `CAP_DAC_OVERRIDE` can't write
  into another user's directory: `/var/log/redis` ships redis-owned, and nginx opens its
  packaged, www-data-owned log files before reading any config. The Dockerfile makes
  `/var/log/redis` root-owned and points nginx's logs at stdout/stderr (`-e` too).
- **Crawls never finished** - the fourth source patch (see the Dockerfile): without
  RabbitMQ the prefetch worker claimed queued jobs and then stranded them. It idles now;
  a 5-page crawl completes in ~26s.
- **Crawl status does not survive a container restart.** It lives in redis, which runs
  without persistence here (`Job not found` for a crawl started before the restart).
  Acceptable for an agent tool whose crawls are short-lived; the scraped data itself is
  returned in the response, not stored for later.

## What a person never sees here

Unchanged: nothing in this repo is meant to be opened by a human. No `ROUTER_VHOST_*`, no
`WEBMANAGER_MANIFEST_SHORTCUT_*`, no `OOTB_ROUTER_ALLOWED_TARGET_HOSTS` entry.

## Open questions / things not resolved here

- **The pinned tag is real but unreleased-in-the-GitHub-sense.** Upstream publishes a new
  semver tag on effectively every merge to `main` - there is no separate "cut a release"
  step. `FIRECRAWL_REF` defaults to the newest tag that existed as of 2026-09-28
  (`v2.11.408`); expect to bump it by hand more often than a project with real release
  notes to check against.
- **`redis` carries none of upstream's own container-level hardening** (no `cap_drop`
  *for itself specifically* - it shares the whole container's `cap_drop: [ALL]` plus the
  four capabilities above, which is already a tighter posture than upstream's own
  `redis:alpine` container had). Losing its data on restart is an accepted trade (see the
  table above) since nuq's actual job data lives in postgres.
- **Image size (3.6GB) has not been pushed further down.** The `--chown`-on-`COPY` fix
  (see "Verification") was the one obvious win found; further trimming (a slimmer apt
  package set, dropping the FDB client, an alpine-based final stage instead of
  bookworm-slim) wasn't attempted - Playwright's own `install-deps` machinery and PGDG's
  `postgresql-17-cron` package both specifically assume a Debian/Ubuntu base, so alpine
  would reopen the exact problem "Why Debian, not Arch" describes.
- **`/extract`'s own worker-crash bug is fixed, but the endpoint itself was not tested
  further** - once RabbitMQ is genuinely absent, calling `/v1/extract` will hit
  `addExtractJob()`'s own `getChannel()` throw at request time. Whether that surfaces to
  the caller as a clean 5xx or an unhandled rejection in the `api` process specifically
  (as opposed to `extract-worker`, which is now patched) was not verified - low-value to
  chase further given `/extract` is already out of scope, but worth knowing before anyone
  relies on it failing gracefully.
- **`firecrawl-front`'s own shape is unresolved** - see its own section above.
- **The foundationdb client library ships in the final image but is never exercised** -
  `NUQ_BACKEND` stays unset (postgres backend), and
  `apps/api/src/services/worker/nuq-fdb/client.ts` only lazy-`require`s the npm module
  when that backend is actually selected. Kept for parity with upstream's own runtime
  stage rather than trimmed, on the theory that a future upstream change eagerly
  importing it would be a worse surprise than a few extra MB.
