# Shared helpers for the scripts/ suite. Source this file, don't execute it.
#
# Pure bash + curl + sed/grep — the Makefile deliberately avoids jq to keep the
# host dependency list at "a shell and curl"; these scripts keep that contract.

# Where the stack answers. EDGE is the nginx TLS front door (self-signed dev
# cert, hence -k on every edge call); KEYCLOAK is the host-published token
# endpoint (part of the stack's contract, see docker-compose.yml).
EDGE="${EDGE:-https://localhost}"
KEYCLOAK="${KEYCLOAK:-http://localhost:8081}"

# Repo root (scripts/ lives directly under it), so every script works from any cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILS=0

# Same client + scopes as `make token` (see the Makefile for why the openFHIR
# per-API scopes must be requested explicitly).
fetch_token() {
  curl -sS -X POST "$KEYCLOAK/auth/realms/freshehr/protocol/openid-connect/token" \
    -d grant_type=client_credentials \
    -d client_id="${KC_API_CLIENT_ID:-api-client}" \
    -d client_secret="${KC_API_CLIENT_SECRET:-dev-api-client-secret}" \
    --data-urlencode "scope=${KC_TOKEN_SCOPES:-opt.c opt.r opt.u opt.d fc.c fc.r fc.u fc.d conceptmap.c conceptmap.r conceptmap.u conceptmap.d openfhir.map openfhir.insights}" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

# fetch_token, or die with a pointer at the usual cause.
require_token() {
  TOKEN=$(fetch_token)
  [ -n "$TOKEN" ] || { echo "FATAL: no token from Keycloak at $KEYCLOAK (is the stack up? make up)"; exit 1; }
}

# Token for one of the dokter-joost/verpleegkundige-bas test users
# (docker/keycloak/realm-freshehr.json) via the public verify-cli client's
# direct-access-grant (ROPC) login — these are real interactive Keycloak
# users (nictiz-ui logs them in through its own client); this is just how the
# CLI test suite fetches a token for one without a browser.
# fetch_user_token <username> <password>
fetch_user_token() {
  curl -sS -X POST "$KEYCLOAK/auth/realms/freshehr/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=verify-cli \
    -d username="$1" \
    -d password="$2" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

pass() { printf '  PASS  %s\n' "$*"; }

fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# assert_eq <description> <want> <got> [hint...]
assert_eq() {
  local desc=$1 want=$2 got=$3; shift 3
  if [ "$want" = "$got" ]; then pass "$desc"; else fail "$desc (want $want, got $got)${*:+ — $*}"; fi
}

# assert_contains <description> <needle-regex> <haystack> [hint...]
assert_contains() {
  local desc=$1 needle=$2 haystack=$3; shift 3
  if printf '%s' "$haystack" | grep -qE "$needle"; then pass "$desc"; else fail "$desc (no match for '$needle')${*:+ — $*}"; fi
}

# Print the verdict line and exit non-zero on any FAIL.
finish() {
  echo
  if [ "$FAILS" -eq 0 ]; then
    echo "OK — all checks passed."
  else
    echo "FAILED — $FAILS check(s) failed."
    exit 1
  fi
}
