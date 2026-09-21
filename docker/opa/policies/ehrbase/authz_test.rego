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
