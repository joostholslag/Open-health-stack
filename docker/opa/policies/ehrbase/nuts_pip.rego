# Experimental PIP: query nuts-node for a VC-based role credential, as an
# alternative attribute source to the static datasource.json allowlist used
# by authz.rego. First step of a POC — see PR discussion for the bigger
# "how does Nuts factor into auth" design question this is a slice of.
#
# Scope of this first step: gated to ONE hardcoded test identity below (see
# sub_to_did), so it changes authorization for nobody else. A real version
# would derive sub_to_did from Keycloak (a custom user attribute, or
# eventually a token Nuts itself issued) instead of hardcoding it here.
#
# nuts_vc_search_url points at nuts-node's INTERNAL API over the in-cluster
# Service DNS — reachable because OPA already runs in-cluster (a sidecar in
# the ehrbase Pod), so this never needs any public exposure. See
# charts/health-stack/templates/nuts-node.yaml for why port 8081 must never
# go in an Ingress. Under compose, the equivalent DNS name is the `nuts-node`
# service on the shared `health-stack` network.
#
# Known cost, not fixed here: this makes an authorization decision depend on
# a live network call to another service, on every request that reaches the
# rule below — the same "double-gating adds failure modes" trade-off this
# repo's CLAUDE.md already flags for /ehrbase and /openfhir's native auth.
# OPA's http.send supports response caching (a "cache"/"caching_mode" +
# "force_cache_duration_seconds" option) as a mitigation; not added yet.
package ehrbase.nuts_pip

import future.keywords.if
import future.keywords.in

# Keycloak JWT `sub` -> the did:nuts DID that was manually issued a matching
# NutsAuthorizationCredential on the nuts-node POC (see the branch's PR
# description for the exact API calls used to create it). Follow
# datasource.json's precedent (a separate, hand-edited JSON file) once this
# grows past one entry.
sub_to_did := {"c2da4669-c025-4ca8-936d-ff2f5bc03e67": "did:nuts:33xRdpmchvQtL17Vvx7LTXSrj92TdEqS3AbDzCatpCda"}

nuts_vc_search_url := "http://nuts-node.health-stack.svc.cluster.local:8081/internal/vcr/v2/issuer/vc/search"

# True if nuts-node holds a NutsAuthorizationCredential, self-issued by the
# caller's DID, whose credentialSubject.purposeOfUse matches.
has_nuts_role(sub, purpose_of_use) if {
	did := sub_to_did[sub]
	resp := http.send({
		"method": "GET",
		"url": nuts_vc_search_url,
		"query_params": {
			"credentialType": "NutsAuthorizationCredential",
			"issuer": did,
		},
		"raise_error": false,
	})
	resp.status_code == 200
	some entry in resp.body.verifiableCredentials
	entry.verifiableCredential.credentialSubject.purposeOfUse == purpose_of_use
}
