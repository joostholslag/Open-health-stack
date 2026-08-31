# freshehr-open-health-stack

A dockerized **openEHR → FHIR** health-data stack — HAPI FHIR (with the openFHIR interceptor), EHRbase, the openFHIR
engine, and nginx — shipped as **three independently-runnable infrastructure-as-code layers**:

| Layer          | Path                                           | What it stands up                                                                                                    |
|----------------|------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| 1 · Local dev  | [`docker/`](docker/)                           | `docker compose` — all services + 1 Postgres + nginx on your laptop                                                  |
| 2 · Kubernetes | [`charts/health-stack/`](charts/health-stack/) | A **Helm chart** (4 workloads + ingress) with values files for `hetzner` (prod) and `dev` (kind)                     |
| 3 · Cloud      | [`terraform/envs/hetzner/`](terraform/)        | Terraform provisions a **Hetzner k3s** cluster, installs ingress-nginx/cert-manager/CSI, then deploys the Helm chart |

> **Distributable.** The app is one Helm chart, published as an OCI artifact to GHCR,
> so it installs without cloning the repo. The chart never branches on the cloud
> provider — the only provider-specific value is `storage.className` — so adding a
> cloud means one new values file plus a Terraform root for that cloud's cluster.
> Only Hetzner ships today (see [Milestones](#milestones)).

It reproduces the end-state of the Dublin openFHIR hackathon, but with **HAPI FHIR instead of Firely**: the [
`openfhir-hapi-interceptor`](https://github.com/openFHIR/openfhir-hapi-interceptor)
JAR turns HAPI into a FHIR facade that routes patient-summary create/query traffic through the openFHIR engine into an
EHRbase openEHR CDR, while all other FHIR traffic falls through to HAPI's own JPA store.

**The shipped mapping set is EPS** (`EPS Patient Summary`) — see
[`docker/openfhir/bootstrap/`](docker/openfhir/bootstrap/). The hackathon original was IPS; the FHIRConnect mappings, the
OPT and the published mappings image (`fhirconnect-eps-mappings`) are all EPS now. One historical name survives on
purpose: the chart's `images.ipsMappings` values key, kept so existing overrides don't break — it names a chart field,
not the mapping set.

## Architecture

```mermaid
flowchart LR
    client([Client])
    subgraph edge[Edge]
        nginx[nginx / ingress-nginx]
    end
    subgraph fhir[FHIR facade]
        hapi[HAPI FHIR<br/>+ openFHIR interceptor]
    end
    openfhir[openFHIR engine]
    ehrbase[EHRbase CDR]
    pg[(Postgres<br/>ehrbase · hapi · openfhir)]

client -->|/fhir /ehrbase /openfhir|nginx
nginx --> hapi
nginx --> ehrbase
nginx --> openfhir
hapi -->|EPS create/query|openfhir
openfhir -->|openEHR REST|ehrbase
hapi --- pg
ehrbase --- pg
openfhir --- pg
```

**Routing table** (nginx in compose; ingress-nginx via the Helm chart in k8s):
`/fhir`→HAPI, `/ehrbase`→EHRbase, `/openfhir`→openFHIR engine.

**DB topology:** **one** Postgres instance with a database each for `ehrbase`,
`hapi` and `openfhir` — see [Database topology](#database-topology) for why, and what production should do differently.

## Database topology

All three services share **one Postgres instance**, each with its own database (`ehrbase`, `hapi`, `openfhir`) and owner
role. The databases are created by
[`docker/ehrbase/init-db.sql`](docker/ehrbase/init-db.sql), which runs after the image's own EHRbase bootstrap.

The instance stays on the **`ehrbase/ehrbase-v2-postgres`** image: EHRbase needs the extensions and role layout that
image pre-provisions, while HAPI and openFHIR are schema-agnostic and just need an empty database to build into (HAPI
creates its JPA tables, openFHIR runs its own Flyway migrations).

> **This is a deliberate non-production choice.** One instance is simpler and cheaper
> to run, and for a reference/integration stack the isolation isn't worth the extra
> moving parts. **For production you would almost certainly separate them**, because:
>
> - **Clinical data deserves its own blast radius.** EHRbase is the system of record.
>   A runaway query, a bad migration, or disk exhaustion caused by the mapping engine
>   should not be able to take down the CDR.
> - **Independent lifecycle and tuning.** The CDR and the mapping engine have very
>   different backup/retention, connection-pool and resource profiles — openFHIR's
>   data is reproducible, EHRbase's is not.
> - **Separate credentials and network policy.** Distinct instances make least-privilege
>   access and audit boundaries far easier to enforce, which matters for clinical data
>   under GDPR/national health-data rules.
> - **Independent scaling and HA.** You would likely run the CDR with replication/PITR
>   (or a managed Postgres) and leave the mapping engine on something cheaper.
>
> The split is a values change, not a redesign: give openFHIR its own StatefulSet (or
> a managed instance) and point `spring.datasource.url` at it.

## Credentials

On Hetzner, **Terraform generates every password** — there are no default or well-known credentials anywhere in the
deployed stack. `random_password` resources in [`terraform/envs/hetzner/main.tf`](terraform/envs/hetzner/main.tf)
produce 32-char values for the Postgres superuser, the EHRbase/HAPI/openFHIR/Keycloak database roles, the Keycloak
admin, the three OIDC client secrets and the oauth2-proxy cookie secret; the chart renders them into Secrets
(`secrets.create=true`) and substitutes them into `init-db.sql`, `cdrs.yml` and the Keycloak realm import so the
roles, the datasources, the realm and every consumer all agree.

Retrieve them:

```bash
cd terraform/envs/hetzner
terraform output -json credentials | jq        # all of them
terraform output -raw kc_api_client_secret     # OIDC client secret for API calls
terraform output -raw keycloak_admin_password  # Keycloak admin console
```

> **⚠ Where these live, honestly.** Terraform stores generated values in
> `terraform.tfstate` **in plaintext** — this is documented Terraform behaviour, and
> `sensitive = true` only masks CLI output, it does not encrypt the file. Kubernetes
> Secrets are base64, not encrypted, and this cluster has no encryption-at-rest or
> RBAC restricting secret reads. So: keep the state file private (it is gitignored
> and should be `chmod 600`), and treat anyone with laptop access as having every
> password.
>
> **This is adequate for a test deployment and is NOT production secret management.**
> For production use External Secrets Operator, Vault, or Sealed Secrets so Terraform
> never sees the values, plus encryption-at-rest, RBAC on secret reads, rotation and
> audit logging.

Two rotation caveats:
> - **Database passwords are baked in on first boot.** `init-db.sql` runs only when
>   the Postgres PVC is empty, so changing a DB password later needs
>   `ALTER USER ... PASSWORD` in-place, or the PVC recreated (data loss).
> - **The openFHIR license Secret is still created out-of-band** — it's a vendor
>   artifact, not a generated credential. See below.

## openFHIR engine

The openFHIR engine **always runs in-cluster** — the stack is self-contained and has no hosted-sandbox mode, so nothing
depends on an external service at runtime.

- **License required.** The engine will not start without the vendor license at
  `docker/openfhir/license/openfhir-license.json` (gitignored) — request one at
  <https://open-fhir.com#access>. In Kubernetes it's the `openfhir-license` Secret.
- **Image must be `openfhir-enterprise`.** The Postgres repository implementation ships only there; the community
  `openfhir` image is Mongo-only and fails with
  `No qualifying bean of type FhirConnectModelRepository` under a Postgres config.
- **No OAuth.** The interceptor only attempts a token request when the token URL, client id *and* secret are all
  non-blank. The in-cluster engine is unauthenticated, so those are left unset — populating them (even with
  placeholders) breaks every store with `Token request failed … invalid_client`.

## Prerequisites & blockers

- **openFHIR license** — **required**; the engine will not start without it.
- **HAPI interceptor JAR** — build input. Clone
  [`openfhir-hapi-interceptor`](https://github.com/openFHIR/openfhir-hapi-interceptor), run
  `mvn clean package -DskipTests`, and drop `target/*.jar` into
  [`docker/hapi/extra-classes/`](docker/hapi/extra-classes/) (gitignored). See that directory's `.gitkeep` for the exact
  commands. *(Alternatively, build the interceptor repo's own multi-stage Dockerfile and reference that image.)*
- **FHIRConnect mappings + OPT** — already vendored into
  [`docker/openfhir/bootstrap/`](docker/openfhir/bootstrap/) from the hackathon repo.
- **Tooling** — Docker + Compose for Layer 1. For Layers 2–3 install `kubectl`,
  `helm`, `terraform`, and `hcloud`. Terraform's `k8s-apps` module installs ingress-nginx/cert-manager/CSI as Helm
  releases and then installs the health-stack chart.

## Quickstart

### Layer 1 — docker compose (local)

```bash
cd docker
cp ../.env.example .env          # fill creds

# One-time: drop the interceptor JAR into hapi/extra-classes/ (see blockers).
docker compose build hapi        # layers the interceptor JAR onto HAPI

# From the repo root you can instead use the Makefile:
#   make build && make up        # (make up also generates dev TLS certs)

docker compose up -d             # all 7 services (needs the openFHIR license)
docker compose ps                # wait for all to be healthy

# One-time per fresh CDR — upload every OPT in docker/openfhir/bootstrap to EHRbase:
#   make template
# One-time per fresh CDR — load openFHIR's mappings + ConceptMaps under tenant
# `freshehr` (required in protected mode; the engine's startup bootstrap writes
# under a different internal tenant and is invisible to API callers):
#   make bootstrap
```

> **⚠ Upgrading an existing checkout to the Keycloak-enabled stack** needs one
> local volume wipe: `docker compose down -v` (postgres init scripts, which now
> also create the `keycloak` database, only run on first boot), then
> `docker compose up -d` and re-run `make template` and `make bootstrap`.

#### Auth (local)

The compose stack is OAuth2-protected end to end by **Keycloak** (realm
`freshehr`, auto-imported from
[`docker/keycloak/realm-freshehr.json`](docker/keycloak/realm-freshehr.json)
with fixed dev secrets) plus **oauth2-proxy** as nginx's `auth_request`
validator. Per-route matrix (all via `https://localhost`):

| Route       | Enforced by                              | Bare request | With Bearer |
|-------------|------------------------------------------|--------------|-------------|
| `/fhir`     | nginx `auth_request` → oauth2-proxy      | 401          | 200         |
| `/ehrbase`  | EHRbase natively (`SECURITY_AUTHTYPE=OAUTH`) | 401      | 200         |
| `/openfhir` | engine natively (`openfhir.protected`, per-API scopes) | 401 | 200 (with scope) |
| `/openfhir/health` | public (engine `permitAll` — probes)| 200          | 200         |
| `/auth`     | public (Keycloak token/discovery/console)| 200          | —           |

The openFHIR engine enforces **fine-grained per-API scopes** (`opt.c/r/u/d`,
`fc.c/r/u/d`, `conceptmap.c/r/u/d`, `openfhir.map`, `openfhir.insights`),
defined as optional client scopes in the realm and requested explicitly via
`scope=` (`make token` does this; the interceptor requests `openfhir.map`).
Every service client also carries a hardcoded `tenant: freshehr` claim — the
engine keys its store (OPTs, mappers, contexts) by that claim, so all clients
share one tenant. Because the engine's *startup* bootstrap runs outside any
request context (different internal tenant), `make bootstrap` with a token is
the canonical way to load mappings in protected mode.

The realm's client inventory (same in the committed dev import and the k8s
realm template — only the secrets differ):

| Client | Type | Used by |
|---|---|---|
| `api-client` | service account (`client_credentials`) | External callers: curl, `make token`, tests — holds all openFHIR scopes |
| `hapi-svc` | service account | HAPI interceptor's HAPI→EHRbase + HAPI→openFHIR hops — least privilege, `openfhir.map` only |
| `oauth2-proxy` | standard flow | The stack's edge Bearer validator (also the audience every service token carries) |

These are the stack's *infrastructure* clients. Applications deployed
alongside (e.g. the nictiz-ui EMR) register their own clients and users
against the realm via the admin API at their own install time — this repo
stays agnostic of them.

`make token` prints a `client_credentials` Bearer token (client `api-client`):

```bash
TOKEN=$(make token)
curl -k -H "Authorization: Bearer $TOKEN" https://localhost/fhir/metadata
```

This maps 1:1 onto the k8s layer: `auth_request` here ⇒ an ingress-nginx
`auth-url` annotation on `/fhir`, while `/ehrbase` and `/openfhir` deliberately
have **no edge auth in either layer** — both are first-class OAuth2 resource
servers, and double-gating a native resource server adds failure modes for no
benefit.

> **Issuer trade-off:** the canonical issuer is pinned to the in-network URL
> `http://keycloak:8080/auth/realms/freshehr` (`KC_HOSTNAME`), so tokens
> validate identically for EHRbase, oauth2-proxy and host callers — who fetch
> tokens from `http://localhost:8081/auth/...` and still get the canonical
> `iss`. The cost: browser SSO redirect flows from the host don't work locally
> (phase 1 is Bearer-API-only). The admin console is exempt
> (`KC_HOSTNAME_ADMIN`): log in at <http://localhost:8081/auth/admin/>
> (`admin`/`admin` by default).

> **EHRbase `PROFILE` scope leniency:** any realm token whose `scope` includes
> `profile` passes EHRbase's non-admin endpoints regardless of whether it
> carries the `USER` role — known EHRbase behavior, not tunable via env.
> `/rest/admin/**` does require the `ADMIN` realm role.

> **Dev bypass:** [`docker-compose.override.yml`](docker/docker-compose.override.yml)
> publishes the direct container ports (8080 hapi · 8082 ehrbase · 8083
> openfhir), skipping nginx — and therefore skipping edge auth on hapi
> (EHRbase and openFHIR still demand a token on their direct ports; both
> validate natively). Rename the file to `.disabled` to run prod-like. Both
> interceptor hops are authenticated via client `hapi-svc`: HAPI→EHRbase
> ([`docker/hapi/cdrs.yml`](docker/hapi/cdrs.yml)) and HAPI→openFHIR
> (`openfhir.oauth2.*` in
> [`docker/hapi/application.yml`](docker/hapi/application.yml)).

> **Mapping sets collide — only one summary set can be loaded at a time.** openFHIR
> keys model mappers by archetype name **globally**, not per template, so the EPS and
> IPS sets cannot coexist: they share five archetypes
> (`COMPOSITION.health_summary.v1`, `EVALUATION.problem_diagnosis.v1`,
> `EVALUATION.adverse_reaction_risk.v2`, `CLUSTER.adverse_reaction_event.v1`,
> `CLUSTER.problem_qualifier.v2`).
>
> **This repo ships EPS only**, so a clean bootstrap does not hit the collision. It
> bites in two cases: you add the IPS set back alongside EPS, or you point the engine
> at a store that already has IPS mappers loaded (an existing CDR, a reused Postgres
> volume). Then `make bootstrap` reports the losers as `FAILED`, and the failure is
> quiet: `/openfhir/tofhir` still answers **200**, but with a bare `Composition` and no
> clinical resources. After bootstrapping, check the ledger for `FAILED` and confirm the
> Bundle has more than one entry. To switch an already-loaded mapper to the other set,
> `PUT /fc/model/{id}` with the YAML and `Content-Type: text/plain`
> (`application/yaml` is a 415).

Verify (`TOKEN=$(make token)`):

| Service  | Check                                                                                     |
|----------|-------------------------------------------------------------------------------------------|
| Keycloak | `curl http://localhost:8081/auth/realms/freshehr/.well-known/openid-configuration` → JSON |
| HAPI     | `curl -k -H "Authorization: Bearer $TOKEN" https://localhost/fhir/metadata` → CapabilityStatement |
| EHRbase  | `curl -k -H "Authorization: Bearer $TOKEN" https://localhost/ehrbase/rest/status` → 200   |
| openFHIR | `curl -k -H "Authorization: Bearer $TOKEN" https://localhost/openfhir/fc/context` → 200 (`/openfhir/health` is public — permitAll) |
| nginx    | `curl -k https://localhost/` → route banner (no auth on the banner)                       |

`make smoke` runs the full auth matrix for you (each data route must **401**
bare and **200** with a token, plus OIDC discovery). Generate the dev TLS certs
with `make certs` (or the `openssl` one-liner in
[`docker/nginx/certs/.gitkeep`](docker/nginx/certs/.gitkeep)).

**End-to-end sanity:** run `make template` and `make bootstrap` once, then POST an EPS `Composition` bundle to `/fhir` → **201**, and the
composition is queryable in EHRbase via AQL. Both are **required on a fresh stack**: `make template` loads EHRbase, and
`make bootstrap` loads openFHIR's mappings + ConceptMaps under the `freshehr` tenant (the engine's startup bootstrap
writes under a different internal tenant and is invisible to API callers in protected mode). If you skip
`make template` you get `422 Could not retrieve template`; if you skip `make bootstrap` the mapping run fails
(no context / "No such … ConceptMap exists"). A
`No EHR ID found for patient … on CDR 'local'` response also proves the interceptor → openFHIR → EHRbase path is live
(it just means the Patient doesn't exist in HAPI yet).

### Layer 2 — Kubernetes (Helm chart)

The app is a single chart at [`charts/health-stack/`](charts/health-stack/); the values files set the only things that
vary (storage class, ingress host, sizing). See the
[chart README](charts/health-stack/README.md) for the full values contract and install matrix.

```bash
# Render (no cluster needed) to eyeball the manifests:
helm template health-stack charts/health-stack -n health-stack \
  -f charts/health-stack/values-dev.yaml

# Install on a local cluster (kind / minikube). values-dev renders placeholder
# Secrets; you must still create the openfhir-license Secret out-of-band:
helm upgrade --install health-stack charts/health-stack \
  -n health-stack --create-namespace -f charts/health-stack/values-dev.yaml
kubectl get pods -n health-stack           # all Ready

# Reach HAPI via its dev NodePort (30080) or port-forward:
kubectl port-forward -n health-stack svc/hapi 8080:8080
curl http://localhost:8080/fhir/metadata
```

For a **standalone** install (no Terraform), use `values-hetzner.yaml` and create the Secrets yourself from [
`charts/health-stack/secrets.example.yaml`](charts/health-stack/secrets.example.yaml). *(Deploying via Terraform on
Hetzner? Skip this — it generates every password and renders these Secrets for you; see [Credentials](#credentials).
Only the openFHIR license Secret is still manual.)*

```bash
cp charts/health-stack/secrets.example.yaml charts/health-stack/secrets.yaml  # edit
kubectl apply -n health-stack -f charts/health-stack/secrets.yaml
helm upgrade --install health-stack charts/health-stack \
  -n health-stack --create-namespace \
  -f charts/health-stack/values-hetzner.yaml \
  --set ingress.host=health.yourdomain.com
```

| Environment | Values file           | storage class    | openFHIR   |
|-------------|-----------------------|------------------|------------|
| Hetzner k3s | `values-hetzner.yaml` | `hcloud-volumes` | `local`    |
| kind / dev  | `values-dev.yaml`     | *(default)*      | in-cluster |

- **One Deployment+Service per app, one StatefulSet+headless-Service+PVC per Postgres.** Config files become ConfigMaps
  (kept in sync with `docker/`), with a
  `checksum/config` annotation so pods roll when config changes. The openFHIR bootstrap mappings + binary OPT are
  delivered by an **initContainer** that copies them into a shared `emptyDir`.
- **The openFHIR engine is always deployed** and needs the `openfhir-license`
  Secret in every environment, including kind.
- **Not published to any chart registry.** Terraform installs the chart from its
  path in this repo, so a packaged copy in a registry would be a second artifact
  that nothing installs from — and that can silently disagree with the working
  tree. CI validates the chart on every change instead
  (see [`helm-lint.yml`](.github/workflows/helm-lint.yml)). If external consumers
  ever need `helm install oci://...`, add the publish job back *and* point
  `helm_release.chart` at the registry, so what is published is what is deployed.

### Layer 3 — Terraform (Hetzner)

The root at [`terraform/envs/hetzner/`](terraform/envs/hetzner/) wires the `hcloud-*`
provisioning modules + the `k8s-apps` module (which installs the add-ons and the health-stack chart). The
kubernetes/helm providers need the cluster's kubeconfig, so every apply is **two-phase**.

**Order matters:** DNS must resolve to the load balancer *before* phase 2, or
cert-manager's HTTP-01 challenge fails and you burn Let's Encrypt's rate limit
(5 failed validations per hour).

#### 0 · Configure

```bash
cd terraform/envs/hetzner
cp terraform.tfvars.example terraform.tfvars
```

Fill in at least:

```hcl
hcloud_token      = "<64-char token>"   # Console → Security → API Tokens (Read & Write)
domain            = "health.yourdomain.com"
letsencrypt_email = "you@example.com"
admin_ssh_cidrs   = ["<your.ip>/32"]    # curl ifconfig.me — also opens the k8s API :6443
```

> `admin_ssh_cidrs` gates **both** SSH and the Kubernetes API. If your IP changes,
> `kubectl` and `terraform apply` start timing out — update it and re-apply (a ~10 s
> in-place firewall change).

#### 1 · Phase 1 — provision the cluster (~5 min)

```bash
terraform init
terraform apply -var 'install_apps=false'         # make tf-cluster
```

Verify the cluster is up before continuing:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes                                  # all Ready
```

#### 2 · Point DNS at the load balancer

```bash
terraform output load_balancer_ipv4                # e.g. 203.0.113.10
```

Create an **A record** for your `domain` pointing at that IP (TTL 300), then **wait
for it to resolve** — do not skip this:

```bash
watch -n10 "dig +short health.yourdomain.com"      # Ctrl-C once it prints the LB IP
```

#### 3 · Create the openFHIR license Secret

Every other credential is generated by Terraform (see [Credentials](#credentials));
the vendor license is the only one you supply:

```bash
kubectl create namespace health-stack
kubectl create secret generic openfhir-license -n health-stack \
  --from-file=openfhir-license.json=../../../docker/openfhir/license/openfhir-license.json
```

#### 4 · Phase 2 — add-ons + the chart (~5 min)

```bash
terraform apply                                    # make tf-apply
kubectl get pods -n health-stack -w                # Ctrl-C when all Running
```

Postgres comes up first, then openFHIR (~1 min), then HAPI (~2 min — slow JVM start).

#### 5 · Get your credentials

```bash
terraform output -json credentials | jq            # all generated passwords
terraform output -raw kc_api_client_secret         # OIDC client secret for API calls
terraform output -raw keycloak_admin_password      # Keycloak admin console (user `admin`)
```

#### 6 · Verify — health checks & exposed APIs

Set these once (every data route takes the same Bearer token):

```bash
D=health.yourdomain.com
# scope=… is required for the openFHIR data APIs: the per-API scopes are
# OPTIONAL client scopes in the realm and only enter the token when requested.
TOKEN=$(curl -sX POST https://$D/auth/realms/freshehr/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=api-client \
  -d client_secret=$(terraform output -raw kc_api_client_secret) \
  --data-urlencode "scope=opt.c opt.r opt.u opt.d fc.c fc.r fc.u fc.d conceptmap.c conceptmap.r conceptmap.u conceptmap.d openfhir.map openfhir.insights" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
```

**Cluster level**

```bash
kubectl get pods -n health-stack        # Running: postgres, ehrbase, openfhir, hapi ×2, keycloak, oauth2-proxy
kubectl get certificate -n health-stack # READY=True once Let's Encrypt has issued
kubectl get ingress -n health-stack     # FOUR: health-stack, -ehrbase, -openfhir, -auth
```

**Public endpoints** — every route below is served through the ingress over HTTPS.
Anything other than the expected status means that service is unhealthy:

| Service | Endpoint | Auth | Expect |
|---|---|---|---|
| Keycloak | `GET /auth/realms/freshehr/.well-known/openid-configuration` | none | `200` — OIDC discovery JSON |
| HAPI FHIR | `GET /fhir/metadata` | **Bearer** (edge) | `200` — CapabilityStatement JSON |
| HAPI (Spring) | `GET /actuator/health` | none — no ingress route | not publicly reachable |
| openFHIR | `GET /openfhir/health` | none (engine `permitAll`) | `200` — `UP` |
| openFHIR | `GET /openfhir/fc/context` | **Bearer** (app, scope `fc.r`) | `200` — EPS FHIRConnect context JSON |
| EHRbase | `GET /ehrbase/rest/status` | **Bearer** (app) | `200` — version/status JSON |
| EHRbase | `GET /ehrbase/rest/openehr/v1/definition/template/adl1.4` | **Bearer** (app) | `200` — list of uploaded OPTs |

```bash
curl -sS -H "Authorization: Bearer $TOKEN" -o /dev/null -w 'hapi        %{http_code}\n' https://$D/fhir/metadata
curl -sS -H "Authorization: Bearer $TOKEN" -o /dev/null -w 'openfhir    %{http_code}\n' https://$D/openfhir/health
curl -sS -H "Authorization: Bearer $TOKEN" -o /dev/null -w 'fc/context  %{http_code}\n' https://$D/openfhir/fc/context
curl -sS -H "Authorization: Bearer $TOKEN" -o /dev/null -w 'ehrbase     %{http_code}\n' https://$D/ehrbase/rest/status

# The gate itself: no token must be rejected on every data route.
# /fhir answers 302 (redirect into the oauth2-proxy sign-in flow — the
# auth-signin annotation; set ingress.auth.signin=false for strict 401s);
# /ehrbase and /openfhir answer 401 (native validation, no signin redirect;
# /openfhir/health is permitAll and answers 200 bare by design).
curl -sS -o /dev/null -w 'hapi     no-auth %{http_code} (expect 302)\n' https://$D/fhir/metadata
curl -sS -o /dev/null -w 'openfhir no-auth %{http_code} (expect 401)\n' https://$D/openfhir/fc/context
curl -sS -o /dev/null -w 'ehrbase  no-auth %{http_code} (expect 401)\n' https://$D/ehrbase/rest/status
```

> **One token, two enforcement layers — and they never stack.** `/fhir` is gated
> by an **ingress-nginx** `auth-url` subrequest to the in-cluster oauth2-proxy;
> `/ehrbase` and `/openfhir` are validated by the **apps themselves**
> (`SECURITY_AUTHTYPE=OAUTH` for EHRbase; `openfhir.protected=true` for the
> engine, with fine-grained per-API scopes — `opt.*`, `fc.*`, `conceptmap.*`,
> `openfhir.map`, `openfhir.insights` — and a shared `tenant: freshehr` claim
> keying the engine's data store). All three accept the same `api-client`
> Bearer token from the `freshehr` realm.
>
> `/ehrbase` and `/openfhir` deliberately have **no edge auth**: both validate
> every request natively, so an edge gate would double-validate the same token
> and add failure modes for no security gain (mirrors the compose nginx split).
>
> Because `auth-url` is an **Ingress-level** annotation (not per-path), routes with
> different auth requirements need different Ingress objects. The chart renders four:
>
> | Ingress | Path | Backend | Edge auth |
> |---|---|---|---|
> | `health-stack` | `/fhir` | HAPI | ✅ Bearer via oauth2-proxy |
> | `health-stack-ehrbase` | `/ehrbase` | EHRbase | ❌ (native validation) |
> | `health-stack-openfhir` | `/openfhir` | openFHIR | ❌ (native validation, per-scope) + rewrite |
> | `health-stack-auth` | `/auth`, `/oauth2` | Keycloak / oauth2-proxy | public |
>
> **Why HAPI needs edge auth at all:** it doesn't authenticate on its own.
> An unauthenticated `/fhir` accepts `POST`/`PUT`/`DELETE` on every resource type, and
> the openFHIR interceptor forwards matching writes into EHRbase — so an open `/fhir`
> is a write path into the CDR.
>
> Edge auth applies **only to ingress traffic**. The kubelet probes hit the pod
> IP directly (openFHIR's `/health` is `permitAll`), so they need no
> credentials. Both interceptor hops authenticate with the `hapi-svc`
> client_credentials account, fetching tokens from the in-cluster `keycloak`
> Service: HAPI→EHRbase (cdrs.yml) and HAPI→openFHIR (`openfhir.oauth2.*` with
> `scope=openfhir.map` in the hapi-config Secret's application.yml).
>
> **`/actuator/health` has no ingress route** — it never did; the old table listed it
> as a public endpoint, but only `/fhir`, `/ehrbase` and `/openfhir` are routed. Check
> it in-cluster: `kubectl exec -n health-stack deploy/hapi -- curl -s localhost:8080/actuator/health`.
>
> **Postgres is deliberately not exposed** — it has no ingress route and is reachable
> only in-cluster at `postgres:5432`. Check it via `kubectl get pods` or
> `kubectl exec -n health-stack postgres-0 -- pg_isready`.

**Debugging from inside the cluster** (bypasses ingress/TLS, isolates whether a problem
is the service or the routing):

```bash
kubectl run tmp --rm -it --restart=Never --image=curlimages/curl:8.10.1 -n health-stack -- \
  sh -c 'curl -sS http://openfhir:8080/health; curl -sS http://hapi:8080/fhir/metadata -o /dev/null -w " hapi %{http_code}\n"'

kubectl logs -n health-stack deploy/hapi     | grep -i 'registering custom interceptor'
kubectl logs -n health-stack deploy/openfhir | grep -iE 'PostgresConfig|Started OpenFhir'
```

**End-to-end (the real gate).** Health endpoints only prove each service is up — this
proves the *chain* works. Once per fresh CDR: upload the EPS operational template to
EHRbase, load openFHIR's mappings under the `freshehr` tenant (required in protected
mode — the engine's startup bootstrap writes under a different internal tenant and is
invisible to API callers), then POST a bundle:

```bash
curl -sS -H "Authorization: Bearer $TOKEN" \
  -X POST https://$D/ehrbase/rest/openehr/v1/definition/template/adl1.4 \
  -H 'Content-Type: application/xml' -H 'Accept: application/xml' \
  --data-binary @"../../../docker/openfhir/bootstrap/EPS Patient Summary.opt" \
  -w '\nOPT %{http_code}\n'                        # 201 first run, 409 after

curl -sS -H "Authorization: Bearer $TOKEN" -X POST "https://$D/openfhir/\$bootstrap" \
  -o /dev/null -w 'bootstrap %{http_code}\n'       # mappings + contexts + OPT (tenant freshehr)
for cm in ../../../docker/openfhir/bootstrap/*/*_conceptmap.json; do   # $bootstrap skips ConceptMap JSONs
  curl -sS -H "Authorization: Bearer $TOKEN" -X POST https://$D/openfhir/terminology/fhir/ConceptMap \
    -H 'Content-Type: application/json' --data-binary @"$cm" -o /dev/null -w "conceptmap $(basename $cm) %{http_code}\n"
done                                               # 2xx first run, 500 "already exists" after (conflict, not failure)

curl -sS -H "Authorization: Bearer $TOKEN" \
  -X POST https://$D/fhir -H 'Content-Type: application/fhir+json' \
  --data-binary @<your-eps-bundle.json> -w '\nEPS %{http_code}\n'   # expect 201

# Confirm it landed in the CDR as an openEHR composition:
curl -sS -H "Authorization: Bearer $TOKEN" -X POST https://$D/ehrbase/rest/openehr/v1/query/aql \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"q":"SELECT c/uid/value, c/archetype_details/template_id/value FROM EHR e CONTAINS COMPOSITION c"}'
```

Troubleshooting the end-to-end path:

| Symptom | Cause |
|---|---|
| `OPT 413` | Body too large — the `proxy-body-size` ingress annotation is missing (the OPT is ~3 MB) |
| `EPS 500` + `CDR store failed with status 422` | OPT was never registered — run the upload above first |
| `EPS 401` | Edge OAuth — the `POST /fhir` is missing (or has an expired) `Authorization: Bearer` header; tokens live 5 min, re-run the `TOKEN=` fetch |
| `No EHR ID found for patient …` | **The chain is working.** The Patient just doesn't exist in HAPI yet — `PUT /fhir/Patient/<id>` first |
| A plain HAPI JPA response instead of an error | The interceptor did **not** load — check the HAPI log line above |

#### Teardown

```bash
terraform destroy      # stops all billing; the LB IP is released, so DNS needs
                       # updating next time
```

> **See [docs/hetzner-architecture.md](docs/hetzner-architecture.md)** for a diagram of
> what gets created on Hetzner — servers, control-plane vs agents, the LB, and where each
> container ends up — plus how to run it on a single node for testing.

#### Cluster sizing — what the default gives you, and what it doesn't

The default is **3 servers**: one k3s control-plane (`cx23`) and two identical agents (`cx33`, created with `count`,
same cloud-init, same role). "Agent" is k3s's word for *worker node*. The control-plane here is **not tainted**, so it
runs pods too.

Today the stack is **5 pods** (HAPI, EHRbase, openFHIR, Postgres, plus ingress-nginx and the other add-ons in their own
namespaces). That fits on a single node. So the second and third servers currently buy **headroom and self-healing — not
high availability**:

| Scenario           | 3 servers (default)                                                   | 1 server (`agent_count = 0`)    |
|--------------------|-----------------------------------------------------------------------|---------------------------------|
| Capacity           | ~16 GB across agents                                                  | 8 GB                            |
| A node dies        | pods **restart** on a survivor (~60–90 s downtime)                    | down until you replace the node |
| Postgres node dies | down either way — the `ReadWriteOnce` volume must detach and reattach |
| Control-plane dies | cluster unmanageable (only 1 control-plane in both cases)             |
| Cost incl. LB      | ~€24/mo                                                               | ~€13/mo                         |

**Why it isn't HA yet.** Every workload is `replicas: 1`, so there is no second instance already serving — Kubernetes
*reschedules*, which is a restart, not a failover. Postgres is a StatefulSet on a single `ReadWriteOnce` hcloud Volume
that attaches to exactly one node. And there is one control-plane, so losing it stops all scheduling regardless of how
many agents exist.

> **Preferred shape for a test environment (not yet applied).** Consolidate onto a
> **single, larger node** rather than three small ones:
>
> ```hcl
> control_plane_type = "cx43"   # 8 vCPU / 16 GB — or cx33 (4/8) to also cut cost
> agent_count        = 0
> ```
>
> k3s schedules pods on the untainted control-plane, so one server runs everything.
> `cx43` is roughly cost-neutral versus the 3-node default (~€20 vs ~€24/mo incl. LB);
> `cx33` roughly halves it. Phase 1 drops from 14 → 12 resources.
>
> Why it's better *for this workload*: the 5 pods are independent processes that don't
> cooperate, so they can't tell whether their CPU/RAM comes from one box or three.
> Consolidating means **all inter-service traffic becomes loopback** instead of flannel
> VXLAN across the private network (HAPI → openFHIR → EHRbase → Postgres is a chatty
> path), **no `ReadWriteOnce` volume-affinity constraint** on scheduling, and **one
> kubelet/NIC/host to patch** instead of three.
>
> Nothing is lost: there is no HA today either way (see above). Note `cx33` is a
> *downsize* in total capacity (4 vCPU/8 GB vs 10 vCPU/20 GB across three nodes) — ample
> for 5 pods, but size up if the JVMs get OOM-killed.
>
> **Not applied yet** because the running stack is verified end-to-end and reshaping
> costs a `terraform destroy`, a new LB IP, a DNS update and full re-verification. Do it
> at the next teardown, when it's free. Revert to multiple nodes at step 2 below —
> replicas + anti-affinity is the point where extra nodes start doing real work.

**Scaling path, in the order that actually buys something:**

1. **Need more room?** Raise `agent_count`, or move to bigger `agent_type` /
   `control_plane_type`. Pure capacity — one line in `terraform.tfvars`, then re-apply.
2. **Want real app-level HA?** Set `hapi.replicas` / `ehrbase.replicas` /
   `openfhir.replicas` to 2+ **and** add pod anti-affinity so replicas land on different nodes (the chart already
   exposes `affinity`). Only now do multiple agents remove downtime — this is the step that turns the default 3 nodes
   into something useful.
3. **Want the database to survive a node loss?** Replace the single Postgres StatefulSet with a replicated operator
   (CloudNativePG, Patroni) or a managed Postgres. Until this, the CDR is the single point of failure no matter what
   else you scale. Pairs naturally with splitting the shared instance — see [Database topology](#database-topology).
4. **Want the cluster itself to survive?** Run 3 control-plane nodes with embedded etcd. This is a change to the
   `hcloud-cluster` module, not a variable.

For a **test environment**, `agent_count = 0` is enough and roughly half the cost; the LB still finds the control-plane
because it targets the `cluster=` label, which every node carries. The 2-agent default is kept as a sensible
production-shaped starting point.

Module layout (`terraform/modules/`):

- **`hcloud-network` / `hcloud-cluster` / `hcloud-lb`** — Hetzner: private network, cloud-init k3s nodes + firewall, and
  the LB fronting the ingress-nginx NodePorts.
- **`k8s-apps`** — installs the hcloud CCM/CSI + ingress-nginx + cert-manager (Helm), then `helm_release`s the
  health-stack chart with `values-hetzner.yaml`.

To add another cloud: write a `<cloud>-cluster` module that writes a kubeconfig to a known path and exposes a
`node_label_selector` + endpoint, add a root under
`terraform/envs/<cloud>`, and add a values file setting `storage.className`. The chart and `k8s-apps`' add-on half are
already provider-neutral.

## Milestones

Status vocabulary is deliberate: **verified** = actually run and observed; **authored** = written and statically
checked, but never executed. Don't promote a row without doing the thing.

| #      | Milestone                                        | Status                                                                                                                                                                                            |
|--------|--------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **M1** | Compose, openEHR→FHIR stack end-to-end           | ✅ **verified** (2026-08-08) — patient-summary bundle POSTed to `/fhir` → `201`, composition stored in EHRbase (see below). *Verified against the IPS set; the shipped set is now EPS.*          |
| **M2** | openFHIR engine + bootstrap + license            | ✅ **verified** (2026-08-08) — engine on Postgres, mappings bootstrapped                                                                                                                          |
| **M3** | CI builds/pushes the custom HAPI image, pin tags | 🟡 **authored** — workflow in [`.github/workflows/`](.github/workflows/); never run in CI                                                                                                         |
| **M4** | Helm chart on local k8s (kind)                   | 🟡 **authored** — `helm lint` + `helm template` pass (20 objects for `values-dev`); **never installed on a cluster** (no kind/minikube available)                                                 |
| **M5** | Terraform + Hetzner (k3s, ingress, TLS)          | ✅ **verified** (2026-08-31) — applied on a live hcloud cluster (3 nodes + LB, DNS + Let's Encrypt TLS at health.example.com); in-place `helm upgrade`s via `terraform apply` exercised |
| **M6** | Keycloak / auth                                  | ✅ **verified** (2026-08-31) — Keycloak + oauth2-proxy with OAuth2 on all three data routes, on BOTH layers: compose (see [Auth (local)](#auth-local)) and the live Hetzner cluster (token matrix: bare/garbage rejected, Bearer 200 on `/fhir`, `/ehrbase`, `/openfhir`). openFHIR now validates **app-level** (`openfhir.protected`, per-API scopes + `tenant` claim) instead of the edge gate — verified on compose; a live Hetzner cluster needs the realm update + `$bootstrap` re-home (chart README runbook). Still machine-clients only — no human users/audit trail yet |
| **M7** | OCI-published chart                              | 🟡 **authored** — [`helm-publish.yml`](.github/workflows/helm-publish.yml) pushes to GHCR on `v*` tags; never released                                                                            |

> **Multi-cloud (AWS EKS / Azure AKS) was removed on 2026-08-08.** It had been fully
> authored but never applied, and there are no live deals on those clouds. The chart is
> provider-neutral, so re-adding one is a values file plus a Terraform root — see
> Layer 3. History: [
`nimbalyst-local/plans/multi-cloud-distribution.md`](nimbalyst-local/plans/multi-cloud-distribution.md).

> **Identity status.** All three layers now carry the same OAuth2 architecture:
> Keycloak (realm `freshehr`, client-credentials service accounts, realm roles
> `USER`/`ADMIN`) + oauth2-proxy edge validation on `/fhir` + `/openfhir`, with
> EHRbase validating natively. The **compose stack** is verified end-to-end (see
> [Auth (local)](#auth-local)); the **Helm chart + Terraform** port (Keycloak and
> oauth2-proxy Deployments, `/auth` + `/oauth2` Ingress, ingress `auth-url`
> replacing the old basic auth, generated `random_password` client secrets) is
> applied and verified on the live Hetzner cluster.
>
> Both layers are **verified** (2026-08-31): the compose stack end-to-end
> locally, and the Helm/Terraform port applied in-place on the live Hetzner
> cluster (Keycloak DB created manually on the existing Postgres — init scripts
> don't rerun; see `charts/health-stack/config/init-db.sql.tpl`).
>
> Human login exists at the application layer: the nictiz-ui EMR gates its
> host with its own session-mode oauth2-proxy and registers its clients + a
> demo user against this realm at install time (admin-API Job — which also
> sidesteps `--import-realm`'s no-update-on-existing-realm limitation). Still
> short of an identity *system*: one demo account, no per-user RBAC beyond the
> `USER`/`ADMIN` realm roles, no audit trail.

### Proving M1/M2 yourself

```bash
make build                      # JAR must be in docker/hapi/extra-classes/ first
make certs
docker compose -f docker/docker-compose.yml up -d
make template                   # one-time per fresh CDR: upload every OPT in the bootstrap dir to EHRbase
make bootstrap                  # one-time per fresh CDR: load openFHIR mappings + ConceptMaps (tenant freshehr)
make smoke                      # auth matrix: 401 bare / 200 with token per route
# then POST an EPS bundle with a Bearer token (TOKEN=$(make token)) to
# https://localhost/fhir → expect 201  (or unauthenticated to the
# http://localhost:8080 dev-bypass port — see Auth (local))
```

`make template` and `make bootstrap` are **required** before the first POST: `make template` loads the OPT into
EHRbase (or writes fail `422 Could not retrieve template for template Id: EPS Patient Summary`), and `make bootstrap`
loads openFHIR's mappings + ConceptMaps under the `freshehr` tenant (in protected mode the engine's startup bootstrap
is invisible to API callers).

## Repository layout

```
freshehr-open-health-stack/
├── README.md · Makefile · .env.example · .gitignore
├── .github/workflows/          # build-images (HAPI) + helm-publish (chart → GHCR OCI)
├── docker/                     # Layer 1 — compose, Dockerfile, configs, init SQL, nginx, keycloak realm
├── charts/health-stack/        # Layer 2 — Helm chart + values (hetzner/dev)
└── terraform/
    ├── modules/                # hcloud-network · hcloud-cluster · hcloud-lb · k8s-apps
    ├── cloud-init/             # k3s bootstrap templates (Hetzner)
    └── envs/hetzner/           # Layer 3 — the Hetzner k3s root
```

## What is / isn't committed

Secrets never land in git. `.gitignore` excludes `.env`, `*.tfvars`, `*.tfstate`, kubeconfigs, the openFHIR license, the
interceptor JAR, and TLS certs. The
`*.example` / `secrets.example.yaml` / `.gitkeep` files document exactly what to provide and where.
