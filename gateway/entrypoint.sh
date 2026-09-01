#!/bin/sh
# Public gateway for the Redpanda stack on Railway.
#
# Redpanda Console has no authentication outside its enterprise build, so it must
# not hold the public domain. This service does: HTTP basic auth in front of the
# Console (which the browser then replays on the Console's own same-origin XHR)
# and a pass-through for the two broker APIs that authenticate themselves.
set -eu

log() { printf '[railway-entrypoint] %s\n' "$*"; }

GATEWAY_USER="${GATEWAY_USER:-admin}"
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-}"

if [ -z "$GATEWAY_PASSWORD" ]; then
  log "FATAL: GATEWAY_PASSWORD is empty. Refusing to publish an unauthenticated Console."
  exit 1
fi

# No Railway variable can compute a bcrypt hash, so it is derived here on every
# boot. --plaintext is the only scriptable form: piping to stdin exits on EOF.
GATEWAY_PASSWORD_HASH=$(caddy hash-password --plaintext "$GATEWAY_PASSWORD")
if [ -z "$GATEWAY_PASSWORD_HASH" ]; then
  log "FATAL: caddy hash-password produced an empty hash"
  exit 1
fi
export GATEWAY_USER GATEWAY_PASSWORD_HASH
unset GATEWAY_PASSWORD

# A cross-service reference renders empty until that service owns a deployment,
# which during a template deploy is every service at once. Repair on shape.
repair() {
  var=$1
  fallback=$2
  eval "current=\${$var:-}"
  case "$current" in
    "" | :*)
      export "$var=$fallback"
      log "$var was '$current'; using $fallback"
      ;;
  esac
}

repair CONSOLE_UPSTREAM "console.railway.internal"
repair REDPANDA_UPSTREAM "redpanda.railway.internal"

: "${PORT:=8080}"
export PORT

log "listening on :${PORT}; console=${CONSOLE_UPSTREAM} broker=${REDPANDA_UPSTREAM}"

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
