---
name: upgrade-stack
description: Per-cycle runbook for bumping the stack's container images (EHRbase, Postgres, openFHIR, Keycloak, HAPI, hades, oauth2-proxy, nginx) — discovery, changelog checklist, pinning both layers, clean-start verification, and the upgrade report. Use when asked to upgrade, bump, or update the stack's container/image versions.
---

# /upgrade-stack — container upgrade runbook

Work through the steps in order. Do not skip the changelog checklist (step 4):
every constraint in it has already broken this stack once.

## 1. Preflight

- `git status` clean in BOTH repos (this one and `../freshehr-nictiz-ui`).
- Gitignored prerequisite present: `docker/openfhir/license/openfhir-license.json`.
  (The openFHIR HAPI interceptor JAR is NOT a local prerequisite anymore — the
  hapi Dockerfile fetches it from the pinned release asset at build time.)

## 2. Record "before"

Run `make versions` and save the table — it is the "before" half of the report.

## 3. Discover latest releases

| Component | Sources |
|---|---|
| EHRbase | https://github.com/ehrbase/ehrbase/releases + `https://hub.docker.com/v2/repositories/ehrbase/ehrbase/tags/?page_size=25` |
| ehrbase-v2-postgres | the tag the target EHRbase release documents (release notes / its docker-compose) — do NOT bump independently |
| HAPI | `https://hub.docker.com/v2/repositories/hapiproject/hapi/tags/?page_size=25` |
| openFHIR interceptor | `https://api.github.com/repos/openFHIR/openfhir-hapi-interceptor/releases` — pick the newest release that ships an `openfhir-hapi-interceptor-<ver>.jar` **asset** (check each release's `assets[]`; releases ≥ 2.0.0 do, older tags publish none). Confirm its `hapi.fhir.version` in the tag's `pom.xml` is compatible with the HAPI base you're pinning. |
| Keycloak | `https://quay.io/api/v1/repository/keycloak/keycloak/tag/?limit=25` + https://github.com/keycloak/keycloak/releases |
| oauth2-proxy | https://github.com/oauth2-proxy/oauth2-proxy/releases |
| openFHIR | `https://hub.docker.com/v2/repositories/openfhir/openfhir-enterprise/tags/?page_size=25` — enterprise ONLY; if the vendor publishes only `latest`, pin by digest and note it |
| hades | https://github.com/wardle/hades/releases (or `https://api.github.com/repos/wardle/hades/releases/latest`) |
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
- **HAPI + openFHIR interceptor** (two coupled pins, both in
  `docker/hapi/Dockerfile`):
  - The interceptor is compiled against a specific HAPI FHIR **library** version
    (its deps are `provided`-scope, resolved at runtime from the base image), so
    `ARG INTERCEPTOR_VERSION` and `ARG HAPI_BASE` must stay compatible. Check the
    interceptor tag's `pom.xml` `hapi.fhir.version` against the HAPI server image
    tag's bundled library (server image `vX.Y.0-*` bundles HAPI FHIR `X.Y.0`).
    Prefer a HAPI base whose library matches the interceptor's target exactly.
  - The interceptor JAR is fetched at build time via `curl -f` from the GitHub
    **release asset** — there is no local file and no mvn build. Only bump
    `INTERCEPTOR_VERSION` to a tag that publishes a
    `openfhir-hapi-interceptor-<ver>.jar` asset; a tag without one FAILS the
    build by design (that is the intended signal — do not fall back to building
    from source). Upstream ships **no `.sha256`** asset, so there's no checksum
    to pin (unlike hades).
- **hades**: Java baseline still 21? CLI flag changes to `install`/`serve`
  (used by `docker/hades/entrypoint.sh` and `make hades-snomed`)? On bump,
  update `ARG HADES_VERSION` **and** `ARG HADES_SHA256` in
  `docker/hades/Dockerfile` in lockstep — fetch the release's `.jar.sha256`
  asset for the checksum. The image tag in compose/chart is the TEAM tag
  (`ghcr.io/freshehrteam/hades:IMAGE_TAG`), not the upstream version.
- **nginx**: config syntax deprecations affecting `docker/nginx/nginx.conf`.

## 5. Apply the pins — every location, BOTH layers

- `docker/docker-compose.yml` (ehrbase, keycloak, oauth2-proxy, postgres,
  openfhir default, nginx)
- `docker/hapi/Dockerfile` (`ARG HAPI_BASE` + `ARG INTERCEPTOR_VERSION`)
- `docker/hades/Dockerfile` (`ARG HADES_VERSION` + `ARG HADES_SHA256`, in lockstep)
- `charts/health-stack/values.yaml` (same tags as compose)
- **Bump `charts/health-stack/Chart.yaml` `version:`** (terraform no-ops otherwise)

## 6. Clean start (compose = the verification environment)

```bash
make destroy && make build && make up && WAIT_TIMEOUT=420 make wait && make template && make bootstrap
```

(`make destroy` wipes the local db volume — acceptable: template/bootstrap/seed
recreate everything. It also wipes `hades-data`: the first `make up` afterwards
re-bootstraps fhir.db from the public package registry — takes minutes and
needs egress, hence the `WAIT_TIMEOUT=420` — and **any imported SNOMED/LOINC
db is lost and must be re-imported** with `make hades-snomed SNOMED_ZIP=...`.)

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
  docker/hades/Dockerfile \
  charts/health-stack/values.yaml charts/health-stack/Chart.yaml
make destroy && make build && make up
```
