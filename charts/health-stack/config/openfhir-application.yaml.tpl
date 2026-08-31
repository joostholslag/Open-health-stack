# openFHIR engine configuration (LOCAL mode only).
# Kept in sync with docker/openfhir/application.yaml.
#
# Rendered by templates/configmaps.yaml with __DOMAIN__ replaced by
# .Values.ingress.host (no secrets in here, so it stays a ConfigMap).
#
# Mounted at /app/application.yaml — the image has WorkingDir=/app and starts with
# `java -jar app.jar`, so Spring Boot reads ./application.yaml from there. Mounting
# it at / silently does nothing (the engine then falls back to its baked-in
# defaults, which point at Mongo).
#
# Every engine setting is nested under `openfhir:` — `openfhir.db.type` is read via
# @ConditionalOnProperty, so a top-level `db.type` is ignored.
spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/openfhir
    username: ${OPENFHIR_DB_USER:openfhir}
    password: ${OPENFHIR_DB_PASS:openfhir}
  security:
    oauth2:
      resourceserver:
        jwt:
          # The PUBLIC issuer (KC_HOSTNAME) — must match the `iss` Keycloak
          # stamps into tokens. The engine fetches the issuer's OIDC metadata
          # + JWKS through the LB (hairpin), exactly like EHRbase's
          # SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUERURI; a crash-loop
          # until DNS/ingress are up is expected and tolerated on first install.
          issuer-uri: https://__DOMAIN__/auth/realms/freshehr

server:
  port: 8080
  error:
    include-stacktrace: never
    include-message: always

openfhir:
  # Native OAuth2 resource server (vendor-supported): the engine validates
  # Bearer tokens itself with fine-grained per-API scopes (SCOPE_opt.*, fc.*,
  # conceptmap.*, openfhir.map — see the freshehr realm's client scopes), so
  # the /openfhir Ingress carries NO auth-url (mirrors /ehrbase). /health,
  # /status, swagger and / stay permitAll — kubelet probes are unaffected.
  #
  # Multi-tenancy: the engine keys OPTs/mappers/contexts by the JWT `tenant`
  # claim (fallback: `sub`). Every freshehr client carries a hardcoded
  # tenant=freshehr claim mapper so they all share one store. NOTE: the
  # STARTUP bootstrap below runs outside any request context and writes under
  # the engine's internal fallback tenant ("123") — invisible to freshehr
  # tokens. POST /$bootstrap with a token is the canonical loading path in
  # protected mode (see the chart README runbook).
  protected: true

  # postgres | mongo — this stack runs Postgres (the shared `postgres` StatefulSet).
  # NOTE: requires the openfhir-enterprise image; the community openfhir image ships
  # only the Mongo repository implementation.
  db:
    type: postgres

  # Vendor-provided license (gitignored). Without it the engine will not start.
  # Request at https://open-fhir.com#access
  license: /app/openfhir-license.json

  # FHIRConnect mappings + OPT loaded at startup from the mounted bootstrap dir.
  bootstrap:
    dir: /app/bootstrap
    recursively-open-directories: true
