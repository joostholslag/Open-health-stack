---
name: upgrade-stack
description: Per-cycle runbook for bumping the stack's container images (EHRbase, Postgres, openFHIR, Keycloak, HAPI, oauth2-proxy, nginx) — discovery, changelog checklist, pinning both layers, clean-start verification, and the upgrade report. Use when asked to upgrade, bump, or update the stack's container/image versions.
---

# /upgrade-stack — container upgrade runbook

Work through the steps in order. Do not skip the changelog checklist (step 4):
every constraint in it has already broken this stack once.

## 1. Preflight

- `git status` clean in BOTH repos (this one and `../freshehr-nictiz-ui`).
- Gitignored prerequisites present: `docker/openfhir/license/openfhir-license.json`
  and `docker/hapi/extra-classes/*.jar`.

## 2. Record "before"

Run `make versions` and save the table — it is the "before" half of the report.

## 3. Discover latest releases

| Component | Sources |
|---|---|
| EHRbase | https://github.com/ehrbase/ehrbase/releases + `https://hub.docker.com/v2/repositories/ehrbase/ehrbase/tags/?page_size=25` |
| ehrbase-v2-postgres | the tag the target EHRbase release documents (release notes / its docker-compose) — do NOT bump independently |
| HAPI | `https://hub.docker.com/v2/repositories/hapiproject/hapi/tags/?page_size=25` |
| Keycloak | `https://quay.io/api/v1/repository/keycloak/keycloak/tag/?limit=25` + https://github.com/keycloak/keycloak/releases |
| oauth2-proxy | https://github.com/oauth2-proxy/oauth2-proxy/releases |
| openFHIR | `https://hub.docker.com/v2/repositories/openfhir/openfhir-enterprise/tags/?page_size=25` — enterprise ONLY; if the vendor publishes only `latest`, pin by digest and note it |
| nginx | newest stable `-alpine` line (https://nginx.org/en/download.html) |

## 4. Changelog checklist (per component, before touching any pin)

- **EHRbase**: which `MANAGEMENT_ENDPOINT_HEALTH_*` property does the new
  version's bundled application.yml use? (≥2.35 `ACCESS`, ≤2.28 `ENABLED`;
  wrong one = startup crash; must match in compose AND chart.) Flyway/DB
  migration notes? Compatible `ehrbase-v2-postgres` tag?
- **Keycloak**: realm-import behavior or `kc.sh` flag changes? If the realm
  JSON needs touching, edit BOTH copies
  (`docker/keycloak/realm-freshehr.json` +
  `charts/health-stack/config/realm-freshehr.json.tpl`).
- **oauth2-proxy**: flag renames/removals (check the CHANGELOG for the
  `OAUTH2_PROXY_*` vars used in compose + chart).
- **HAPI**: major version bump ⇒ the interceptor JAR must be recompiled
  against the new base (openfhir-hapi-interceptor repo) before `make build`.
- **nginx**: config syntax deprecations affecting `docker/nginx/nginx.conf`.

## 5. Apply the pins — every location, BOTH layers

- `docker/docker-compose.yml` (ehrbase, keycloak, oauth2-proxy, postgres,
  openfhir default, nginx)
- `docker/hapi/Dockerfile` (`ARG HAPI_BASE`)
- `charts/health-stack/values.yaml` (same tags as compose)
- **Bump `charts/health-stack/Chart.yaml` `version:`** (terraform no-ops otherwise)

## 6. Clean start (compose = the verification environment)

```bash
make destroy && make build && make up && make wait && make template && make bootstrap
```

(`make destroy` wipes the local db volume — acceptable: template/bootstrap/seed
recreate everything.)

## 7. Stack gate

`make verify` must exit 0. On the bare-Composition tofhir failure: stale
mappers — `make destroy` and redo step 6.

## 8. UI gate

`cd ../freshehr-nictiz-ui/app && npm run stack:verify` must exit 0.

## 9. Chart gate

`make helm-lint && make helm-render ENV=dev` (hetzner render needs
out-of-band secrets; lint covers both values files).

## 10. Report

- Before/after `make versions` tables.
- Test results (verify + stack:verify + helm gates).
- Changelog notes that mattered (step 4 findings).
- Deferred items (components deliberately NOT bumped, and why).

## 11. Rollback

```bash
git checkout -- docker/docker-compose.yml docker/hapi/Dockerfile \
  charts/health-stack/values.yaml charts/health-stack/Chart.yaml
make destroy && make build && make up
```
