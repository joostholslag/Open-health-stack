terraform {
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.48" }
  }
}

variable "name" { type = string }
variable "location" { type = string }
variable "network_id" { type = string }
variable "target_label_selector" { type = string }
variable "http_node_port" { type = number }
variable "https_node_port" { type = number }

variable "lb_type" {
  type    = string
  default = "lb11"
}

resource "hcloud_load_balancer" "this" {
  name               = "${var.name}-lb"
  load_balancer_type = var.lb_type
  location           = var.location
  labels = {
    cluster = var.name
  }
}

# Attach the LB to the private network so it can reach node targets internally.
resource "hcloud_load_balancer_network" "this" {
  load_balancer_id = hcloud_load_balancer.this.id
  network_id       = var.network_id
}

# Target all cluster nodes by label; use private-network targets.
resource "hcloud_load_balancer_target" "nodes" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.this.id
  label_selector   = var.target_label_selector
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.this]
}

# :80 → ingress-nginx HTTP NodePort
resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = var.http_node_port

  health_check {
    protocol = "tcp"
    port     = var.http_node_port
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# :443 → ingress-nginx HTTPS NodePort (TLS terminates at ingress-nginx/cert-manager)
resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = var.https_node_port

  health_check {
    protocol = "tcp"
    port     = var.https_node_port
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

output "ipv4" { value = hcloud_load_balancer.this.ipv4 }
output "id" { value = hcloud_load_balancer.this.id }
