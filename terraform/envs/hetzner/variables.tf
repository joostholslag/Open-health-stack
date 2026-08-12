# ── Provider / auth ──────────────────────────────────────────────────────────
variable "hcloud_token" {
  description = "Hetzner Cloud API token (project-scoped). Provide via TF_VAR_hcloud_token or a gitignored *.tfvars."
  type        = string
  sensitive   = true
}

# ── Cluster shape ────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name prefix for all hcloud resources."
  type        = string
  default     = "freshehr"
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ash, hil)."
  type        = string
  default     = "nbg1"
}

variable "control_plane_type" {
  description = "Server type for the k3s control-plane node."
  type        = string
  default     = "cx23"
}

variable "agent_type" {
  description = "Server type for k3s agent nodes."
  type        = string
  default     = "cx33"
}

variable "agent_count" {
  description = "Number of k3s agent nodes."
  type        = number
  default     = 2
}

variable "image" {
  description = "Base OS image for the nodes."
  type        = string
  default     = "ubuntu-24.04"
}

# ── SSH / access ─────────────────────────────────────────────────────────────
variable "ssh_public_key_path" {
  description = "Path to the SSH public key uploaded to Hetzner and installed on nodes."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_ssh_cidrs" {
  description = "CIDRs allowed to SSH (port 22) to the nodes. Lock this down."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

# ── Networking ───────────────────────────────────────────────────────────────
variable "network_zone" {
  description = "Hetzner network zone for the private network (eu-central, us-east, us-west, ap-southeast)."
  type        = string
  default     = "eu-central"
}

variable "network_cidr" {
  description = "CIDR for the private network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the node subnet within the private network."
  type        = string
  default     = "10.0.1.0/24"
}

# ── k3s ──────────────────────────────────────────────────────────────────────
variable "k3s_version" {
  description = "k3s channel or pinned version (e.g. 'stable', 'v1.30')."
  type        = string
  default     = "stable"
}

# ── Apps layer (k8s-apps module) ─────────────────────────────────────────────
variable "domain" {
  description = "DNS host for the ingress (must resolve to the load balancer IP). Empty = skip TLS host wiring."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Contact email for the cert-manager Let's Encrypt ClusterIssuer."
  type        = string
  default     = "admin@example.com"
}

variable "install_apps" {
  description = "Whether the k8s-apps module installs add-ons + the health-stack chart. Set false for a cluster-only (phase 1) apply."
  type        = bool
  default     = true
}

variable "kubeconfig_path" {
  description = "Local path where the fetched k3s kubeconfig is written."
  type        = string
  default     = "./kubeconfig"
}
