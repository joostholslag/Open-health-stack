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
# Basic-auth EHRbase enforces on its REST API (reachable at /ehrbase through the
# ingress) and that the HAPI interceptor uses via cdrs.yml.
resource "random_password" "ehrbase_api" {
  length  = 32
  special = false
}

# Cluster add-ons (hcloud CCM/CSI + ingress-nginx + cert-manager) + the health-stack chart.
module "apps" {
  source = "../../modules/k8s-apps"
  count  = var.install_apps ? 1 : 0

  kubeconfig_path   = var.kubeconfig_path
  hcloud_token      = var.hcloud_token
  network_id        = module.network.network_id
  domain            = var.domain
  letsencrypt_email = var.letsencrypt_email

  pg_superuser_password     = random_password.pg_superuser.result
  ehrbase_db_password       = random_password.ehrbase_db.result
  ehrbase_db_admin_password = random_password.ehrbase_db_admin.result
  hapi_db_password          = random_password.hapi_db.result
  openfhir_db_password      = random_password.openfhir_db.result
  ehrbase_api_password      = random_password.ehrbase_api.result

  http_node_port       = 30080
  https_node_port      = 30443
  ingress_service_type = "NodePort"

  chart_path        = "${path.module}/../../../charts/health-stack"
  chart_values_file = "${path.module}/../../../charts/health-stack/values-hetzner.yaml"

  depends_on = [module.cluster]
}
