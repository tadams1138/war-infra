# Provider requirements shared by every root module.
# Symlinked or copied into each env; kept in one place so versions cannot drift.
#
# Provider versions are pinned to majors deliberately. The Cloudflare provider
# renamed a large number of resources at v5, so an unpinned upgrade would break
# every resource in modules/edge and modules/scheduler.

terraform {
  required_version = "~> 1.9"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
