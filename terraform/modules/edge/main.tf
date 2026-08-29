# Cloudflare edge — see specs/war-infra-spec.md §5.1, §6, §7, §13.1, §13.2
#
# Rule ordering matters and is not alphabetical. Within a ruleset phase, rules
# evaluate top to bottom and the first match wins, so /ui/default must be
# excluded from the custom-UI route and /api/v1/internal must be blocked before
# anything else can route it.

# Required in every module that uses it, not just the root — Terraform does
# not infer a non-default-namespace provider's source for a child module from
# the root's required_providers alone.
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
  }
}

variable "env" {
  type = string
}

variable "zone_id" {
  type      = string
  sensitive = true
}

variable "account_id" {
  type      = string
  sensitive = true
}

variable "domain" {
  type = string
}

variable "app_default_host" {
  type        = string
  description = "*.ondigitalocean.app hostname; proxied to, never advertised"
}

variable "media_cdn_host" {
  type = string
}

variable "ui_custom_cdn_host" {
  type = string
}

locals {
  # Everything not matched by an origin rule proxies to App Platform, which
  # performs the path→component routing in §6.
  worker_name = "war-ui-router-${var.env}"
}

# ── DNS ───────────────────────────────────────────────────────────────────────

resource "cloudflare_record" "apex" {
  zone_id = var.zone_id
  name    = var.domain
  type    = "CNAME"
  content = var.app_default_host
  proxied = true
  ttl     = 1 # required when proxied
  comment = "War ${var.env} — proxied to App Platform"
}

# ── Origin routing ────────────────────────────────────────────────────────────
# /media/* is served from the media bucket's CDN rather than App Platform.
# The path prefix is stripped by the rewrite below so bucket keys stay clean.

resource "cloudflare_ruleset" "origin" {
  zone_id = var.zone_id
  name    = "war-${var.env}-origin"
  kind    = "zone"
  phase   = "http_request_origin"

  rules {
    description = "Serve /media/* from the media bucket CDN"
    expression  = "(http.host eq \"${var.domain}\" and starts_with(http.request.uri.path, \"/media/\"))"
    action      = "route"
    enabled     = true

    action_parameters {
      host_header = var.media_cdn_host
      origin {
        host = var.media_cdn_host
      }
    }
  }
}

resource "cloudflare_ruleset" "rewrite" {
  zone_id = var.zone_id
  name    = "war-${var.env}-rewrite"
  kind    = "zone"
  phase   = "http_request_transform"

  rules {
    description = "Strip the /media prefix before hitting the bucket"
    expression  = "(http.host eq \"${var.domain}\" and starts_with(http.request.uri.path, \"/media/\"))"
    action      = "rewrite"
    enabled     = true

    action_parameters {
      uri {
        path {
          expression = "regex_replace(http.request.uri.path, \"^/media/\", \"/\")"
        }
      }
    }
  }
}

# ── Custom UI router Worker ───────────────────────────────────────────────────
# Handles /ui/{slug}/* for every slug from one shared bucket, and rewrites
# storage 404s to that slug's index.html with HTTP 200 (spec §6.1). Object
# storage cannot do the latter, which is the whole reason this Worker exists.

resource "cloudflare_workers_script" "ui_router" {
  account_id = var.account_id
  name       = local.worker_name
  content    = file("${path.module}/../../../edge/ui-router.js")
  module     = true

  plain_text_binding {
    name = "STORAGE_CDN_ORIGIN"
    text = "https://${var.ui_custom_cdn_host}"
  }
}

# Bound only to /ui/*, so the bulk of platform traffic never invokes it and any
# per-invocation quota applies to custom-UI traffic alone (spec §6.1).
# /ui/default/* is served by App Platform and must not reach the Worker.
resource "cloudflare_workers_route" "ui_router" {
  zone_id     = var.zone_id
  pattern     = "${var.domain}/ui/*"
  script_name = cloudflare_workers_script.ui_router.name
}

# ── WAF ───────────────────────────────────────────────────────────────────────

resource "cloudflare_ruleset" "firewall" {
  zone_id = var.zone_id
  name    = "war-${var.env}-firewall"
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

# ── Rate limiting ─────────────────────────────────────────────────────────────
# Volumetric shedding only. Per-voter limits live in the API, which can decode
# the JWT the edge cannot (spec §9.4 of war-api-spec.md).

resource "cloudflare_ruleset" "ratelimit" {
  zone_id = var.zone_id
  name    = "war-${var.env}-ratelimit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules {
    description = "Throttle vote submission per address"
    expression  = "(http.request.method eq \"POST\" and http.request.uri.path contains \"/matchups/\" and http.request.uri.path contains \"/vote\")"
    action      = "block"
    enabled     = true

    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = 300
      mitigation_timeout  = 60
    }
  }

  rules {
    description = "Throttle auth endpoints per address"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/auth/\"))"
    action      = "block"
    enabled     = true

    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = 60
      mitigation_timeout  = 300
    }
  }
}

# ── Cache ─────────────────────────────────────────────────────────────────────

resource "cloudflare_ruleset" "cache" {
  zone_id = var.zone_id
  name    = "war-${var.env}-cache"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  # API responses are uncacheable by default. The rankings endpoint is the
  # deliberate exception and sets its own Cache-Control (spec §7.5 of the API
  # spec), which the edge honours because this rule does not override it.
  rules {
    description = "Bypass cache for the API, except where it opts in"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/\") and not http.request.uri.path contains \"/rankings\")"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = false
    }
  }

  rules {
    description = "Cache media aggressively; keys are content-addressed"
    expression  = "(starts_with(http.request.uri.path, \"/media/\"))"
    action      = "set_cache_settings"
    enabled     = true

    action_parameters {
      cache = true
      edge_ttl {
        mode    = "respect_origin"
        default = 31536000
      }
      browser_ttl {
        mode = "respect_origin"
      }
    }
  }
}

output "worker_name" {
  value = cloudflare_workers_script.ui_router.name
}
