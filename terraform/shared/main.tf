# Account- and zone-scoped resources that cannot be created per environment.
#
# The container registry is one-per-DigitalOcean-account (it holds many
# repositories), and Cloudflare zone settings apply to the whole zone. Creating
# either from both envs/staging and envs/production would conflict, so they live
# here and are applied once.
#
# Apply order: shared → staging → production.

terraform {
  required_version = "~> 1.9"

  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.43" }
    cloudflare   = { source = "cloudflare/cloudflare", version = "~> 4.40" }
  }

  backend "s3" {
    endpoints                   = { s3 = "https://nyc3.digitaloceanspaces.com" }
    bucket                      = "war-tfstate"
    key                         = "shared/terraform.tfstate"
    region                      = "us-east-1" # ignored by Spaces; required by the backend
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = false
  }
}

variable "do_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type      = string
  sensitive = true
}

variable "registry_name" {
  type    = string
  default = "war"
}

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── Container registry ────────────────────────────────────────────────────────
# One registry, one repository per image. Both environments pull the same image
# by tag — production deploys the exact digest staging validated.

resource "digitalocean_container_registry" "war" {
  name                   = var.registry_name
  subscription_tier_slug = "basic"
  region                 = "nyc3"
}

# ── Zone-wide Cloudflare settings ─────────────────────────────────────────────

resource "cloudflare_zone_settings_override" "war" {
  zone_id = var.cloudflare_zone_id

  settings {
    # Full (strict) — App Platform and Spaces both present valid certificates,
    # so there is no reason to accept an unvalidated origin.
    ssl                      = "strict"
    always_use_https         = "on"
    automatic_https_rewrites = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"

    # Assets are content-hashed and immutable; let the edge honour that.
    browser_cache_ttl = 0 # respect origin Cache-Control

    security_header {
      enabled            = true
      include_subdomains = true
      max_age            = 31536000
      preload            = false
    }
  }
}

output "registry_name" {
  value = digitalocean_container_registry.war.name
}

output "registry_endpoint" {
  value = digitalocean_container_registry.war.endpoint
}
