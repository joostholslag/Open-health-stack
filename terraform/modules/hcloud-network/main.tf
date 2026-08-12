terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

variable "name" { type = string }
variable "network_zone" { type = string }
variable "network_cidr" { type = string }
variable "subnet_cidr" { type = string }

# Private network carrying node↔node (flannel) and node↔DB traffic.
resource "hcloud_network" "this" {
  name     = "${var.name}-net"
  ip_range = var.network_cidr
  labels = {
    cluster = var.name
  }
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

output "network_id" {
  value = hcloud_network.this.id
}

output "subnet_id" {
  value = hcloud_network_subnet.nodes.id
}
