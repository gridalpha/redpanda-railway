#!/usr/bin/env bash
# Redpanda broker entrypoint for Railway.
#
# Railway-specific work this does, none of which the stock image can do:
#   * sizes Seastar from the cgroup instead of the 48-core host
#   * writes redpanda.yaml itself, because `rpk redpanda start --set` silently
#     drops the per-listener `authentication_method` key
#   * derives advertised addresses from the injected RAILWAY_* variables
#   * chowns the root-owned volume and drops back to uid 101
set -euo pipefail

log() { printf '[railway-entrypoint] %s\n' "$*"; }

RP_UID=101
RP_GID=101
CONFIG_DIR=/etc/redpanda
MOUNT="${RAILWAY_VOLUME_MOUNT_PATH:-/var/lib/redpanda/data}"
# Every Railway volume ships a lost+found, and Redpanda refuses to share its
# data directory with one, so the cluster lives one level below the mount root.
DATA_DIR="${MOUNT%/}/redpanda"

# ---------------------------------------------------------------- credentials
ADMIN_USER="${REDPANDA_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${REDPANDA_ADMIN_PASSWORD:-}"
SASL_MECHANISM="${REDPANDA_SASL_MECHANISM:-SCRAM-SHA-256}"

if [ -z "$ADMIN_PASSWORD" ]; then
  log "FATAL: REDPANDA_ADMIN_PASSWORD is empty. Refusing to start an unauthenticated broker."
  exit 1
fi
case "$ADMIN_USER" in
  *:*) log "FATAL: REDPANDA_ADMIN_USER must not contain ':'"; exit 1 ;;
esac
case "$ADMIN_PASSWORD" in
  *:*) log "FATAL: REDPANDA_ADMIN_PASSWORD must not contain ':'"; exit 1 ;;
esac

# Read once at cluster bootstrap by the redpanda binary itself; ignored on every
# later boot, which is what makes it idempotent.
export RP_BOOTSTRAP_USER="${ADMIN_USER}:${ADMIN_PASSWORD}:${SASL_MECHANISM}"

# ------------------------------------------------------------------- addresses
# RAILWAY_PRIVATE_DOMAIN is empty on a service's first-ever deployment, and a
# template deploys every service for the first time at once, so default it to
# the deterministic literal rather than advertising a bare ":9092".
PRIVATE_HOST="${RAILWAY_PRIVATE_DOMAIN:-}"
if [ -z "$PRIVATE_HOST" ]; then
  PRIVATE_HOST="${RAILWAY_SERVICE_NAME:-redpanda}.railway.internal"
  log "RAILWAY_PRIVATE_DOMAIN is empty; advertising ${PRIVATE_HOST}"
fi

KAFKA_PORT="${REDPANDA_KAFKA_PORT:-9092}"
ADMIN_PORT="${PORT:-9644}"
SCHEMA_REGISTRY_PORT="${REDPANDA_SCHEMA_REGISTRY_PORT:-8081}"
HTTP_PROXY_PORT="${REDPANDA_HTTP_PROXY_PORT:-8082}"
RPC_PORT="${REDPANDA_RPC_PORT:-33145}"
# Redpanda's own HTTP Proxy and Schema Registry clients are Kafka clients living
# inside this container, and a service calling its own *.railway.internal name
# fails at request time. They get a loopback listener of their own instead.
LOCAL_KAFKA_PORT="${REDPANDA_LOCAL_KAFKA_PORT:-9093}"

# The external Kafka listener only exists when a Railway TCP proxy is attached.
# Both halves come from the container environment so a regenerated proxy port
# self-heals on the next boot.
EXT_LISTENER=""
EXT_ADVERTISED=""
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ] && [ -n "${RAILWAY_TCP_APPLICATION_PORT:-}" ]; then
  EXT_LISTENER="${RAILWAY_TCP_APPLICATION_PORT}"
  EXT_ADVERTISED="${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT}"
  log "external Kafka listener :${EXT_LISTENER} advertised as ${EXT_ADVERTISED}"
else
  log "no TCP proxy attached; Kafka API stays on the private network only"
fi

# --------------------------------------------------------------------- sizing
# Seastar reads the host, not the cgroup: unpinned it asks for 48 shards and
# tens of gigabytes on a container that has 8 cores and ~8 GB.
read_cpu_quota() {
  local line quota period
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    line=$(cat /sys/fs/cgroup/cpu.max)
    quota=${line%% *}
    period=${line##* }
    if [ "$quota" != "max" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
      echo $(( (quota + period - 1) / period ))
      return
    fi
  fi
  echo 0
}

read_mem_limit_mb() {
  local v
  if [ -r /sys/fs/cgroup/memory.max ]; then
    v=$(cat /sys/fs/cgroup/memory.max)
    if [ "$v" != "max" ] && [ "$v" -gt 0 ] 2>/dev/null; then
      echo $(( v / 1024 / 1024 ))
      return
    fi
  fi
  echo 0
}

CPU_QUOTA=$(read_cpu_quota)
MEM_LIMIT_MB=$(read_mem_limit_mb)
[ "$CPU_QUOTA" -gt 0 ] || CPU_QUOTA=2
[ "$MEM_LIMIT_MB" -gt 0 ] || MEM_LIMIT_MB=2048

# Leave headroom for rpk, the page cache and Seastar's own allocations.
MEMORY_MB="${REDPANDA_MEMORY_MB:-$(( MEM_LIMIT_MB * 80 / 100 ))}"
[ "$MEMORY_MB" -ge 512 ] || MEMORY_MB=512

# Redpanda wants roughly 2 GB per shard; never more shards than the CPU quota.
SHARDS_BY_MEM=$(( MEMORY_MB / 2048 ))
[ "$SHARDS_BY_MEM" -ge 1 ] || SHARDS_BY_MEM=1
SMP="${REDPANDA_SMP:-}"
if [ -z "$SMP" ]; then
  SMP=$CPU_QUOTA
  [ "$SMP" -le "$SHARDS_BY_MEM" ] || SMP=$SHARDS_BY_MEM
fi
[ "$SMP" -ge 1 ] || SMP=1

log "cgroup: cpu=${CPU_QUOTA} mem=${MEM_LIMIT_MB}MB -> --smp=${SMP} --memory=${MEMORY_MB}M"

# ------------------------------------------------------------------ node config
mkdir -p "$DATA_DIR" "$CONFIG_DIR"

{
  echo "redpanda:"
  echo "  data_directory: ${DATA_DIR}"
  echo "  node_id: 0"
  echo "  empty_seed_starts_cluster: true"
  echo "  seed_servers: []"
  echo "  rpc_server:"
  echo "    address: 127.0.0.1"
  echo "    port: ${RPC_PORT}"
  echo "  advertised_rpc_api:"
  echo "    address: 127.0.0.1"
  echo "    port: ${RPC_PORT}"
  echo "  admin:"
  echo "    - address: \"::\""
  echo "      port: ${ADMIN_PORT}"
  echo "  kafka_api:"
  echo "    - name: internal"
  echo "      address: \"::\""
  echo "      port: ${KAFKA_PORT}"
  echo "      authentication_method: sasl"
  if [ -n "$EXT_LISTENER" ]; then
    # Railway's TCP proxy dials the container over IPv4; a "::" bind here is
    # reachable from a private peer and never from the proxy.
    echo "    - name: external"
    echo "      address: 0.0.0.0"
    echo "      port: ${EXT_LISTENER}"
    echo "      authentication_method: sasl"
  fi
  echo "    - name: local"
  echo "      address: 127.0.0.1"
  echo "      port: ${LOCAL_KAFKA_PORT}"
  echo "      authentication_method: sasl"
  echo "  advertised_kafka_api:"
  echo "    - name: internal"
  echo "      address: ${PRIVATE_HOST}"
  echo "      port: ${KAFKA_PORT}"
  if [ -n "$EXT_ADVERTISED" ]; then
    echo "    - name: external"
    echo "      address: ${EXT_ADVERTISED%%:*}"
    echo "      port: ${EXT_ADVERTISED##*:}"
  fi
  echo "    - name: local"
  echo "      address: 127.0.0.1"
  echo "      port: ${LOCAL_KAFKA_PORT}"
  echo "pandaproxy_client:"
  echo "  brokers:"
  echo "    - address: 127.0.0.1"
  echo "      port: ${LOCAL_KAFKA_PORT}"
  echo "  sasl_mechanism: ${SASL_MECHANISM}"
  echo "  scram_username: ${ADMIN_USER}"
  echo "  scram_password: ${ADMIN_PASSWORD}"
  echo "schema_registry_client:"
  echo "  brokers:"
  echo "    - address: 127.0.0.1"
  echo "      port: ${LOCAL_KAFKA_PORT}"
  echo "  sasl_mechanism: ${SASL_MECHANISM}"
  echo "  scram_username: ${ADMIN_USER}"
  echo "  scram_password: ${ADMIN_PASSWORD}"
  echo "pandaproxy:"
  echo "  pandaproxy_api:"
  echo "    - name: internal"
  echo "      address: \"::\""
  echo "      port: ${HTTP_PROXY_PORT}"
  echo "      authentication_method: http_basic"
  echo "  advertised_pandaproxy_api:"
  echo "    - name: internal"
  echo "      address: ${PRIVATE_HOST}"
  echo "      port: ${HTTP_PROXY_PORT}"
  echo "schema_registry:"
  echo "  schema_registry_api:"
  echo "    - name: internal"
  echo "      address: \"::\""
  echo "      port: ${SCHEMA_REGISTRY_PORT}"
  echo "      authentication_method: http_basic"
  echo "rpk:"
  echo "  overprovisioned: true"
} > "${CONFIG_DIR}/redpanda.yaml"

# Cluster properties. Imported once, when the cluster bootstraps; the reconcile
# below is what keeps them right on an existing cluster.
{
  echo "enable_sasl: true"
  echo "kafka_enable_authorization: true"
  echo "admin_api_require_auth: true"
  echo "superusers:"
  echo "  - ${ADMIN_USER}"
  echo "default_topic_replications: 1"
  echo "minimum_topic_replications: 1"
  echo "auto_create_topics_enabled: ${REDPANDA_AUTO_CREATE_TOPICS:-true}"
  echo "audit_enabled: false"
} > "${CONFIG_DIR}/.bootstrap.yaml"

chmod 0640 "${CONFIG_DIR}/redpanda.yaml" "${CONFIG_DIR}/.bootstrap.yaml"
log "rendered ${CONFIG_DIR}/redpanda.yaml: kafka=${KAFKA_PORT} local=${LOCAL_KAFKA_PORT} sr=${SCHEMA_REGISTRY_PORT} proxy=${HTTP_PROXY_PORT} admin=${ADMIN_PORT} advertised=${PRIVATE_HOST}"

# ---------------------------------------------------------------- reconcile
# .bootstrap.yaml is read only while the cluster has no controller log, so on an
# existing cluster a changed security property would silently do nothing. Re-apply
# the three that matter once the broker answers, and tolerate failure — a rotated
# password legitimately cannot authenticate here.
(
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:${ADMIN_PORT}/v1/status/ready"; then break; fi
    sleep 2
  done
  sleep 5
  # rpk reuses the -X user/-X pass pair for Admin API basic auth; there is no
  # separate admin.basic_auth key, and passing one is silently ignored.
  set -- -X admin.hosts="127.0.0.1:${ADMIN_PORT}" -X user="${ADMIN_USER}" -X pass="${ADMIN_PASSWORD}"
  if rpk cluster config set enable_sasl true "$@" >/dev/null 2>&1; then
    rpk cluster config set kafka_enable_authorization true "$@" >/dev/null 2>&1 || true
    rpk cluster config set admin_api_require_auth true "$@" >/dev/null 2>&1 || true
    rpk cluster config set superusers "[\"${ADMIN_USER}\"]" "$@" >/dev/null 2>&1 || true
    log "security properties reconciled"
  else
    log "skipped security reconcile (admin API did not accept the configured credentials)"
  fi
) &

# ------------------------------------------------------------------ privileges
chown -R "${RP_UID}:${RP_GID}" "$MOUNT" "$CONFIG_DIR"
export HOME=/var/lib/redpanda

exec setpriv --reuid="$RP_UID" --regid="$RP_GID" --init-groups \
  /opt/redpanda/bin/redpanda \
  --redpanda-cfg "${CONFIG_DIR}/redpanda.yaml" \
  --smp="${SMP}" \
  --memory="${MEMORY_MB}M" \
  --reserve-memory=0M \
  --lock-memory=false \
  --overprovisioned \
  --default-log-level="${REDPANDA_LOG_LEVEL:-info}"
