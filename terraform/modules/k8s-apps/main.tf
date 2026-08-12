terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.14" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
  }
}

# ── Inputs ────────────────────────────────────────────────────────────────────
variable "kubeconfig_path" { type = string }
variable "domain" { type = string }
variable "letsencrypt_email" { type = string }

variable "http_node_port" {
  type    = number
  default = 30080
}
variable "https_node_port" {
  type    = number
  default = 30443
}

# The Hetzner CCM/CSI need the API token + network as a Secret.
variable "hcloud_token" {
  type      = string
  sensitive = true
  default   = ""
}
variable "network_id" {
  type    = string
  default = ""
}

# Path to the health-stack Helm chart (this repo's charts/health-stack).
variable "chart_path" { type = string }

# Values file passed to the chart (charts/health-stack/values-hetzner.yaml).
variable "chart_values_file" { type = string }

# ── Generated credentials (from the root module's random_password resources) ───
variable "pg_superuser_password" {
  type      = string
  sensitive = true
}
variable "ehrbase_db_password" {
  type      = string
  sensitive = true
}
variable "ehrbase_db_admin_password" {
  type      = string
  sensitive = true
}
variable "hapi_db_password" {
  type      = string
  sensitive = true
}
variable "openfhir_db_password" {
  type      = string
  sensitive = true
}
variable "ehrbase_api_password" {
  type      = string
  sensitive = true
}

# Basic-auth username EHRbase enforces (password is generated).
variable "ehrbase_api_user" {
  type    = string
  default = "ehrbase-user"
}

# ingress-nginx Service type. NodePort on Hetzner — the hcloud LB fronts the pinned
# NodePorts below.
variable "ingress_service_type" {
  type    = string
  default = "NodePort"
}

# ============================================================================
# Hetzner cloud provider integrations (CCM / CSI)
# ============================================================================

# ── Hetzner: CCM + CSI need the API token as a Secret ─────────────────────────
resource "kubernetes_namespace" "system" {
  metadata { name = "hcloud-system" }
}

resource "kubernetes_secret" "hcloud" {
  metadata {
    name      = "hcloud"
    namespace = kubernetes_namespace.system.metadata[0].name
  }
  data = {
    token   = var.hcloud_token
    network = var.network_id
  }
}

# Hetzner Cloud Controller Manager (nodes get proper providerIDs).
resource "helm_release" "hcloud_ccm" {
  name       = "hccm"
  namespace  = kubernetes_namespace.system.metadata[0].name
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"

  set {
    name  = "networking.enabled"
    value = "true"
  }
  set {
    name  = "env.HCLOUD_TOKEN.valueFrom.secretKeyRef.name"
    value = kubernetes_secret.hcloud.metadata[0].name
  }

  depends_on = [kubernetes_secret.hcloud]
}

# Hetzner CSI (dynamic PVC provisioning → hcloud-volumes storage class).
resource "helm_release" "hcloud_csi" {
  name       = "hcloud-csi"
  namespace  = kubernetes_namespace.system.metadata[0].name
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-csi"

  depends_on = [helm_release.hcloud_ccm]
}

# ============================================================================
# Cluster add-ons: ingress-nginx + cert-manager
# ============================================================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"

  set {
    name  = "controller.service.type"
    value = var.ingress_service_type
  }

  # NodePort pinning only matters on hetzner (the hcloud LB targets these ports).
  dynamic "set" {
    for_each = var.ingress_service_type == "NodePort" ? [1] : []
    content {
      name  = "controller.service.nodePorts.http"
      value = tostring(var.http_node_port)
    }
  }
  dynamic "set" {
    for_each = var.ingress_service_type == "NodePort" ? [1] : []
    content {
      name  = "controller.service.nodePorts.https"
      value = tostring(var.https_node_port)
    }
  }

  # Preserve client source IPs through the TCP LB.
  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
}

# cert-manager (Let's Encrypt certs for the ingress) — same on every cloud.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# ============================================================================
# The application stack — health-stack Helm chart
# ============================================================================
# Installs the local chart with the Hetzner values file, overriding the ingress
# host + cert-manager issuer email from Terraform vars so DNS/TLS line up with
# what the LB/network modules provisioned. cert-manager's ClusterIssuer is created
# by the chart here (clusterIssuer.create=true) so TLS works end-to-end.
resource "helm_release" "health_stack" {
  name             = "health-stack"
  namespace        = "health-stack"
  create_namespace = true
  chart            = var.chart_path

  # Environment defaults (storage class, sizing, image tags).
  values = [file(var.chart_values_file)]

  # Have the chart render the Secrets from the generated credentials below, rather
  # than requiring a hand-maintained secrets.yaml applied out-of-band.
  set {
    name  = "secrets.create"
    value = "true"
  }

  # Generated credentials. set_sensitive keeps them out of Terraform's plan/apply
  # output. NOTE: the DB passwords are baked into the Postgres roles by init-db.sql,
  # which only runs on FIRST boot of an empty PVC — rotating them later needs the
  # roles altered in-place (ALTER USER ... PASSWORD) or the PVC recreated.
  set_sensitive {
    name  = "secrets.values.postgres.POSTGRES_PASSWORD"
    value = var.pg_superuser_password
  }
  set_sensitive {
    name  = "secrets.values.postgres.EHRBASE_PASSWORD"
    value = var.ehrbase_db_password
  }
  set_sensitive {
    name  = "secrets.values.postgres.EHRBASE_PASSWORD_ADMIN"
    value = var.ehrbase_db_admin_password
  }
  # EHRbase's own datasource creds must match the roles above.
  set_sensitive {
    name  = "secrets.values.ehrbase.DB_PASS"
    value = var.ehrbase_db_password
  }
  set_sensitive {
    name  = "secrets.values.ehrbase.DB_PASS_ADMIN"
    value = var.ehrbase_db_admin_password
  }
  # EHRbase REST basic-auth — also rendered into cdrs.yml for the interceptor.
  set {
    name  = "secrets.values.ehrbase.SECURITY_AUTHUSER"
    value = var.ehrbase_api_user
  }
  set_sensitive {
    name  = "secrets.values.ehrbase.SECURITY_AUTHPASSWORD"
    value = var.ehrbase_api_password
  }
  set {
    name  = "secrets.values.ehrbase.SERVER_NODENAME"
    value = var.domain
  }
  # HAPI + openFHIR datasource creds; init-db.sql creates these roles with the
  # same values (rendered from these Secret values).
  set_sensitive {
    name  = "secrets.values.hapi.HAPI_DB_PASS"
    value = var.hapi_db_password
  }
  set_sensitive {
    name  = "secrets.values.openfhir.OPENFHIR_DB_PASS"
    value = var.openfhir_db_password
  }

  # Terraform-owned overrides: real domain + issuer email.
  set {
    name  = "ingress.host"
    value = var.domain
  }
  set {
    name  = "clusterIssuer.create"
    value = "true"
  }
  set {
    name  = "clusterIssuer.email"
    value = var.letsencrypt_email
  }
  set {
    name  = "ingress.tls.clusterIssuer"
    value = "letsencrypt-prod"
  }

  # Apps depend on: the ingress controller + cert-manager (for the issuer CRD) and
  # the hcloud CSI driver (so PVCs bind).
  depends_on = [
    helm_release.ingress_nginx,
    helm_release.cert_manager,
    helm_release.hcloud_csi,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "ingress_namespace" { value = "ingress-nginx" }
output "app_namespace" { value = "health-stack" }
output "app_release" { value = helm_release.health_stack.name }
