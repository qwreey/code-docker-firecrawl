# CLAUDE.md

## What this is

A **code-docker plugin**, not a Firecrawl distribution. Upstream
[firecrawl/firecrawl](https://github.com/firecrawl/firecrawl) images run unmodified (with
one deliberate exception, `firecrawl-dns` - see below); this repo only carries what it
takes to attach it to [code-docker](https://github.com/qwreey/code-docker) as an
agent-usable scrape/crawl tool:

- `code-docker-firecrawl.yml` - the compose overlay code-docker's `EXTRA_INCLUDE` chain
  pulls in. No standalone `docker-compose.yml`, same asymmetry as `code-docker-trilium`:
  running Firecrawl on its own needs nothing this repo adds.
- `docker/dns-forwarder/` - a small custom image (the one non-upstream image this repo
  builds). See "The DNS problem" below for why it exists.
- `docker/firecrawl-proxy/` - the bearer-token gate nginx config `firecrawl-front` loads.
- `ootb-manifest.env` - read by code-docker's `ootb.sh`/`migrate.sh`. Schema lives in
  code-docker's `docs/tips/ootb-manifest.md`.

`README.md` is the user-facing doc and the single source of truth for setup and what the
token actually protects - keep it in sync when changing the overlay.

## The one architectural decision: why this lives outside dind, not inside

Firecrawl's whole job is fetching **attacker-influenced URLs**, including redirects it
follows itself. That is fundamentally different from Trilium (a note app that only
egresses for link previews/update checks, off by default) or code-server-chrome (a
browser gated by a bearer token on the CDP path, with VNC as the only other consumer).
Firecrawl's own fetchers - `firecrawl-api` and `playwright-service` - exist specifically
to go wherever a scrape target's response tells them to.

`code-docker-internal` is not a safe place for that. webmanager on `code-docker:81` has
no login of its own; `router-manager`'s admin API and VNC relay are also reachable from
there. A fetcher with a route to that network is one SSRF-shaped redirect away from the
whole admin surface.

Putting it inside `code-docker-dind` instead was considered and rejected: dind's nested
containers all share one Docker daemon and one bridge network inside it, with no cheap
way to say "these two containers get egress, these three don't" - that granularity is
exactly what code-docker's own top-level `netinit.provider`/`netinit.gateway` label
scheme gives you, and dind doesn't have an equivalent. So Firecrawl gets its own
sibling-level `internal: true` network (`firecrawl`), the same kind of thing
`roblox-studio-docker`'s VNC-isolation network is, not a construct living inside dind.

## The shape

```
code-docker-internal                          firecrawl (internal: true)
                                       ┌─────────────────────────────────┐
  code-docker ──http+Bearer──▶ firecrawl-front:3002                     │
       (agent)                        │  │                              │
                                       │  ▼                              │
                                       │  firecrawl-api ──┐              │
                                       │  playwright-service│  (routed,  │
                                       │        │           │  netinit  │
                                       │        ▼           │  .provider)│
                                       │  redis / rabbitmq / nuq-postgres│
                                       │  (no netinit label - no route) │
                                       │        ▲                        │
                                       │  firecrawl-dns (static IP)      │
                                       └────────┼─────────────────────────┘
                                                 │ dns: 10.89.42.2 (both fetchers)
                                     code-docker-router (also joins `firecrawl`:
                                     is both the netinit.gateway AND the second
                                     DNS upstream firecrawl-dns forwards to)
```

- Only `firecrawl-api` and `playwright-service` carry the `netinit.provider` label. The
  `firecrawl` network's `netinit.gateway` label names router, so those two - and only
  those two - get a default route planted by `code-docker-netinit-docker`.
  `redis`/`rabbitmq`/`nuq-postgres` carry no label and get no route: their only
  nameserver stays Docker's own `127.0.0.11` (same-network names only), so there is no
  path out even by IP literal.
- `firecrawl-front` is the only container on both networks, and it is not a fetcher - it
  proxies exactly one path, to `firecrawl-api:3002`, after checking
  `Authorization: Bearer $FIRECRAWL_TOKEN`. That token is the only thing between "any
  container reachable from `code-docker-internal`" (dind, code-docker-chrome, anything a
  user runs inside dind) and Firecrawl's API, because Firecrawl's self-host build has **no
  key check of its own** (`USE_DB_AUTHENTICATION=false`, no Supabase wired up) to fall
  back on. Same shape as `code-docker-chrome`'s CDP bearer token, same reasoning.
- Firecrawl's own `extra_hosts: host.docker.internal:host-gateway` (upstream sets this on
  `api` only) is **deliberately dropped**, not carried over. `internal: true` only
  removes the network's NAT/forwarding path outward - the host's own bridge gateway IP is
  still directly reachable from any container on that bridge, `internal` or not. Handing a
  URL-fetching service a live route to the Docker host itself is not a trade this repo
  makes.
- The experimental `foundationdb`/`foundationdb-init` services (`NUQ_BACKEND=fdb`) are
  skipped entirely - `nuq-postgres` is the default backend and the only one this repo
  wires up.

## The DNS problem, and why `firecrawl-dns` is a real (small) custom image

`firecrawl-api` and `playwright-service` need to resolve two different classes of name:
same-network compose service names (redis, rabbitmq, nuq-postgres) **and** arbitrary
external hostnames (whatever a scrape/crawl job is pointed at). On an `internal: true`
network, Docker's embedded DNS (`127.0.0.11`) resolves the first class fine but answers
the second with an immediate, *definitive* SERVFAIL - it has no route to forward the
query over. Node's own resolver (both fetchers are Node processes) does not retry past
that SERVFAIL onto a second `nameserver` line the way glibc's NSS stack does. This is the
identical bug code-docker's own `dns-local`, `roblox-studio-docker`, and
`code-docker-dind` each independently hit against router - see code-docker's own
CLAUDE.md, "netshare" section, and `qwreey/router-docker-client`'s `dns-local/dns-local.sh`
for the measurements (0/15 external lookups without the fix, 15/15 with it, on the
equivalent `code-docker-internal` case).

The fix is the same recipe dns-local uses - a `dnsmasq --strict-order` forwarder with
`127.0.0.11` and router as its two upstreams - but it **cannot be `dns-local` itself**:
that script rewrites the `/etc/resolv.conf` of the same container it runs inside, as a
supervisord program. `firecrawl-api`/`playwright-service` are upstream images with no
process manager to hang a same-container resolver off of, and rebuilding them just to add
one is a bigger footprint than this needs (it would also mean re-verifying the fix every
time upstream's base image changes). Instead, `firecrawl-dns` is one small custom image
(`docker/dns-forwarder/`, `alpine:3.22` + `dnsmasq`) that listens on the network itself -
not just `127.0.0.1` - at a fixed, hand-picked IP, and both fetchers point their
compose-level `dns:` field directly at it. This is also why the `firecrawl` network has a
pinned subnet (`10.89.42.0/24` by default) instead of Docker's usual auto-assigned one:
Compose's `dns:` field only accepts IP literals, so the forwarder's address has to be
known in advance rather than resolved by name.

Verified live (2026-09-28, this deployment): `getent hosts example.com` from
`firecrawl-dns` itself resolved through the forwarder; `redis`/`rabbitmq`/`nuq-postgres`
(no `netinit.provider` label, same DNS setup otherwise) failed the identical lookup with
`getent`'s own exit code 2; and a real end-to-end scrape through `firecrawl-front` -
`node dist/src/harness.js` fetching `https://example.com` via `firecrawl-api`, which
itself depends on this DNS path for the outbound request, not just the name lookup -
came back with real markdown. That last one is the stronger proof: Node's resolver (what
`firecrawl-api`/`playwright-service` actually use, not `getent`) is exactly the resolver
this whole design exists to make work.

### Real bugs this design hit during its own live verification (2026-09-28)

Worth keeping visible rather than only fixed silently, since each one would look like an
unrelated flake if rediscovered cold:

- **`firecrawl-dns`'s own static IP got raced away.** Without a pinned `ip_range:` inside
  the subnet, Docker's auto-assignment for every OTHER container on `firecrawl` (nothing
  else here pins an address) starts from the bottom of the subnet in container-start
  order - so whichever backing service happened to start first could claim
  `FIRECRAWL_DNS_IP` before `firecrawl-dns` itself did, and `firecrawl-dns` then failed
  outright with "Address already in use". Fixed by reserving the bottom half of the
  subnet for static addresses via `ip_range` (see the `firecrawl` network's own comment
  in `code-docker-firecrawl.yml`).
- **Both fetchers raced their own route.** `code-docker-netinit-docker` can only plant a
  route after a container already exists, and both `firecrawl-api` and
  `playwright-service` do real network I/O the moment their process starts -
  `playwright-service` especially, whose `pnpm start` goes through a corepack shim that
  fetches its pinned package manager from `registry.npmjs.org` on every fresh container.
  Without a wait, this crash-looped on `ENETUNREACH`/`EAI_AGAIN` across 15+ restart
  attempts, because `restart: unless-stopped`'s growing backoff kept landing outside the
  window where the route already existed. Fixed by `docker/wait-for-route.sh` (see that
  file and both fetchers' `entrypoint:` override).
- **`firecrawl-front` cached `firecrawl-api`'s IP and never let go.** A bare
  `proxy_pass http://firecrawl-api:3002` resolves once, at nginx worker startup, and
  keeps that IP even after `firecrawl-api` is later recreated with a different one -
  which happened for real mid-test (recreating `firecrawl-api` to pick up the
  wait-for-route fix above) and produced a clean, silent 502 with no hint that the fix on
  the other side had worked. Fixed with `resolver 127.0.0.11 valid=10s;` plus a variable
  in `proxy_pass` (see `docker/firecrawl-proxy/firecrawl.conf.template`) - the same
  pattern router's own vhost nginx config uses for its upstreams.

## What a person never sees here

Unlike `code-docker-trilium` (its own PWA + router vhost + webmanager shortcut) or
`code-docker-chrome` (a VNC tab for a person to watch), nothing in this repo is meant to
be opened by a human. Firecrawl's self-host build ships no management UI, and the only
consumer is the agent inside `code-docker`, over `FIRECRAWL_API_URL`/`FIRECRAWL_TOKEN`
(merged into the `code-docker` service, same mechanism `roblox-studio-docker` uses for
`MCP_TOKEN` and `code-docker-chrome` uses for `CHROME_CDP_TOKEN`). There is accordingly no
`ROUTER_VHOST_*`, no `WEBMANAGER_MANIFEST_SHORTCUT_*`, and no
`OOTB_ROUTER_ALLOWED_TARGET_HOSTS` entry anywhere in this repo.

## Open questions / things not resolved here

- **`firecrawl-api`'s image tag is a real but unreleased-in-the-GitHub-sense tag.**
  Upstream publishes a new semver-tagged image on effectively every merge to `main` -
  there is no separate "cut a release" step the way TriliumNext has. `FIRECRAWL_TAG`
  defaults to the newest tag that existed on `ghcr.io` as of 2026-09-28 (`2.11.408`,
  digest-identical to `latest` at that moment), but expect to bump it by hand more often
  than a project with real release notes to check against.
- **`playwright-service`/`nuq-postgres` have no versioned tag at all upstream** (only
  `latest` existed on ghcr.io as of 2026-09-28) - `FIRECRAWL_PLAYWRIGHT_TAG`/
  `FIRECRAWL_NUQ_POSTGRES_TAG` exist as override points for if that ever changes, but
  there is nothing more specific to default them to today.
- **`redis`/`rabbitmq`/`nuq-postgres` carry none of upstream's own hardening** (no
  `cap_drop`, no `no-new-privileges`) beyond what their own official images already do
  internally - matching upstream's own compose file exactly, which also doesn't apply
  any to these three. They're already the most isolated containers in this stack (no
  egress, reachable only from the two fetchers and `firecrawl-dns`), so this was judged
  low-value to chase further, but it's a real gap if you want to tighten it - the
  practical blocker to `cap_drop: ALL` is that both official images use root→unprivileged
  privilege drop in their own entrypoints (`gosu`/similar), which needs
  `CAP_SETUID`/`CAP_SETGID` back, and that combination was not tested here.
- **Resource limit defaults are upstream's own hardcoded values** (`firecrawl-api`:
  4 CPU / 8G, `playwright-service`: 2 CPU / 4G) carried over as env-var defaults rather
  than re-derived from anything measured on this deployment's actual hardware.
