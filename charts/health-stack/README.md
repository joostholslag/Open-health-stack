# health-stack Helm chart

The **freshehr-open-health-stack** application layer as a Helm chart: HAPI FHIR
(with the openFHIR interceptor), EHRbase, the openFHIR engine, hades (FHIR
terminology server), Keycloak (OIDC IdP, realm `freshehr`), oauth2-proxy (edge
Bearer validator), and their shared Postgres backend.

Runs on any Kubernetes cluster. Two values files ship with it — `values-hetzner.yaml`
(prod) and `values-dev.yaml` (kind/minikube). The templates never branch on the cloud
provider, so targeting another one is a new values file setting mostly the **storage
class**, plus the **ingress host** and a few **image tag / sizing** knobs.

## Install

Installed from this repo, not from a chart registry — Terraform's `k8s-apps`
module points `helm_release.chart` at this directory. CI validates the chart on
every change (`.github/workflows/helm-lint.yml`) but publishes nothing.

```bash
helm upgrade --install health-stack charts/health-stack \
  -n health-stack --create-namespace \
  -f charts/health-stack/values-hetzner.yaml \
  --set ingress.host=health.yourdomain.com
```

> Terraform installs this chart for you (see `terraform/envs/hetzner`); the manual
> commands above are for standalone / non-Terraform installs.

## Install matrix

| Environment | Values file | `storage.className` | `ingress` Service | openFHIR |
|-------------|-------------|---------------------|-------------------|----------|
| Hetzner k3s | `values-hetzner.yaml` | `hcloud-volumes` | NodePort (hcloud LB fronts it) | in-cluster |
| kind / dev | `values-dev.yaml` | *(cluster default)* | NodePort 30080, no TLS | in-cluster |

Prod uses ingress-nginx + cert-manager + Let's Encrypt.

### Routing and auth — five Ingress objects

`auth-url` and `rewrite-target` are **Ingress-level** annotations, not per-path, so
each route with a different annotation set needs its own object:

| Ingress | Path | Backend | Edge OAuth (auth-url) | Rewrite |
|---|---|---|---|---|
| `health-stack` | `/fhir` | HAPI | ✅ | — |
| `health-stack-ehrbase` | `/ehrbase` | EHRbase | ❌ (validates natively) | — |
| `health-stack-openfhir` | `/openfhir` | openFHIR | ❌ (validates natively, per-API scopes) | strips prefix |
| `health-stack-terminology` | `/terminology` | hades | ✅ (no app-level auth; SNOMED licensing) | strips prefix |
| `health-stack-auth` | `/auth`, `/oauth2` | Keycloak / oauth2-proxy | public | — |

hades serves its FHIR API under `/fhir/...` on its own port, and `/fhir` at the
edge belongs to HAPI — so the public shape is
`https://<host>/terminology/fhir/CodeSystem/$lookup` (prefix stripped, like
`/openfhir`). It carries the same edge gate as `/fhir`: hades has no
application-level auth, and once SNOMED CT is imported its license terms
preclude serving it openly.

The whole stack authenticates against the in-cluster **Keycloak** (realm
`freshehr`, imported from
[`config/realm-freshehr.json.tpl`](config/realm-freshehr.json.tpl) with client
secrets substituted from `secrets.values.keycloak`). HAPI has
**no application-level auth** — an open `/fhir` accepts anonymous writes, and
the openFHIR interceptor carries them into EHRbase. Hence the edge gate on
`/fhir`: ingress-nginx sends an `auth-url` subrequest to **oauth2-proxy**,
which validates the Bearer JWT (signature, issuer, `aud=oauth2-proxy`).

`/ehrbase` and `/openfhir` are exempt on purpose: both validate every request
themselves (`SECURITY_AUTHTYPE=OAUTH` for EHRbase; `openfhir.protected=true`
for the engine, which additionally enforces fine-grained per-API scopes —
`opt.*`, `fc.*`, `conceptmap.*`, `openfhir.map`, `openfhir.insights` — and
keys its data store by the JWT `tenant` claim, hardcoded to `freshehr` on
every service client). An edge gate would double-validate the same token for
no gain. The engine's `/health`, `/status` and swagger stay `permitAll`, so
kubelet probes are unaffected.

`/ehrbase` additionally passes through an OPA-backed PEP before it ever
reaches EHRbase: the `ehrbase` Pod runs three containers (`ehrbase-gateway`,
`opa`, `ehrbase`), and the `ehrbase` Service targets the gateway, not the CDR
container directly (see [`templates/ehrbase.yaml`](templates/ehrbase.yaml) and
[`config/ehrbase-gateway-nginx.conf`](config/ehrbase-gateway-nginx.conf)). This
is transparent to callers — HAPI and openFHIR reach the same Service and see
no config difference — and mirrors EHRbase's own USER/ADMIN check, plus one
additional restriction layered on top: the single-template GET
(`/ehrbase/rest/openehr/v1/definition/template/adl1.4/{template_id}` — the
one EHRbase endpoint that names a template in its path) is further gated by
a `(user_role, template_id, operation)` allowlist in
[`config/ehrbase-gateway-datasource.json`](config/ehrbase-gateway-datasource.json),
ported from [jorritspee/openEHRxNuts#14](https://github.com/jorritspee/openEHRxNuts/pull/14).
Two demo persona roles exercise it end-to-end — `dokter` (granted READ on the
`EPS Patient Summary` template) and `verpleegkundige` (deliberately not
granted, so it gets denied there) — held by the real interactive Keycloak
users `dokter-joost`/`verpleegkundige-bas` in `realm-freshehr.json` (nictiz-ui
logs these in through its own client; the realm's `verify-cli` public client
exists only so `scripts/verify.sh` can fetch a token for them without a
browser).

**Caveat confirmed live on Scaleway (2026-09-19):** nictiz-ui's composition
form fetches the web template with its own backend service credential
(`nictiz-ui-svc`, same `USER`+`admin` shape as `api-client`/`hapi-svc`), not
the logged-in clinician's token — so the `dokter`/`verpleegkundige` allowlist
can never apply to that call path; there's no individual user's roles in
play there, only the shared service account's. `authz.rego` carries a third
`allow` rule for the template-definition path that lets any `admin`-role
holder through regardless of template, mirroring how `admin` already grants
openFHIR's `$purge`. This is a deliberate trade-off, not a bug: any current
or future holder of `admin` gets blanket template-definition READ, and
per-user distinction on this one endpoint only actually applies to a caller
presenting its own token directly (not routed through nictiz-ui's BFF).
Restoring real per-clinician scoping there would mean nictiz-ui forwarding
the individual user's own Bearer token for this fetch instead — not done.

See [`config/ehrbase-gateway-authz.rego`](config/ehrbase-gateway-authz.rego)
for the rules and the extension point for other resources/operations, which
is still just USER/ADMIN today. The table above still lists `/ehrbase` as
"validates natively" because that native check is unchanged and still the
final word — the gateway only ever narrows what it allows.

The canonical issuer is the **public** URL `https://<ingress.host>/auth/realms/freshehr`
(`KC_HOSTNAME`): every token carries it, and EHRbase/oauth2-proxy fetch OIDC
discovery through the LB (they crash-loop harmlessly until Keycloak + DNS are
reachable). The HAPI interceptor fetches its `hapi-svc` tokens from the
in-cluster `keycloak` Service — Keycloak answers under any Host header but
always stamps the canonical `iss`.

Edge auth applies to **ingress traffic only** — kubelet probes hit the pod IP,
so they need no credentials. The in-network HAPI→openFHIR call goes through the
`openfhir` Service but IS authenticated (the engine validates natively): the
interceptor fetches a `hapi-svc` client-credentials token with
`scope=openfhir.map` (`openfhir.oauth2.*` in `config/application.yml.tpl`,
shipped as the `hapi-config` Secret).

## Prerequisites on the cluster

The chart deploys the **app**, not the cluster add-ons. These must already be
installed (Terraform's `k8s-apps` module does this):

- An **ingress controller** (`ingress-nginx`) matching `ingress.className`.
- **cert-manager** (when `ingress.tls.enabled=true`) — provides the ClusterIssuer CRD.
- A **CSI driver + StorageClass** matching `storage.className` (hcloud-csi on Hetzner).

## Secrets (required, created out-of-band)

With `secrets.create=true` the chart **renders** these Secrets from
`.Values.secrets.values` — which is how the Terraform path works: it generates every
password and passes them in, so nothing is hand-maintained (see the repo README →
Credentials).

For a **standalone** install (`secrets.create=false`, the default) the chart only
**references** Secrets by name. Create them yourself from
[`secrets.example.yaml`](secrets.example.yaml):

```bash
cp charts/health-stack/secrets.example.yaml charts/health-stack/secrets.yaml
# edit real values, then:
kubectl apply -n health-stack -f charts/health-stack/secrets.yaml
```

Required Secrets: `postgres-secret`, `ehrbase-secret`, `hapi-secret`,
`openfhir-secret`, `keycloak-secret`, `oauth2-proxy-secret`, and the
vendor-issued **`openfhir-license`** (the engine will not start without it).
The OIDC client secrets additionally have to be passed as chart values
(`secrets.values.keycloak.*`) so they can be substituted into the realm import
and `cdrs.yml` — see the notes in `secrets.example.yaml`:

```bash
kubectl create secret generic openfhir-license -n health-stack \
  --from-file=openfhir-license.json=./docker/openfhir/license/openfhir-license.json
```

For **dev only**, `secrets.create=true` renders placeholder credentials (the
`values-dev.yaml` file enables this). **Never** use that in a real environment.

## openFHIR engine

The engine **always runs in-cluster** — the stack is self-contained and has no
hosted-sandbox mode. It requires the vendor `openfhir-license` Secret (see above);
the Deployment will not start without it.

Uses an **`openfhir-enterprise`** image: the Postgres repository implementation ships
only there, and the community `openfhir` image is Mongo-only.

## Key values

| Key | Default | Purpose |
|-----|---------|---------|
| `storage.className` | `""` | Postgres PVC storage class |
| `ingress.host` | `health.local` | Ingress hostname |
| `ingress.className` | `nginx` | Ingress class |
| `ingress.tls.enabled` | `false` | cert-manager TLS |
| `ingress.tls.clusterIssuer` | `letsencrypt-prod` | Issuer name referenced by the Ingress |
| `ingress.auth.enabled` | `false` | Edge OAuth (`auth-url` → oauth2-proxy) on `/fhir` + `/terminology` (**on** in `values-hetzner.yaml`; `/ehrbase` and `/openfhir` validate natively) |
| `ingress.auth.signin` | `true` | Also emit `auth-signin` (browser redirect into the oauth2-proxy login flow) |
| `keycloak.enabled` / `oauth2Proxy.enabled` | `true` | The OIDC IdP + edge validator workloads |
| `secrets.values.keycloak.*` | dev values | Admin/DB creds + OIDC client secrets. **Blanked in `values-hetzner.yaml`** so a bare prod render fails (`required`); Terraform supplies generated values |
| `clusterIssuer.create` | `false` | Also render a Let's Encrypt ClusterIssuer |
| `images.hapi.*` / `images.ipsMappings.*` / `images.hades.*` | `:latest` | Custom image repo/tag (pin per env) |
| `hapi.replicas` / `hapi.resources` | `1` / `{}` | HAPI sizing |
| `hades.enabled` | `true` | The hades terminology server workload (PVC + Deployment + Service + Ingress) |
| `hades.storage` | `5Gi` | PVC size for hades' terminology `.db` files (raise **before** importing SNOMED) |
| `hades.env.JAVA_OPTS` | `-Xmx1g` | hades heap (`-Xmx2g` in `values-hetzner.yaml` for SNOMED-loaded sizing) |
| `hades.startupFailureThreshold` | `60` | First-boot budget: 10s × this while hades bootstraps its FHIR packages |
| `postgres.storage` | `5Gi` | PVC size for the shared Postgres |
| `secrets.create` | `false` | Render placeholder Secrets (dev only) |

See [`values.yaml`](values.yaml) for the full, commented contract.

## Config-change rollouts

Config files live in [`config/`](config/) (kept in sync with `docker/`) and are
mounted as ConfigMaps — or Secrets when they carry credentials (`application.yml`,
`cdrs.yml`, `init-db.sql`, the realm import). Every pod carries a `checksum/config` annotation over the
rendered config, so changing a config file rolls the affected pods automatically —
the same behavior Kustomize's ConfigMap name-hashing gave, without the name churn.

## Runbook: updating the realm on a LIVE cluster (openFHIR native OAuth)

`--import-realm` only imports realms that don't exist yet, so realm-JSON
changes (the openFHIR client scopes, `tenant`/realm-roles mappers, optional
scope attachments) do **not** reach an already-installed cluster via
`helm upgrade` alone. Two options, run inside the keycloak pod
(`kubectl exec -n health-stack deploy/keycloak -- …`):

**Option A — delete + reimport (simplest; drops sessions only).** Client
secrets are identical afterwards, since they're the same generated values the
chart substitutes into the import:

```bash
kubectl exec -n health-stack deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  config credentials --server http://localhost:8080/auth --realm master \
  --user "$KC_ADMIN" --password "$KC_ADMIN_PASSWORD"
kubectl exec -n health-stack deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  delete realms/freshehr
kubectl rollout restart deployment/keycloak -n health-stack   # reimports on boot
```

**Option B — additive kcadm one-shot** (no session loss): create the 14 client
scopes (`kcadm.sh create client-scopes -r freshehr …`), attach them as optional
scopes to `api-client`/`hapi-svc`, and add the `openfhir-tenant` +
`realm-roles` protocol mappers to both clients — mirroring
[`config/realm-freshehr.json.tpl`](config/realm-freshehr.json.tpl) exactly.

**After either option**, re-home the openFHIR mapping data: rows bootstrapped
while the engine was unprotected (or by the engine's startup bootstrap, which
runs outside any request context) live under a different tenant than
`freshehr` and are invisible to API callers. Run one authenticated bootstrap —
`POST /$bootstrap` plus the `*_conceptmap.json` POSTs, i.e. the equivalent of
`make bootstrap` against `https://<host>` — with a freshehr-realm token. Old
rows are orphaned, not migrated.

## Runbook: importing SNOMED CT into hades (one-off Job)

Out of the box hades serves the FHIR core packages only (bootstrapped on first
boot, no license needed). SNOMED CT is an optional operator import — free
licenses via [MLDS](https://mlds.ihtsdotools.org/) (member territories) or
[NHS TRUD](https://isd.digital.nhs.uk/) (UK). Run the import as a **Job**, not
`kubectl exec` into the serving pod: an import runs 30–60 min and needs its
own ~4Gi heap, which would blow the serving pod's 3Gi limit.

1. **Expand the PVC first** if needed (hcloud CSI supports online expansion;
   snomed.db Intl edition is ≈ 3–4 GiB), then release it — the PVC is RWO and
   the Job needs it:

   ```bash
   kubectl -n health-stack patch pvc hades-data \
     -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
   kubectl -n health-stack scale deploy/hades --replicas=0
   ```

2. **Get the release onto the volume** — either let hades auto-download it
   (MLDS: `install /data/snomed.db --dist ihtsdo.mlds/<member> --username ...
   --password file`, TRUD: `--dist uk.nhs/sct-monolith --api-key file`, creds
   from an out-of-band Secret mounted into the Job), or `kubectl cp` a local
   RF2 zip into `/data/import/` via a temporary pod mounting the PVC and run
   `import /data/snomed.db /data/import/snomed.zip`.

3. **Job skeleton** — same image, entrypoint overridden with the one-shot
   import command:

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: hades-snomed-import
     namespace: health-stack
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: import
             image: ghcr.io/freshehrteam/hades:<tag>   # match images.hades
             command: ["java", "-Xmx4g", "-jar", "/app/hades.jar",
                       "import", "/data/snomed.db", "/data/import/snomed.zip"]
             resources:
               requests: {memory: 4Gi}
               limits:   {memory: 5Gi}
             volumeMounts:
               - {name: data, mountPath: /data}
         volumes:
           - name: data
             persistentVolumeClaim: {claimName: hades-data}
   ```

4. **Wait, then scale back up** — the entrypoint's `serve /data/*.db` picks up
   the new file automatically:

   ```bash
   kubectl -n health-stack wait --for=condition=complete job/hades-snomed-import --timeout=2h
   kubectl -n health-stack scale deploy/hades --replicas=1
   ```

   Consider raising `hades.env.JAVA_OPTS` to `-Xmx2g` (already the
   `values-hetzner.yaml` default) for SNOMED-loaded serving.

LOINC works the same way with a manually-downloaded `Loinc_X.zip` and
`import /data/loinc.db ...`.

⚠️ The terminology data lives only on the `hades-data` PVC: deleting it means
re-importing SNOMED/LOINC (the FHIR core packages re-bootstrap themselves).

## Caveat: storage class is install-time

`volumeClaimTemplates` is immutable on an existing StatefulSet. `storage.className`
and `postgres.<db>.storage` therefore only take effect on **first install** — you
cannot change them via `helm upgrade` on a running cluster (delete + recreate the
StatefulSet, or migrate the data, to change them).
