terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Generates the service credentials (see random_password.* in main.tf).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Optional: uncomment to store state remotely (S3-compatible, e.g. Hetzner
  # Object Storage). Local state is the v1 default.
  # backend "s3" {
  #   bucket                      = "freshehr-tfstate"
  #   key                         = "health-stack/hetzner.tfstate"
  #   region                      = "eu-central"
  #   endpoints                   = { s3 = "https://<project>.your-objectstorage.com" }
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  # }
}
