# CDR connection registry for the openFHIR HAPI interceptor.
# Mounted at /etc/cdrs.yml (matches interceptor.cdrs-config-file).
#
# The `local` CDR is the in-cluster EHRbase, which runs as an OAuth2 resource
# server (SECURITY_AUTHTYPE=OAUTH) against the freshehr Keycloak realm. The
# interceptor authenticates with a client_credentials service account.
#
# tokenUrl is the IN-CLUSTER Keycloak Service on purpose: Keycloak answers under
# any Host header while stamping the canonical public issuer (KC_HOSTNAME) into
# the token, so the high-frequency token calls never hairpin through the LB.

- id: local
  name: EHRbase (local)
  baseUrl: http://ehrbase:8080/ehrbase/rest
  authMethod: oauth2
  oauth2:
    tokenUrl: http://keycloak:8080/auth/realms/freshehr/protocol/openid-connect/token
    clientId: hapi-svc
    clientSecret: __KC_HAPI_SVC_SECRET__
    authMethod: basic

# ── Examples of additional remote CDRs (disabled; edit and uncomment) ────────
#
# - id: remote-oauth2
#   name: Remote CDR (OAuth2)
#   baseUrl: https://cdr.example.com/rest
#   authMethod: oauth2
#   oauth2:
#     tokenUrl: https://auth.example.com/oauth/token
#     clientId: my-client-id
#     clientSecret: my-client-secret
#     authMethod: basic
#     extraParams:
#       audience: https://cdr.example.com/openehr/v1
#
# - id: remote-basic
#   name: Remote CDR (Basic Auth)
#   baseUrl: https://cdr2.example.com/rest
#   authMethod: basic
#   basicAuth:
#     username: my-username
#     password: my-password
