#!/usr/bin/env bash
# Block until every service in the compose stack actually answers, or time out.
#
# Compose healthchecks cover most services, but not HAPI: the hapiproject/hapi
# image is distroless (no shell/curl/wget), so it has NO container healthcheck
# and `make up` returns before HAPI can serve traffic. This script is the
# readiness gate `depends_on` can't provide — poll from the host instead.
#
# Usage: scripts/wait-healthy.sh          (or: make wait)
#   WAIT_TIMEOUT=300 scripts/wait-healthy.sh   to override the 180s default.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT="${WAIT_TIMEOUT:-180}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

# wait_for <label> <want-http-code> <curl args...>
wait_for() {
  local label=$1 want=$2; shift 2
  local code
  while :; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null)
    if [ "$code" = "$want" ]; then
      printf '  up    %-28s %s\n' "$label" "$code"
      return 0
    fi
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      printf '  DOWN  %-28s last HTTP %s (want %s) after %ss\n' "$label" "${code:-none}" "$want" "$TIMEOUT"
      echo "FATAL: stack not healthy within ${TIMEOUT}s — check 'make ps' / 'make logs'."
      exit 1
    fi
    sleep 3
  done
}

echo "Waiting for the stack (timeout ${TIMEOUT}s)…"

# Order matters: Keycloak first (everything else needs tokens), then the edge,
# then each backend through its production route.
wait_for "keycloak OIDC discovery" 200 "$KEYCLOAK/auth/realms/freshehr/.well-known/openid-configuration"
wait_for "nginx edge banner"       200 "$EDGE/"
wait_for "openfhir /health"        200 "$EDGE/openfhir/health"

require_token
wait_for "ehrbase /rest/status"    200 -H "Authorization: Bearer $TOKEN" "$EDGE/ehrbase/rest/status"
# HAPI is the one service with no compose healthcheck — this is its only gate.
wait_for "hapi /fhir/metadata"     200 -H "Authorization: Bearer $TOKEN" "$EDGE/fhir/metadata"

echo "All services answering."
