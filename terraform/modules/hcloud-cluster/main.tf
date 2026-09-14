terraform {
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.48" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

variable "name" { type = string }
variable "location" { type = string }
variable "image" { type = string }
variable "control_plane_type" { type = string }
variable "agent_type" { type = string }
variable "agent_count" { type = number }
variable "ssh_public_key_path" { type = string }
variable "admin_ssh_cidrs" { type = list(string) }
variable "k3s_version" { type = string }
variable "network_id" { type = string }
variable "subnet_cidr" { type = string }
variable "network_cidr" { type = string }
variable "kubeconfig_path" { type = string }

variable "ssh_private_key_path" {
  description = "Private key matching ssh_public_key_path, used to fetch the kubeconfig. Defaults to the public key path minus .pub."
  type        = string
  default     = ""
}

# Deterministic k3s cluster token (kept in state; state is gitignored).
resource "tls_private_key" "k3s_token" {
  algorithm = "ED25519"
}

locals {
  # 64 hex chars derived from the generated key — a stable shared secret.
  k3s_token = substr(sha256(tls_private_key.k3s_token.private_key_pem), 0, 48)

  # Static private IPs within the subnet.
  control_plane_ip = cidrhost(var.subnet_cidr, 10)
  agent_ips        = [for i in range(var.agent_count) : cidrhost(var.subnet_cidr, 20 + i)]

  # k3s uses the private NIC for flannel. On Hetzner the first attached private
  # network shows up as enp7s0 on Ubuntu 24.04 cloud images.
  flannel_iface = "enp7s0"

  # Hetzner's private-network gateway is always the first host of the network range.
  private_gateway = cidrhost(var.network_cidr, 1)

  # Private key used to SSH in and pull the kubeconfig. Falls back to the public
  # key path with the trailing ".pub" stripped.
  ssh_private_key_path = var.ssh_private_key_path != "" ? var.ssh_private_key_path : replace(var.ssh_public_key_path, ".pub", "")
}

# ── SSH key ──────────────────────────────────────────────────────────────────
resource "hcloud_ssh_key" "this" {
  name       = "${var.name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ── Firewall ─────────────────────────────────────────────────────────────────
resource "hcloud_firewall" "this" {
  name = "${var.name}-fw"

  # SSH from admin CIDRs only.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.admin_ssh_cidrs
  }

  # HTTP/HTTPS from anywhere (LB health checks + public traffic reach NodePorts).
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # NodePort range (ingress-nginx 30080/30443 + services) — LB + world.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "30000-32767"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Kubernetes API: the private network (agents joining) PLUS the admin CIDRs.
  # The kubeconfig this module writes points at the control-plane's PUBLIC IP, and
  # Terraform's kubernetes/helm providers connect from your machine in phase 2 — so
  # private-only here makes both `kubectl` and phase 2 time out.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = concat([var.network_cidr], var.admin_ssh_cidrs)
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "8472" # flannel VXLAN
    source_ips = [var.network_cidr]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "10250" # kubelet
    source_ips = [var.network_cidr]
  }
}

# ── Control-plane server ─────────────────────────────────────────────────────
resource "hcloud_server" "control_plane" {
  name         = "${var.name}-cp"
  server_type  = var.control_plane_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.this.id]
  firewall_ids = [hcloud_firewall.this.id]

  # The control-plane's public IP isn't known until the server exists, and it's
  # needed as a k3s TLS SAN. cloud-init fetches it at boot from the Hetzner
  # metadata service (169.254.169.254), so no self-reference is required here.
  user_data = templatefile("${path.module}/../../cloud-init/control-plane.yaml.tftpl", {
    k3s_version     = var.k3s_version
    k3s_token       = local.k3s_token
    node_ip         = local.control_plane_ip
    flannel_iface   = local.flannel_iface
    network_cidr    = var.network_cidr
    private_gateway = local.private_gateway
  })

  network {
    network_id = var.network_id
    ip         = local.control_plane_ip
  }

  labels = {
    cluster = var.name
    role    = "control-plane"
  }

  lifecycle {
    ignore_changes = [user_data] # avoid recreate churn on template tweaks
  }
}

# ── Agent servers ────────────────────────────────────────────────────────────
resource "hcloud_server" "agent" {
  count        = var.agent_count
  name         = "${var.name}-agent-${count.index}"
  server_type  = var.agent_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.this.id]
  firewall_ids = [hcloud_firewall.this.id]

  user_data = templatefile("${path.module}/../../cloud-init/agent.yaml.tftpl", {
    k3s_version     = var.k3s_version
    k3s_token       = local.k3s_token
    server_url      = "https://${local.control_plane_ip}:6443"
    node_ip         = local.agent_ips[count.index]
    flannel_iface   = local.flannel_iface
    network_cidr    = var.network_cidr
    private_gateway = local.private_gateway
  })

  network {
    network_id = var.network_id
    ip         = local.agent_ips[count.index]
  }

  labels = {
    cluster = var.name
    role    = "agent"
  }

  depends_on = [hcloud_server.control_plane]

  lifecycle {
    ignore_changes = [user_data]
  }
}

# ── Fetch kubeconfig from the control-plane ──────────────────────────────────
# Waits for k3s to be ready, pulls /etc/rancher/k3s/k3s.yaml, and rewrites the
# server URL from 127.0.0.1 to the node's public IP so it's usable off-cluster.
resource "null_resource" "kubeconfig" {
  triggers = {
    control_plane_id = hcloud_server.control_plane.id
  }

  # SSH in and wait until k3s has finished bootstrapping.
  #
  # Auth goes through ssh-agent rather than reading the key file directly:
  # Terraform's ssh provisioner cannot decrypt a passphrase-protected key
  # ("Failed to parse ssh private key: ssh: this private key is passphrase
  # protected"), and passphrase-protected keys are the sane default. Ensure the
  # key matching ssh_public_key_path is loaded:  ssh-add ~/.ssh/id_ed25519
  connection {
    type    = "ssh"
    host    = hcloud_server.control_plane.ipv4_address
    user    = "root"
    agent   = true
    timeout = "5m"
  }

  # Bounded wait: an unbounded `while [ ! -f ... ]` turns any failed bootstrap into
  # a silent hang that only ends when the operator gives up. Cap it at 5 minutes
  # (a healthy install lands in ~60-90s) and dump the k3s journal on timeout so the
  # actual cause shows up in the Terraform output.
  provisioner "remote-exec" {
    inline = [
      <<-EOT
        for i in $(seq 1 60); do
          if [ -f /tmp/k3s-ready ]; then echo "k3s ready"; exit 0; fi
          echo "waiting for k3s"
          sleep 5
        done
        echo "ERROR: k3s did not become ready within 5m" >&2
        echo "--- cloud-init status ---" >&2
        cloud-init status --long >&2 2>&1 || true
        echo "--- k3s journal (last 50) ---" >&2
        journalctl -u k3s --no-pager -n 50 >&2 2>&1 || true
        exit 1
      EOT
    ]
  }

  # Pull the kubeconfig and rewrite its server URL to the public IP.
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@${hcloud_server.control_plane.ipv4_address}:/etc/rancher/k3s/k3s.yaml ${var.kubeconfig_path}
      # -i.bak (not bare -i): BSD sed (macOS) requires an explicit backup-suffix
      # argument after -i, or it swallows the script as that argument and treats
      # the filename as the script itself. -i.bak works identically on GNU sed too.
      sed -i.bak 's#https://127.0.0.1:6443#https://${hcloud_server.control_plane.ipv4_address}:6443#g' ${var.kubeconfig_path}
      rm -f ${var.kubeconfig_path}.bak
      chmod 600 ${var.kubeconfig_path}
    EOT
  }

  depends_on = [hcloud_server.control_plane]
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "control_plane_ipv4" { value = hcloud_server.control_plane.ipv4_address }
output "agent_ipv4s" { value = hcloud_server.agent[*].ipv4_address }
output "control_plane_private_ip" { value = local.control_plane_ip }
output "node_label_selector" { value = "cluster=${var.name}" }
output "k3s_token" {
  value     = local.k3s_token
  sensitive = true
}
