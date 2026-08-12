provider "hcloud" {
  token = var.hcloud_token
}

# ── Kubernetes / Helm providers ──────────────────────────────────────────────
# Read the kubeconfig the hcloud-cluster module fetches from the k3s control-plane.
# Guard with a fallback so a clean workspace (kubeconfig not yet written) still plans.
locals {
  kubeconfig_exists = fileexists(var.kubeconfig_path)
}

provider "kubernetes" {
  config_path = local.kubeconfig_exists ? var.kubeconfig_path : null
}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_exists ? var.kubeconfig_path : null
  }
}
