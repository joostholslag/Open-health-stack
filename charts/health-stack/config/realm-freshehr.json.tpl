{
  "realm": "freshehr",
  "enabled": true,
  "sslRequired": "external",
  "accessTokenLifespan": 300,
  "roles": {
    "realm": [
      {
        "name": "USER",
        "description": "EHRbase non-admin API access (SECURITY_OAUTH2USERROLE)"
      },
      {
        "name": "ADMIN",
        "description": "EHRbase /rest/admin/** access (SECURITY_OAUTH2ADMINROLE)"
      },
      {
        "name": "admin",
        "description": "openFHIR $purge access (engine checks ROLE_admin, lowercase)"
      }
    ]
  },
  "clients": [
    {
      "clientId": "api-client",
      "name": "External API callers (curl, tests)",
      "description": "client_credentials service account for host-side callers hitting nginx routes. openFHIR scopes attach as OPTIONAL scopes and are requested via scope= — see the realm-import comment in templates/keycloak.yaml.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__KC_API_CLIENT_SECRET__",
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "fullScopeAllowed": true,
      "protocolMappers": [
        {
          "name": "oauth2-proxy-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": {
            "included.custom.audience": "oauth2-proxy",
            "access.token.claim": "true",
            "id.token.claim": "false"
          }
        },
        {
          "name": "openfhir-tenant",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "tenant",
            "claim.value": "freshehr",
            "jsonType.label": "String",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "userinfo.token.claim": "false"
          }
        },
        {
          "name": "realm-roles",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-realm-role-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "realm_access.roles",
            "jsonType.label": "String",
            "multivalued": "true",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "userinfo.token.claim": "false"
          }
        }
      ],
      "optionalClientScopes": [
        "opt.c",
        "opt.r",
        "opt.u",
        "opt.d",
        "fc.c",
        "fc.r",
        "fc.u",
        "fc.d",
        "conceptmap.c",
        "conceptmap.r",
        "conceptmap.u",
        "conceptmap.d",
        "openfhir.map",
        "openfhir.insights"
      ]
    },
    {
      "clientId": "hapi-svc",
      "name": "HAPI openFHIR interceptor",
      "description": "client_credentials service account the HAPI interceptor uses for the HAPI->EHRbase and HAPI->openFHIR hops. Least privilege: only openfhir.map (optional scope, requested via openfhir.oauth2.scope).",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__KC_HAPI_SVC_SECRET__",
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "fullScopeAllowed": true,
      "protocolMappers": [
        {
          "name": "oauth2-proxy-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": {
            "included.custom.audience": "oauth2-proxy",
            "access.token.claim": "true",
            "id.token.claim": "false"
          }
        },
        {
          "name": "openfhir-tenant",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-hardcoded-claim-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "tenant",
            "claim.value": "freshehr",
            "jsonType.label": "String",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "userinfo.token.claim": "false"
          }
        },
        {
          "name": "realm-roles",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-realm-role-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "realm_access.roles",
            "jsonType.label": "String",
            "multivalued": "true",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "userinfo.token.claim": "false"
          }
        }
      ],
      "optionalClientScopes": [
        "openfhir.map"
      ]
    },
    {
      "clientId": "oauth2-proxy",
      "name": "oauth2-proxy (ingress auth-url edge validator)",
      "description": "Standard-flow client oauth2-proxy authenticates as; also the audience Bearer tokens must carry.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__OAUTH2_PROXY_CLIENT_SECRET__",
      "serviceAccountsEnabled": false,
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "fullScopeAllowed": true,
      "redirectUris": [
        "https://__DOMAIN__/oauth2/callback"
      ],
      "webOrigins": [
        "https://__DOMAIN__"
      ],
      "protocolMappers": []
    }
  ],
  "users": [
    {
      "username": "service-account-api-client",
      "enabled": true,
      "serviceAccountClientId": "api-client",
      "realmRoles": [
        "USER",
        "admin"
      ]
    },
    {
      "username": "service-account-hapi-svc",
      "enabled": true,
      "serviceAccountClientId": "hapi-svc",
      "realmRoles": [
        "USER"
      ]
    }
  ],
  "clientScopes": [
    {
      "name": "opt.c",
      "description": "openFHIR: create operational templates (/opt)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "opt.r",
      "description": "openFHIR: read operational templates (/opt)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "opt.u",
      "description": "openFHIR: update operational templates (/opt)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "opt.d",
      "description": "openFHIR: delete operational templates (/opt)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "fc.c",
      "description": "openFHIR: create FHIR Connect mappers/contexts (/fc)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "fc.r",
      "description": "openFHIR: read FHIR Connect mappers/contexts (/fc)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "fc.u",
      "description": "openFHIR: update FHIR Connect mappers/contexts (/fc)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "fc.d",
      "description": "openFHIR: delete FHIR Connect mappers/contexts (/fc)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "conceptmap.c",
      "description": "openFHIR: create ConceptMaps (/terminology/fhir/ConceptMap)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "conceptmap.r",
      "description": "openFHIR: read ConceptMaps (/terminology/fhir/ConceptMap)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "conceptmap.u",
      "description": "openFHIR: update ConceptMaps (/terminology/fhir/ConceptMap)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "conceptmap.d",
      "description": "openFHIR: delete ConceptMaps (/terminology/fhir/ConceptMap)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "openfhir.map",
      "description": "openFHIR: run mappings (/openfhir/tofhir, /openfhir/toopenehr)",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "openfhir.insights",
      "description": "openFHIR: mapping insights API",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      }
    },
    {
      "name": "roles",
      "description": "Minimal recreation of Keycloak's built-in `roles` scope (defining clientScopes suppresses the built-ins): maps realm roles into realm_access.roles. Realm-wide default so companion-registered clients keep working.",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "false",
        "display.on.consent.screen": "false"
      },
      "protocolMappers": [
        {
          "name": "realm roles",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-realm-role-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "realm_access.roles",
            "jsonType.label": "String",
            "multivalued": "true",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "userinfo.token.claim": "false"
          }
        }
      ]
    }
  ],
  "defaultDefaultClientScopes": [
    "roles"
  ]
}
