# opa test coverage for authz.rego — run with:  opa test docker/opa/policies
#
# Ported in the spirit of jorritspee/openEHRxNuts#14's own test suite, but
# exercised against this gateway's actual input shape rather than #14's.
# Tokens below are unsigned ("alg": "none") JWTs — dev-only fixtures for
# exercising the policy's role logic in isolation. io.jwt.decode never
# verifies the signature (EHRbase re-validates that natively — see the
# comment at the top of authz.rego), so these never need to be real,
# signed credentials.
package ehrbase.authz_test

import future.keywords.if

import data.ehrbase.authz

# {"realm_access":{"roles":["USER","dokter"]}}
dokter_joost_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOiB7InJvbGVzIjogWyJVU0VSIiwgImRva3RlciJdfX0."

# {"realm_access":{"roles":["USER","verpleegkundige"]}}
verpleegkundige_bas_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOiB7InJvbGVzIjogWyJVU0VSIiwgInZlcnBsZWVna3VuZGlnZSJdfX0."

# {"realm_access":{"roles":["USER","admin"]}} — the default api-client/hapi-svc
# shape.
plain_user_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOiB7InJvbGVzIjogWyJVU0VSIiwgImFkbWluIl19fQ."

# {"realm_access":{"roles":["USER"]}} — USER but no admin/dokter/verpleegkundige.
user_only_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOiB7InJvbGVzIjogWyJVU0VSIl19fQ."

# {"realm_access":{"roles":["ADMIN"]}}
admin_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOiB7InJvbGVzIjogWyJBRE1JTiJdfX0."

eps_template_path := "/ehrbase/rest/openehr/v1/definition/template/adl1.4/EPS Patient Summary"

# {"realm_access":{"roles":["USER"]},"sub":"dokter-joost-poc-sub"} — matches
# nuts_pip.rego's hardcoded sub_to_did test entry.
nuts_pip_user_token := "Bearer eyJhbGciOiAibm9uZSIsICJ0eXAiOiAiSldUIn0.eyJyZWFsbV9hY2Nlc3MiOnsicm9sZXMiOlsiVVNFUiJdfSwic3ViIjoiZG9rdGVyLWpvb3N0LXBvYy1zdWIifQ."

mock_dokter_credential := {
	"status_code": 200,
	"body": {"verifiableCredentials": [
		{"verifiableCredential": {"credentialSubject": {"purposeOfUse": "dokter"}}},
	]},
}

test_dokter_reads_eps_template if {
	authz.allow with input as {"method": "GET", "path": eps_template_path, "token": dokter_joost_token}
}

test_verpleegkundige_denied_eps_template if {
	not authz.allow with input as {"method": "GET", "path": eps_template_path, "token": verpleegkundige_bas_token}
}

test_user_only_denied_eps_template if {
	# USER alone (no admin/dokter/verpleegkundige) must NOT fall through to
	# the generic USER allow — the template-definition endpoint is a strict
	# addition on top of that baseline, never a relaxation of it.
	not authz.allow with input as {"method": "GET", "path": eps_template_path, "token": user_only_token}
}

test_admin_role_denied_eps_template if {
	# Locks in the revert (see authz.rego's "REVERTED" comment): "admin" alone
	# (no dokter/verpleegkundige) must NOT grant template-definition READ,
	# same as plain USER. A caller needs an actual datasource-allowlisted
	# role, not a blanket role bypass.
	not authz.allow with input as {"method": "GET", "path": eps_template_path, "token": plain_user_token}
}

test_plain_user_allowed_template_list if {
	# The list endpoint (no template id in the path) stays on the ordinary
	# USER baseline — only the single-template GET is scoped.
	authz.allow with input as {"method": "GET", "path": "/ehrbase/rest/openehr/v1/definition/template/adl1.4", "token": plain_user_token}
}

test_plain_user_allowed_elsewhere if {
	authz.allow with input as {"method": "GET", "path": "/ehrbase/rest/openehr/v1/ehr/abc", "token": plain_user_token}
}

test_admin_allowed_admin_path if {
	authz.allow with input as {"method": "GET", "path": "/ehrbase/rest/admin/ehr", "token": admin_token}
}

test_user_denied_admin_path if {
	not authz.allow with input as {"method": "GET", "path": "/ehrbase/rest/admin/ehr", "token": plain_user_token}
}

test_bare_denied_admin_path if {
	not authz.allow with input as {"method": "GET", "path": "/ehrbase/rest/admin/ehr", "token": ""}
}

test_bare_denied_eps_template if {
	not authz.allow with input as {"method": "GET", "path": eps_template_path, "token": ""}
}

# ── Nuts PIP path (POC) ──────────────────────────────────────────────────────
test_nuts_pip_role_reads_eps_template if {
	authz.allow with input as {"method": "GET", "path": eps_template_path, "token": nuts_pip_user_token}
		with http.send as mock_dokter_credential
}

test_nuts_pip_denied_without_mocked_credential if {
	# Same token/path as above, but nuts-node has nothing to say (e.g. the
	# search returns empty) — must not fall through to an allow.
	empty_response := {"status_code": 200, "body": {"verifiableCredentials": []}}
	not authz.allow with input as {"method": "GET", "path": eps_template_path, "token": nuts_pip_user_token}
		with http.send as empty_response
}
