# Redpanda on Railway

Deployment sources for a production-shaped [Redpanda](https://github.com/redpanda-data/redpanda)
stack on [Railway](https://railway.com): a Kafka-API broker with SASL/SCRAM
authentication, Schema Registry and the Kafka HTTP Proxy, plus Redpanda Console
behind an authenticating gateway.

Three services, each built from its own directory in this repo.

| Directory | Service | Public | Notes |
|---|---|---|---|
| `broker/` | `redpanda` | no (TCP proxy for the Kafka API) | volume-backed; Kafka 9092, Schema Registry 8081, HTTP Proxy 8082, Admin API 9644 |
| `console/` | `console` | no | Redpanda Console, reachable only through the gateway |
| `gateway/` | `gateway` | yes | Caddy: HTTP basic auth in front of the Console, pass-through for the two broker HTTP APIs |

## Why these are custom images and not the published ones

**`broker/`** — `redpandadata/redpanda` cannot be configured for Railway by
environment variables alone:

- Seastar sizes itself from the **host**, and Railway's hosts report 48 cores. The
  entrypoint reads `cpu.max` and `memory.max` from the cgroup and passes `--smp` and
  `--memory` explicitly, so a container resize re-tunes on the next boot.
- `rpk redpanda start --set` **silently drops** the per-listener
  `authentication_method` key, leaving Schema Registry and the HTTP Proxy open to
  anonymous callers on a cluster that otherwise looks locked down. The entrypoint
  writes `redpanda.yaml` itself and execs the broker binary directly.
- Railway's private network is IPv6-first, so every listener binds `::`, which
  Seastar serves dual-stack — the IPv4 health-check prober and an IPv6 peer are both
  answered by one socket.
- The advertised Kafka addresses have to be derived at boot from
  `RAILWAY_PRIVATE_DOMAIN` and, for the external listener, from
  `RAILWAY_TCP_PROXY_DOMAIN` / `RAILWAY_TCP_PROXY_PORT`. No Railway variable can
  express them, and `RAILWAY_PRIVATE_DOMAIN` is empty on a service's first-ever
  deployment.
- The image runs as uid 101 and a Railway volume is mounted root-owned, so the
  entrypoint chowns it and drops back with `setpriv`.
- The HTTP Proxy and Schema Registry are Kafka *clients* living inside the broker's
  own container, and a service calling its own `*.railway.internal` name fails at
  request time — the HTTP Proxy answers `503 broker_not_available` on a cluster that
  is otherwise healthy. They are given a `local` Kafka listener on `127.0.0.1:9093`,
  advertised as itself, which is unreachable from outside the container.

**`console/`** — Console is configured entirely by environment variables. The only
thing the entrypoint does is repair the cross-service references Railway renders as
an empty string during a first deployment.

**`gateway/`** — Redpanda Console has no authentication outside its enterprise
build, so it must not hold the public domain. Caddy derives a bcrypt hash from
`GATEWAY_PASSWORD` at boot, which no Railway variable can compute.

## Variables

### `redpanda` (broker)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `REDPANDA_ADMIN_USER` | yes | `admin` | SASL/SCRAM superuser, created at cluster bootstrap |
| `REDPANDA_ADMIN_PASSWORD` | yes | — | its password; the broker refuses to start without one |
| `PORT` | yes | `9644` | Admin API port; also what Railway health-checks |
| `REDPANDA_SASL_MECHANISM` | no | `SCRAM-SHA-256` | or `SCRAM-SHA-512` |
| `REDPANDA_SMP` | no | derived | Seastar shard count |
| `REDPANDA_MEMORY_MB` | no | 80% of the cgroup limit | Seastar memory |
| `REDPANDA_AUTO_CREATE_TOPICS` | no | `true` | set `false` to require explicit topic creation |
| `REDPANDA_LOG_LEVEL` | no | `info` | |

Neither the user nor the password may contain `:` — `RP_BOOTSTRAP_USER` is
colon-delimited.

### `console`

`KAFKA_BROKERS`, `KAFKA_SASL_*`, `SCHEMAREGISTRY_*` and `REDPANDA_ADMINAPI_*` point
at the broker with the superuser's credentials. `SERVER_LISTENPORT` must match
`PORT`.

### `gateway`

`GATEWAY_USER` / `GATEWAY_PASSWORD` for the Console's basic auth,
`CONSOLE_UPSTREAM` and `REDPANDA_UPSTREAM` for the private hostnames.

## Public routes

| Path | Reaches | Auth |
|---|---|---|
| `/` | Redpanda Console | HTTP basic, at the gateway |
| `/schema-registry/*` | Schema Registry (8081) | the broker's own `http_basic`, against a SASL user |
| `/http-proxy/*` | Kafka HTTP Proxy (8082) | the broker's own `http_basic`, against a SASL user |
| `/healthz` | the gateway itself | none |

The Kafka API is reached over a Railway TCP proxy and always requires SASL/SCRAM.

## Scaling

This ships one broker. Redpanda's own production guidance is three, and nothing in
these images prevents it, but a Railway template redeploys every service at once and
`*.railway.internal` points at the previous container for the whole health-check
window — so a quorum tier cannot be rolled safely without manual, one-at-a-time
deploys. Durability here comes from the Railway volume rather than from replication.

## Licence

Redpanda is BSL 1.1 with an Additional Use Grant permitting production use, except
as a "Streaming or Queuing Service" offered to third parties. Each version converts
to Apache 2.0 four years after its release. Redpanda Console is likewise BSL 1.1;
its enterprise features (SSO, RBAC, authentication) are not used here.
