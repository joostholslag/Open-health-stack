#!/usr/bin/env bash
# Version drift report: what each layer DECLARES vs what is actually RUNNING.
#
# Declared pins are read from the three files that own them:
#   docker/docker-compose.yml        (compose layer)
#   docker/hapi/Dockerfile           (the real upstream HAPI pin — ARG HAPI_BASE)
#   charts/health-stack/values.yaml  (Helm layer)
# Running versions come from `docker compose images` plus what the services
# report about themselves (EHRbase /rest/status, HAPI /fhir/metadata).
#
# Exit non-zero when compose and chart disagree on a shared component — that
# mismatch is exactly the "upgraded one layer, forgot the other" failure this
# report exists to catch. The RUNNING column is informational (stale containers
# are fixed by `make up`/`make destroy`, not by editing pins).
#
# Usage: scripts/versions.sh    (or: make versions)
# Output doubles as the before/after table for /upgrade-stack reports.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPOSE_FILE="$ROOT/docker/docker-compose.yml"
VALUES_FILE="$ROOT/charts/health-stack/values.yaml"
HAPI_DOCKERFILE="$ROOT/docker/hapi/Dockerfile"
HADES_DOCKERFILE="$ROOT/docker/hades/Dockerfile"

# Tag declared in compose for an image whose repo path ends in $1.
# Handles both plain lines (image: repo:tag) and ${VAR:-repo:tag} defaults.
# tr -d '\r': working copies may be CRLF-checked-out (core.autocrlf).
compose_tag() {
  tr -d '\r' < "$COMPOSE_FILE" \
    | sed -n "s|^[[:space:]]*image:.*$1:\([^}\"']*\)}\{0,1\}[[:space:]]*$|\1|p" | head -1
}

# Tag declared in values.yaml for the given repository (first tag: after it).
chart_tag() {
  awk -v repo="$1" '
    { sub(/\r$/, "") }
    $1 == "repository:" && $2 == repo { f = 1; next }
    f && $1 == "tag:" { gsub(/"/, "", $2); print $2; exit }
  ' "$VALUES_FILE"
}

# Tag of the image a running compose container was created from.
running_tag() {
  printf '%s\n' "$COMPOSE_IMAGES" | awk -v repo="$1" '$2 == repo { print $3; exit }'
}

STACK_UP=0
COMPOSE_IMAGES=""
if [ -n "$(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null)" ]; then
  STACK_UP=1
  COMPOSE_IMAGES=$(docker compose -f "$COMPOSE_FILE" images 2>/dev/null)
fi

FMT='%-13s %-22s %-22s %-22s %s\n'
printf "$FMT" COMPONENT COMPOSE CHART RUNNING VERDICT
printf "$FMT" --------- ------- ----- ------- -------

# row <component> <compose-repo-suffix> <chart-repository>
# Prints one table row; compose↔chart mismatch flips the global fail counter.
row() {
  local name=$1 crepo=$2 hrepo=$3
  local c h r verdict
  c=$(compose_tag "$crepo");  : "${c:=?}"
  h=$(chart_tag "$hrepo");    : "${h:=?}"
  if [ "$STACK_UP" = 1 ]; then r=$(running_tag "$hrepo"); fi
  : "${r:=-}"
  if [ "$c" = "$h" ]; then verdict=OK; else verdict="FAIL compose≠chart"; FAILS=$((FAILS + 1)); fi
  printf "$FMT" "$name" "$c" "$h" "$r" "$verdict"
  r=""
}

row ehrbase       "ehrbase/ehrbase"              "ehrbase/ehrbase"
row postgres      "ehrbase-v2-postgres"          "ehrbase/ehrbase-v2-postgres"
row keycloak      "keycloak/keycloak"            "quay.io/keycloak/keycloak"
row openfhir      "openfhir-enterprise"          "openfhir/openfhir-enterprise"
row oauth2-proxy  "oauth2-proxy/oauth2-proxy"    "quay.io/oauth2-proxy/oauth2-proxy"
# hades is a team image shared by both layers (compose ${HADES_IMAGE:-...}
# default vs chart images.hades) — the tags must agree like any shared pin.
row hades         "freshehrteam/hades"           "ghcr.io/freshehrteam/hades"

# Components that exist in only one layer — informational, no match check:
# - hapi: compose builds locally FROM the Dockerfile pin; the chart pulls the
#   team's pushed ghcr.io/freshehrteam/hapi-openfhir image (push with an explicit
#   IMAGE_TAG=).
# - nginx: compose-only; on k8s its job is done by ingress-nginx.
hapi_base=$(tr -d '\r' < "$HAPI_DOCKERFILE" | sed -n 's/^ARG HAPI_BASE=hapiproject\/hapi:\(.*\)$/\1/p')
hapi_run=""; [ "$STACK_UP" = 1 ] && hapi_run=$(running_tag "ghcr.io/freshehrteam/hapi-openfhir")
printf "$FMT" "hapi (base)"  "${hapi_base:-?}" "(local build)"        "${hapi_run:--}" "info"
# openFHIR interceptor: fetched at build time from the pinned GitHub release
# asset (Dockerfile ARG INTERCEPTOR_VERSION), not a committed file or image tag.
hapi_icpt=$(tr -d '\r' < "$HAPI_DOCKERFILE" | sed -n 's/^ARG INTERCEPTOR_VERSION=\(.*\)$/\1/p')
printf "$FMT" "hapi (icpt)"  "${hapi_icpt:-?}" "(Dockerfile ARG)"     "-" "info"
printf "$FMT" "hapi (chart)" "-"               "$(chart_tag ghcr.io/freshehrteam/hapi-openfhir)" "-" "info"
nginx_run=""; [ "$STACK_UP" = 1 ] && nginx_run=$(running_tag "nginx")
printf "$FMT" "nginx"        "$(compose_tag nginx)" "(ingress-nginx)" "${nginx_run:--}" "info"
# hades upstream JAR pin — lives in the Dockerfile ARG, not in any image tag
# (analogous to hapi (base)). The image-tag row above tracks the TEAM tag.
hades_jar=$(tr -d '\r' < "$HADES_DOCKERFILE" | sed -n 's/^ARG HADES_VERSION=\(.*\)$/\1/p')
printf "$FMT" "hades (jar)"  "${hades_jar:-?}" "(Dockerfile ARG)"     "-" "info"

# What the services say about themselves — catches a wrong-image-for-the-tag
# situation no tag comparison can.
if [ "$STACK_UP" = 1 ]; then
  echo
  TOKEN=$(fetch_token)
  if [ -n "$TOKEN" ]; then
    eb=$(curl -sk -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' "$EDGE/ehrbase/rest/status" \
      | sed -n 's/.*"ehrbase_version"[^"]*"\([^"]*\)".*/\1/p')
    hp=$(curl -sk -H "Authorization: Bearer $TOKEN" -H 'Accept: application/fhir+json' "$EDGE/fhir/metadata" \
      | tr -d '\n' | sed -n 's/.*"software"[^}]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    # hades reports the upstream JAR version in its CapabilityStatement — this
    # should equal the hades (jar) Dockerfile ARG above.
    hd=$(curl -sk -H "Authorization: Bearer $TOKEN" "$EDGE/terminology/fhir/metadata" \
      | tr -d '\n' | sed -n 's/.*"software"[^}]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    echo "self-reported: ehrbase=${eb:-?}  hapi=${hp:-?}  hades=${hd:-?}"
  else
    echo "self-reported: (no Keycloak token — skipped)"
  fi
else
  echo
  echo "(stack not running — RUNNING column and self-reported versions skipped)"
fi

if [ "$FAILS" -gt 0 ]; then
  echo
  echo "FAILED — $FAILS compose↔chart mismatch(es). Pin both layers to the same tag."
  exit 1
fi
