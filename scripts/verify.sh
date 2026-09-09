#!/usr/bin/env bash
# Data-plane verification suite — the gate `make smoke` is not.
#
# smoke proves the AUTH layer (right HTTP codes bare vs Bearer). It stays green
# even when the openFHIR mapping chain is completely broken — the documented
# silent failure where $tofhir answers 200 with a bare Composition and
# no clinical resources (README "Mapping sets collide"). This suite proves the
# DATA plane: templates registered, mappings visible to the freshehr tenant,
# a FHIR bundle actually lands in the CDR, AQL finds it, and $tofhir produces
# clinical resources — not just a 200.
#
# Prereqs: `make up` (+ `make template` + `make bootstrap` once per fresh CDR).
# Usage:  scripts/verify.sh    (or: make verify)         Exit 0 = all green.
#
# Fixture provenance: scripts/fixtures/eps.example.bundle.json is copied from
# ../freshehr-nictiz-ui/fixtures/eps.example.bundle.json with one change — a
# Composition.subject referencing Patient/stack-verify-patient (the source
# fixture has no subject, and without one the interceptor cannot resolve an
# EHR: "No EHR ID found for patient").
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

BOOTSTRAP_DIR="$ROOT/docker/openfhir/bootstrap"
BUNDLE_FIXTURE="$SCRIPT_DIR/fixtures/eps.example.bundle.json"
FLAT_FIXTURE="$BOOTSTRAP_DIR/eps.example.flat.json"
PATIENT_ID="stack-verify-patient"

# ── 1. Healthy gate ──────────────────────────────────────────────────────────
"$SCRIPT_DIR/wait-healthy.sh" || exit 1
echo

# ── 2. Auth matrix (unchanged smoke, already exits non-zero) ─────────────────
echo "Auth matrix (make smoke):"
if make -C "$ROOT" --no-print-directory smoke; then
  pass "auth matrix"
else
  fail "auth matrix (make smoke)"
fi
echo

require_token

# ── 3. Templates present in EHRbase ──────────────────────────────────────────
# `make template` prints HTTP codes but asserts nothing; this does.
templates=$(curl -sk -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' \
  "$EDGE/ehrbase/rest/openehr/v1/definition/template/adl1.4")
for opt in "$BOOTSTRAP_DIR"/*.opt; do
  [ -e "$opt" ] || continue
  tid=$(grep -m1 -A2 '<template_id>' "$opt" | sed -n 's/.*<value>\(.*\)<\/value>.*/\1/p')
  if [ -z "$tid" ]; then fail "template id not extractable from $(basename "$opt")"; continue; fi
  if printf '%s' "$templates" | grep -qF "\"$tid\""; then
    pass "template '$tid' registered in EHRbase"
  else
    fail "template '$tid' missing from EHRbase — run: make template"
  fi
done

# ── 4. openFHIR mapping state (freshehr tenant) ──────────────────────────────
# The engine's own STARTUP bootstrap writes under an internal tenant that is
# invisible to freshehr callers; only `make bootstrap` loads the visible set.
contexts=$(curl -sk -H "Authorization: Bearer $TOKEN" "$EDGE/openfhir/fc/context")
if [ -n "$contexts" ] && [ "$contexts" != "[]" ] && printf '%s' "$contexts" | grep -qiE 'eps'; then
  pass "openFHIR fc/context non-empty and mentions EPS"
else
  fail "openFHIR fc/context empty or missing EPS context — run: make bootstrap"
fi

# ── 4b. hades terminology data plane ─────────────────────────────────────────
# smoke already proves /terminology's auth codes; this proves hades actually
# HAS content (the fhir.db bootstrap ran), same spirit as the tofhir
# entry-count check. NOTE: hades serializes Parameters with the value BEFORE
# the name ({"valueString":"Male","name":"display"}), so match the value key,
# not a display:Male pair.
lookup=$(curl -sk -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" \
  "$EDGE/terminology/fhir/CodeSystem/\$lookup?system=http://hl7.org/fhir/administrative-gender&code=male")
lcode=$(printf '%s' "$lookup" | tail -n1)
lbody=$(printf '%s' "$lookup" | sed '$d')
if [ "$lcode" = 200 ] && printf '%s' "$lbody" | grep -qF '"valueString":"Male"'; then
  pass "hades \$lookup administrative-gender male → display Male"
else
  fail "hades \$lookup (HTTP $lcode) — empty hades? check 'docker compose logs hades' for the fhir.db bootstrap"
fi

# ── 5. EPS ingest through HAPI (+ interceptor) ───────────────────────────────
# Patient first: the fixture Composition's subject references it, and without
# an existing Patient the interceptor answers "No EHR ID found for patient".
pcode=$(curl -sk -o /dev/null -w '%{http_code}' -X PUT \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/fhir+json' \
  -d "{\"resourceType\":\"Patient\",\"id\":\"$PATIENT_ID\",\"identifier\":[{\"system\":\"http://fhir.nl/fhir/NamingSystem/bsn\",\"value\":\"999990019\"}],\"name\":[{\"family\":\"StackVerify\",\"given\":[\"Test\"]}]}" \
  "$EDGE/fhir/Patient/$PATIENT_ID")
case "$pcode" in
  200|201) pass "PUT /fhir/Patient/$PATIENT_ID ($pcode)";;
  *)       fail "PUT /fhir/Patient/$PATIENT_ID (HTTP $pcode)";;
esac

headers=$(mktemp); body=$(mktemp)
bcode=$(curl -sk -o "$body" -D "$headers" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/fhir+json' \
  --data-binary @"$BUNDLE_FIXTURE" "$EDGE/fhir")
location=$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$headers" | tr -d '\r' | head -1)
if [ "$bcode" = 201 ]; then
  # A 201 whose Location is a stored Bundle means stock HAPI JPA handled it —
  # i.e. the openFHIR interceptor did NOT load (check `docker compose logs hapi`
  # for "registering custom interceptor").
  case "$location" in
    */Bundle/*) fail "EPS bundle POST: plain HAPI JPA response (Location $location) — interceptor not loaded";;
    *)          pass "EPS bundle POST → 201 (Location: ${location:-none})";;
  esac
else
  fail "EPS bundle POST → HTTP $bcode (want 201): $(head -c 300 "$body")"
fi
rm -f "$headers" "$body"

# ── 6. AQL round-trip: the composition is queryable in the CDR ───────────────
aql=$(curl -sk -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"q":"SELECT c/uid/value, c/archetype_details/template_id/value FROM EHR e CONTAINS COMPOSITION c"}' \
  "$EDGE/ehrbase/rest/openehr/v1/query/aql")
acode=$(printf '%s' "$aql" | tail -n1)
abody=$(printf '%s' "$aql" | sed '$d')
if [ "$acode" = 200 ] && printf '%s' "$abody" | grep -qF 'EPS Patient Summary'; then
  pass "AQL round-trip: ≥1 composition with template 'EPS Patient Summary'"
else
  fail "AQL round-trip (HTTP $acode, EPS row present: no)"
fi

# ── 7. $tofhir entry count — the silent-failure killer ───────────────────────
# 200 alone is NOT success: with stale/colliding mappers the engine still
# answers 200 but the Bundle is bare {Bundle, Composition} with zero clinical
# resources. Assert real content.
# Probes the root-level $tofhir operation — what the HAPI interceptor and the
# nictiz-ui BFF call since openFHIR 3.0.0 — not the legacy raw-flat-JSON
# /openfhir/tofhir API. The operation wants a Parameters resource whose
# `composition` parameter is the STRINGIFIED flat composition, so the fixture
# is JSON-escaped inline (backslashes, quotes, then newlines dropped — legal:
# they are inter-token whitespace in the embedded JSON). Pure sed/tr, keeping
# the repo's no-jq rule. A healthy Bundle now also carries an engine-generated
# Provenance entry on top of the clinical resources.
escaped=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$FLAT_FIXTURE" | tr -d '\n\r\t')
printf '{"resourceType":"Parameters","parameter":[{"name":"composition","valueString":"%s"}]}' \
  "$escaped" > "$SCRIPT_DIR/.tofhir-params.json.tmp"
tof=$(curl -sk -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/fhir+json' \
  --data-binary @"$SCRIPT_DIR/.tofhir-params.json.tmp" \
  "$EDGE/openfhir/\$tofhir?templateId=EPS%20Patient%20Summary")
rm -f "$SCRIPT_DIR/.tofhir-params.json.tmp"
tcode=$(printf '%s' "$tof" | tail -n1)
tbody=$(printf '%s' "$tof" | sed '$d')
rcount=$(printf '%s' "$tbody" | grep -o '"resourceType"' | wc -l | tr -d ' ')
if [ "$tcode" = 200 ] && [ "$rcount" -ge 3 ] \
  && printf '%s' "$tbody" | grep -qE '"resourceType"[[:space:]]*:[[:space:]]*"(AllergyIntolerance|Condition|Procedure|Device)"'; then
  pass "\$tofhir: $rcount resourceTypes incl. clinical resources"
else
  fail "\$tofhir: HTTP $tcode, $rcount resourceTypes, clinical resources missing — bare {Bundle, Composition} means stale/colliding mappers: run make destroy and rebootstrap"
fi

# ── 8. FHIR read-back ────────────────────────────────────────────────────────
case "$location" in
  http*://*/fhir/*) target="$location";;
  /fhir/*)          target="$EDGE$location";;
  *)                target="$EDGE/fhir/Patient/$PATIENT_ID";;
esac
gcode=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$target")
assert_eq "FHIR read-back GET $target" 200 "$gcode"

# ── 9. Cleanup ───────────────────────────────────────────────────────────────
# Remove the verify Patient: it has no UI-created EHR link, and leaving it in
# the HAPI patient list breaks the nictiz-ui e2e suite (its selectPatient
# helper picks the LAST listed patient and then waits forever for a
# composition view this patient can't render).
dcode=$(curl -sk -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $TOKEN" "$EDGE/fhir/Patient/$PATIENT_ID")
case "$dcode" in
  200|204) pass "cleanup: deleted Patient/$PATIENT_ID";;
  *)       fail "cleanup: DELETE Patient/$PATIENT_ID (HTTP $dcode)";;
esac

finish
