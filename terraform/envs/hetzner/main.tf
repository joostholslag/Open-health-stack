# ============================================================================
# Root: Hetzner (k3s on hcloud) — Layer 3, per-cloud root.
# Wires the hcloud-* provisioning modules + the shared k8s-apps module (which
# installs add-ons and the health-stack Helm chart). Provider-agnostic parts live
# in k8s-apps and charts/health-stack; hcloud specifics are the three hcloud-* modules.
#
# TWO-PHASE APPLY (kubeconfig must exist before the k8s/helm providers connect):
#   terraform apply -var 'install_apps=false'   # phase 1: cluster only
#   terraform apply                              # phase 2: add-ons + app chart
# ============================================================================

module "network" {
  source = "../../modules/hcloud-network"

  name         = var.cluster_name
  network_zone = var.network_zone
  network_cidr = var.network_cidr
  subnet_cidr  = var.subnet_cidr
}

module "cluster" {
  source = "../../modules/hcloud-cluster"

  name                = var.cluster_name
  location            = var.location
  image               = var.image
  control_plane_type  = var.control_plane_type
  agent_type          = var.agent_type
  agent_count         = var.agent_count
  ssh_public_key_path = var.ssh_public_key_path
  admin_ssh_cidrs     = var.admin_ssh_cidrs
  k3s_version         = var.k3s_version

  network_id   = module.network.network_id
  subnet_cidr  = var.subnet_cidr
  network_cidr = var.network_cidr

  kubeconfig_path = var.kubeconfig_path
}

module "lb" {
  source = "../../modules/hcloud-lb"

  name                  = var.cluster_name
  location              = var.location
  network_id            = module.network.network_id
  target_label_selector = module.cluster.node_label_selector

  http_node_port  = 30080
  https_node_port = 30443
}

# ── Generated credentials ─────────────────────────────────────────────────────
# Every database/API password is generated here rather than shipped as a default,
# so no well-known credential is ever exposed on a public endpoint.
#
# `special = false` on purpose: these values are interpolated into JDBC URLs, YAML
# and SQL string literals, where punctuation causes quoting/escaping bugs. 32
# alphanumeric characters is ~190 bits — ample.
#
# ⚠ These land in terraform.tfstate in PLAINTEXT (a documented Terraform
# behaviour — `sensitive` only masks CLI output). The state file is gitignored and
# chmod 600, but treat it as a secret: anyone who can read it has every password.
# For production, use External Secrets / Vault so Terraform never sees the values.
# Retrieve them with:  terraform output -json credentials | jq
resource "random_password" "pg_superuser" {
  length  = 32
  special = false
}
resource "random_password" "ehrbase_db" {
  length  = 32
  special = false
}
resource "random_password" "ehrbase_db_admin" {
  length  = 32
  special = false
}
resource "random_password" "hapi_db" {
  length  = 32
  special = false
}
resource "random_password" "openfhir_db" {
  length  = 32
  special = false
}
# ── Keycloak / OAuth2 credentials ────────────────────────────────────────────
# EHRbase and the openFHIR engine validate Bearer tokens natively
# (SECURITY_AUTHTYPE=OAUTH / openfhir.protected) and the /fhir ingress route
# is gated by oauth2-proxy (auth-url), so the
# old ehrbase_api / api_basic_auth basic-auth passwords are gone. What's needed
# instead: the Keycloak admin + DB credentials, one client secret per OIDC
# client (substituted into the realm import AND handed to each consumer, so
# they always agree), and oauth2-proxy's cookie-encryption secret.
resource "random_password" "keycloak_admin" {
  length  = 32
  special = false
}
resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}
# client_credentials service account for external API callers (`terraform
# output -raw kc_api_client_secret` to retrieve).
resource "random_password" "kc_api_client" {
  length  = 32
  special = false
}
# client_credentials service account for the HAPI interceptor's HAPI→EHRbase hop.
resource "random_password" "kc_hapi_svc" {
  length  = 32
  special = false
}
resource "random_password" "oauth2_proxy_client" {
  length  = 32
  special = false
}
# MUST be exactly 16, 24 or 32 bytes — oauth2-proxy rejects other lengths.
resource "random_password" "oauth2_proxy_cookie" {
  length  = 32
  special = false
}

# Hetzner-specific cloud-provider integration (CCM + CSI). Same install_apps
# gating as module.apps below — both are meaningless before the cluster exists.
module "hcloud_cloud_integration" {
  source = "../../modules/hcloud-cloud-integration"
  count  = var.install_apps ? 1 : 0

  hcloud_token = var.hcloud_token
  network_id   = module.network.network_id

  depends_on = [module.cluster]
}

# Cluster add-ons (ingress-nginx + cert-manager) + the health-stack chart.
# Provider-agnostic — the Hetzner-specific cloud integration above is a
# separate module so this one doesn't need to change per cloud.
module "apps" {
  source = "../../modules/k8s-apps"
  count  = var.install_apps ? 1 : 0

  kubeconfig_path   = var.kubeconfig_path
  domain            = var.domain
  letsencrypt_email = var.letsencrypt_email

  pg_superuser_password     = random_password.pg_superuser.result
  ehrbase_db_password       = random_password.ehrbase_db.result
  ehrbase_db_admin_password = random_password.ehrbase_db_admin.result
  hapi_db_password          = random_password.hapi_db.result
  openfhir_db_password      = random_password.openfhir_db.result

  keycloak_admin_password    = random_password.keycloak_admin.result
  keycloak_db_password       = random_password.keycloak_db.result
  kc_api_client_secret       = random_password.kc_api_client.result
  kc_hapi_svc_secret         = random_password.kc_hapi_svc.result
  oauth2_proxy_client_secret = random_password.oauth2_proxy_client.result
  oauth2_proxy_cookie_secret = random_password.oauth2_proxy_cookie.result

  http_node_port       = 30080
  https_node_port      = 30443
  ingress_service_type = "NodePort"

  chart_path        = "${path.module}/../../../charts/health-stack"
  chart_values_file = "${path.module}/../../../charts/health-stack/values-hetzner.yaml"

  # module.cluster: needs the kubeconfig to exist. module.hcloud_cloud_integration:
  # needs the CSI driver up before the chart's PVCs try to bind.
  depends_on = [module.cluster, module.hcloud_cloud_integration]
}
