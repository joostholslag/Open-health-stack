# opa test coverage for nuts_pip.rego — run with: opa test docker/opa/policies
#
# http.send is mocked throughout (`with http.send as ...`) so this never
# depends on a live nuts-node — same spirit as authz_test.rego's unsigned
# JWT fixtures never depending on a live Keycloak.
package ehrbase.nuts_pip_test

import future.keywords.if

import data.ehrbase.nuts_pip

known_sub := "c2da4669-c025-4ca8-936d-ff2f5bc03e67"

mock_dokter_credential := {
	"status_code": 200,
	"body": {"verifiableCredentials": [
		{"verifiableCredential": {"credentialSubject": {"purposeOfUse": "dokter"}}},
	]},
}

test_has_nuts_role_true_for_matching_credential if {
	nuts_pip.has_nuts_role(known_sub, "dokter") with http.send as mock_dokter_credential
}

test_has_nuts_role_false_for_unknown_sub if {
	not nuts_pip.has_nuts_role("someone-not-in-the-mapping", "dokter") with http.send as mock_dokter_credential
}

test_has_nuts_role_false_when_purpose_does_not_match if {
	not nuts_pip.has_nuts_role(known_sub, "verpleegkundige") with http.send as mock_dokter_credential
}

test_has_nuts_role_false_on_no_credentials if {
	empty_response := {"status_code": 200, "body": {"verifiableCredentials": []}}
	not nuts_pip.has_nuts_role(known_sub, "dokter") with http.send as empty_response
}

test_has_nuts_role_false_on_non_200 if {
	error_response := {"status_code": 500, "body": {}}
	not nuts_pip.has_nuts_role(known_sub, "dokter") with http.send as error_response
}
