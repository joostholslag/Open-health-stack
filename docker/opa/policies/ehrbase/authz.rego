# Authorization policy for the EHRbase-fronting PEP (docker/ehrbase-gateway).
#
# Input shape (built by the gateway's access_by_lua_block):
#   {
#     "method": "GET",
#     "path":   "/ehrbase/rest/openehr/v1/ehr/...",
#     "token":  "Bearer <jwt>"
#   }
#
# EHRbase itself re-validates the JWT's signature/issuer/expiry natively
# (SECURITY_AUTHTYPE=OAUTH) — this policy only needs the claims, so it decodes
# the token without re-verifying the signature.
package ehrbase.authz

import future.keywords.if
import future.keywords.in

default allow := false

claims := payload if {
	parts := split(input.token, " ")
	count(parts) == 2
	lower(parts[0]) == "bearer"
	[_, payload, _] := io.jwt.decode(parts[1])
}

roles := claims.realm_access.roles if claims

is_admin_path if startswith(input.path, "/ehrbase/rest/admin")

# ── v1 baseline: never more permissive than EHRbase's own native check ──────
# This makes the PEP a strict superset gate in front of EHRbase's binary
# USER/ADMIN role split — it changes nothing yet, but gives every caller
# (nginx /ehrbase, HAPI, openFHIR) one shared point to extend below.
allow if {
	is_admin_path
	"ADMIN" in roles
}

allow if {
	not is_admin_path
	"USER" in roles
}

# ── Extension point ──────────────────────────────────────────────────────────
# Attribute-based rule, modeled after EHRbase's own (since-removed) ABAC design
# — organization_id / patient_id JWT claims scoped to a resource. Requires
# Keycloak to mint those claims (see realm-freshehr.json protocol mappers) and
# a way to pull the ehr_id/patient out of the request path. Left commented out
# until those claims exist:
#
# allow if {
# 	not is_admin_path
# 	"USER" in roles
# 	some ehr_id
# 	regex.match(sprintf("^/ehrbase/rest/openehr/v1/ehr/%s(/.*)?$", [ehr_id]), input.path)
# 	claims.patient_id == ehr_id
# }
