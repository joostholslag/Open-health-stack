# health-stack Helm chart

The **freshehr-open-health-stack** application layer as a Helm chart: HAPI FHIR
(with the openFHIR interceptor), EHRbase, the openFHIR engine, and their Postgres
backends.

Runs on any Kubernetes cluster. Two values files ship with it — `values-hetzner.yaml`
(prod) and `values-dev.yaml` (kind/minikube). The templates never branch on the cloud
provider, so targeting another one is a new values file setting mostly the **storage
class**, plus the **ingress host** and a few **image tag / sizing** knobs.

## Install

Published as an OCI artifact on GHCR (see `.github/workflows/helm-publish.yml`):

```bash
# From the OCI registry (consumers):
helm install health-stack \
  oci://ghcr.io/<org>/charts/health-stack --version <x.y.z> \
  -n health-stack --create-namespace \
  -f values-hetzner.yaml \
  --set ingress.host=health.yourdomain.com

# Or from a local checkout (developers):
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
`openfhir-secret`, and the vendor-issued **`openfhir-license`** (the engine will
not start without it):

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
| `clusterIssuer.create` | `false` | Also render a Let's Encrypt ClusterIssuer |
| `images.hapi.*` / `images.ipsMappings.*` | `:latest` | Custom image repo/tag (pin per env) |
| `hapi.replicas` / `hapi.resources` | `1` / `{}` | HAPI sizing |
| `postgres.storage` | `5Gi` | PVC size for the shared Postgres |
| `secrets.create` | `false` | Render placeholder Secrets (dev only) |

See [`values.yaml`](values.yaml) for the full, commented contract.

## Config-change rollouts

Config files live in [`config/`](config/) (kept in sync with `docker/`) and are
mounted as ConfigMaps. Every pod carries a `checksum/config` annotation over the
rendered config, so changing a config file rolls the affected pods automatically —
the same behavior Kustomize's ConfigMap name-hashing gave, without the name churn.

## Caveat: storage class is install-time

`volumeClaimTemplates` is immutable on an existing StatefulSet. `storage.className`
and `postgres.<db>.storage` therefore only take effect on **first install** — you
cannot change them via `helm upgrade` on a running cluster (delete + recreate the
StatefulSet, or migrate the data, to change them).
