#!/bin/sh
# Redpanda Console entrypoint for Railway.
#
# Console is configured entirely by environment variables, so the only work here
# is repairing the cross-service references that Railway renders as an empty
# string on the broker's first-ever deployment — which is every service's state
# during a template deploy. Left alone the app would connect to ":9092" forever.
set -eu

log() { printf '[railway-entrypoint] %s\n' "$*"; }

BROKER_HOST="${REDPANDA_BROKER_HOST:-}"
case "$BROKER_HOST" in
  "" | :*) BROKER_HOST="redpanda.railway.internal" ;;
esac

KAFKA_PORT="${REDPANDA_KAFKA_PORT:-9092}"
SCHEMA_REGISTRY_PORT="${REDPANDA_SCHEMA_REGISTRY_PORT:-8081}"
ADMIN_PORT="${REDPANDA_ADMIN_PORT:-9644}"

# Repair on shape: a value that is empty, or starts with ':' because the host
# half of "${host}:${port}" rendered empty, gets the deterministic literal.
repair() {
  var=$1
  fallback=$2
  eval "current=\${$var:-}"
  case "$current" in
    "" | :* | */:* | *//:*)
      export "$var=$fallback"
      log "$var was '$current'; using $fallback"
      ;;
  esac
}

repair KAFKA_BROKERS "${BROKER_HOST}:${KAFKA_PORT}"
repair SCHEMAREGISTRY_URLS "http://${BROKER_HOST}:${SCHEMA_REGISTRY_PORT}"
repair REDPANDA_ADMINAPI_URLS "http://${BROKER_HOST}:${ADMIN_PORT}"

: "${SERVER_LISTENPORT:=${PORT:-8080}}"
export SERVER_LISTENPORT

log "brokers=${KAFKA_BROKERS} listen=${SERVER_LISTENPORT}"

cd /app
exec /app/console "$@"
