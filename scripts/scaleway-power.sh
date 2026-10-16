#!/usr/bin/env bash
# Power the Scaleway cluster's instances off (pause) or on (resume). Waits until
# every server reaches the target state.
#
# Usage: scripts/scaleway-power.sh pause|resume
# Env: SCW_SECRET_KEY, SCW_PROJECT_ID, CLUSTER_NAME, SCW_ZONE
set -euo pipefail
: "${SCW_SECRET_KEY:?}" "${SCW_PROJECT_ID:?}" "${CLUSTER_NAME:?}" "${SCW_ZONE:?}"
API="https://api.scaleway.com/instance/v1/zones/$SCW_ZONE"

servers() { # $1 = role tag
  curl -sSf -H "X-Auth-Token: $SCW_SECRET_KEY" \
    "$API/servers?project=$SCW_PROJECT_ID&tags=cluster:$CLUSTER_NAME,role:$1&per_page=100" \
    | jq -r '.servers[] | "\(.id) \(.state | gsub(" "; "_")) \(.name)"'
}

act() { # $1 = poweron|poweroff, $2 = role tag; skips servers already in the target state
  local want=stopped list
  [ "$1" = poweron ] && want=running
  list=$(servers "$2")
  [ -n "$list" ] || { echo "::warning::no $2 servers tagged cluster:$CLUSTER_NAME"; return 0; }
  while read -r id state name; do
    if [ "$state" = "$want" ]; then echo "$name already $state"; continue; fi
    case "$state" in starting|stopping) echo "$name is $state, waiting"; continue ;; esac
    echo "$name: $state -> $1"
    curl -sSf -o /dev/null -H "X-Auth-Token: $SCW_SECRET_KEY" -H "Content-Type: application/json" \
      -X POST "$API/servers/$id/action" -d "{\"action\":\"$1\"}"
  done <<< "$list"
  for _ in $(seq 1 60); do
    if servers "$2" | awk -v w="$want" '$2 != w {bad=1} END {exit bad}'; then
      echo "all $2 servers $want"; return 0
    fi
    sleep 10
  done
  echo "timed out waiting for $2 servers to be $want:" >&2; servers "$2" >&2; exit 1
}

case "${1:-}" in
  pause)  act poweroff agent; act poweroff control-plane ;;
  resume) act poweron control-plane; act poweron agent ;;
  *) echo "usage: $0 pause|resume" >&2; exit 1 ;;
esac
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "## Scaleway cluster: $1 done" >> "$GITHUB_STEP_SUMMARY"
  { servers control-plane; servers agent; } | awk '{print "- " $3 ": " $2}' >> "$GITHUB_STEP_SUMMARY"
fi
