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

# ── WAF, rate limiting, and cache ─────────────────────────────────────────────
# Zone-wide, applied once. Cloudflare permits exactly one custom ruleset per
# phase per zone — staging and production are both subdomains of this one
# zone (one CLOUDFLARE_ZONE_ID between them), so these used to live in
# modules/edge and be instantiated once per environment, which fails outright
# on the second environment's apply ("A similar configuration with rules
# already exists"). None of the rules below key off a specific env or domain
# — every match is path-only — so one zone-wide copy covers both
# environments exactly as intended; only the number of copies changed.
#
# Rule ordering matters and is not alphabetical: within a ruleset phase,
# rules evaluate top to bottom and the first match wins.

resource "cloudflare_ruleset" "firewall" {
  zone_id = var.cloudflare_zone_id
  name    = "war-firewall"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  # Internal task endpoints are reachable only by the scheduler, which calls the
  # App Platform origin directly rather than through this hostname (spec §12.3).
  rules {
    description = "Block internal task endpoints from the public internet"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/internal/\"))"
    action      = "block"
    enabled     = true
  }

  # Originals exist only for reprocessing and are never served (spec §11).
  rules {
    description = "Block direct access to unprocessed image originals"
    expression  = "(starts_with(http.request.uri.path, \"/media/originals/\"))"
    action      = "block"
    enabled     = true
  }
}

# Volumetric shedding only. Per-voter limits live in the API, which can decode
# the JWT the edge cannot (spec §9.4 of war-api-spec.md).
#
# Free plan permits exactly one rule in the http_ratelimit phase per zone
# (apply fails outright past that — "exceeded the maximum number of rules").
# This originally defined two: vote-submission and auth-endpoint throttles.
# Auth wins the single slot — credential-stuffing/brute-force volumetric
# protection has no other backstop, whereas vote submission is already
# bounded by the API's own per-voter, per-matchup limits (one vote per side,
# enforced server-side). Revisit if the Cloudflare plan changes.
resource "cloudflare_ruleset" "ratelimit" {
  zone_id = var.cloudflare_zone_id
  name    = "war-ratelimit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules {
    description = "Throttle auth endpoints per address"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/auth/\"))"
    action      = "block"
    enabled     = true

    ratelimit {
      characteristics = ["ip.src", "cf.colo.id"]
      # Free plan only permits a 10s period and a 10s mitigation timeout
      # ("not entitled to use the period 60, can only use a period among
      # [10]", then separately "not entitled to use a mitigation timeout
      # different from 10"). Rate scaled to preserve the original 60
      # requests/60s average; mitigation window is just whatever Free allows.
      period              = 10
      requests_per_period = 10
      mitigation_timeout  = 10
    }
  }
}

resource "cloudflare_ruleset" "cache" {
  zone_id = var.cloudflare_zone_id
  name    = "war-cache"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  # API responses are uncacheable by default. The rankings endpoint is the
  # deliberate exception and sets its own Cache-Control (spec §7.5 of the API
  # spec), which the edge honours because this rule does not override it.
  #
  # No rule here for /media/* — it used to set cache = true / respect_origin,
  # but that's inert now: each environment's media_router Worker (modules/edge)
  # fetches with its own cf overrides, and Cloudflare's documented precedence
  # is Worker script settings over Cache Rules. A rule here would silently do
  # nothing for every /media/* request and mislead whoever reads it next into
  # thinking it's what makes media caching work.
  #
  # No rule here for the default UI's HTML either, and it needs to stay that
  # way: Cache Level defaults to not caching HTML at all without an explicit
  # "Cache Everything" rule, which is what makes App Platform's fixed,
  # non-configurable s-maxage=86400 on that static site currently inert (see
  # scripts/smoke-test.sh's ui-default cache-control check). Adding a "cache
  # everything" rule here for performance later would make that s-maxage
  # start mattering — revisit the smoke test's tolerance at the same time.
  rules {
    description = "Bypass cache for the API, except where it opts in"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/\") and not http.request.uri.path contains \"/rankings\")"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = false
    }
  }
}

output "registry_name" {
  value = digitalocean_container_registry.war.name
}

output "registry_endpoint" {
  value = digitalocean_container_registry.war.endpoint
}
