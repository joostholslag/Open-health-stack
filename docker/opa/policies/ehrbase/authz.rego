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

import data.ehrbase.nuts_pip

default allow := false

claims := payload if {
	parts := split(input.token, " ")
	count(parts) == 2
	lower(parts[0]) == "bearer"
	[_, payload, _] := io.jwt.decode(parts[1])
}

roles := claims.realm_access.roles if claims

is_admin_path if startswith(input.path, "/ehrbase/rest/admin")

# ── Template-definition READ scoping ─────────────────────────────────────────
# Ported from jorritspee/openEHRxNuts#14's template-id + operation + user_role
# allowlist — adapted, not copied verbatim:
#   - package/data shape matches THIS gateway's input ({method, path, token}),
#     not #14's `package rules` + Styra-DAS-style
#     `import data.datasources["acp_access_policy_for_rego.json"]`.
#   - `operation` isn't a field the gateway sends; it's derived from
#     input.method below.
#   - `resource.template.id` isn't recoverable from the path for most READs
#     either — a `GET /ehr/{id}/composition/{uid}` doesn't name its template.
#     The one EHRbase endpoint that DOES name a template in its path is the
#     template-definition GET below, so v1 scopes exactly that: real
#     template-scoped READ for composition/AQL endpoints needs a PIP (ask
#     EHRbase what template a composition uid belongs to) — a bigger design
#     question left for later, not bolted on here.
template_definition_prefix := "/ehrbase/rest/openehr/v1/definition/template/adl1.4/"

is_template_definition_path if startswith(input.path, template_definition_prefix)

# ngx.var.uri (what the gateway sends as `path`) is nginx's already-decoded
# $uri, so a template id containing a space (e.g. "EPS Patient Summary")
# arrives here literal, not percent-encoded.
template_id := substring(input.path, count(template_definition_prefix), -1) if is_template_definition_path

operation := "READ" if input.method == "GET"
operation := "CREATE" if input.method == "POST"
operation := "UPDATE" if input.method in {"PUT", "PATCH"}
operation := "DELETE" if input.method == "DELETE"

template_read_allowed if {
	some role in roles
	some entry in data.ehrbase.datasource.policies
	entry.user_role == role
	entry.template_id == template_id
	entry.operation == operation
}

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
	not is_template_definition_path
	"USER" in roles
}

# Template-definition GET is carved out of the blanket USER rule above and
# additionally gated by the datasource allowlist — a restriction layered on
# top of the native USER check, never a grant it wouldn't already make: a
# USER-only caller with no dokter/verpleegkundige role (e.g. the default
# api-client/hapi-svc service tokens) is denied here even though it would
# pass every other USER-gated endpoint.
allow if {
	is_template_definition_path
	"USER" in roles
	template_read_allowed
}

# REVERTED (was here 2026-09-19 to 2026-09-21, see git history): an "admin"
# in roles bypass for this path, on the premise that nictiz-ui's composition
# form calls it with the nictiz-ui-svc service credential which supposedly
# already held "admin" for openFHIR's $purge. That premise was wrong — a
# live check of nictiz-ui-svc's actual service-account roles in Keycloak
# showed only USER + default-roles-freshehr, and the bypass predictably
# never fired (confirmed by a live 403 in the gateway log, same call, after
# the bypass was deployed). The real fix is on nictiz-ui's side: forward the
# logged-in clinician's own token for this call (same pattern already used
# by its /api/admin/access-check and /api/admin/execute routes) instead of
# the shared service-account token — once that lands, the dokter/
# verpleegkundige allowlist above is correct and sufficient on its own,
# which is the whole reason it exists.

# ── Experimental: Nuts VC as a live PIP (POC) ───────────────────────────────
# Alongside the static datasource.json path above, gated to whichever
# identities have an entry in nuts_pip.sub_to_did — nobody else's
# authorization changes. See nuts_pip.rego for the query itself and its
# scope caveats (single hardcoded test identity, in-cluster-only call).
allow if {
	is_template_definition_path
	"USER" in roles
	template_id == "EPS Patient Summary"
	nuts_pip.has_nuts_role(claims.preferred_username, "dokter")
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
