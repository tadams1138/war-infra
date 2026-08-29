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
  required_version = "~> 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.40" }
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
  # Everything not matched by a Worker route proxies to App Platform, which
  # performs the path→component routing in §6.
  ui_worker_name    = "war-ui-router-${var.env}"
  media_worker_name = "war-media-router-${var.env}"
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

# ── Media router Worker ───────────────────────────────────────────────────────
# /media/* is served from the media bucket's CDN rather than App Platform.
# A Worker rather than an Origin Rule: redirecting to a different origin's
# hostname needs that rule type's Host Header override, which requires a
# paid Cloudflare plan. Fetching the CDN's own hostname directly (what
# edge/media-router.js does) needs no such override at all.

resource "cloudflare_workers_script" "media_router" {
  account_id         = var.account_id
  name               = local.media_worker_name
  content            = file("${path.module}/../../../edge/media-router.js")
  module             = true
  compatibility_date = "2025-04-02" # earliest date the Worker's own cf.cacheEverything/cacheTtl are honoured over Cache Rules — required for the aggressive media caching this Worker exists to provide

  plain_text_binding {
    name = "MEDIA_CDN_ORIGIN"
    text = "https://${var.media_cdn_host}"
  }
}

resource "cloudflare_workers_route" "media_router" {
  zone_id     = var.zone_id
  pattern     = "${var.domain}/media/*"
  script_name = cloudflare_workers_script.media_router.name
}

# ── Custom UI router Worker ───────────────────────────────────────────────────
# Handles /ui/{slug}/* for every slug from one shared bucket, and rewrites
# storage 404s to that slug's index.html with HTTP 200 (spec §6.1). Object
# storage cannot do the latter, which is the whole reason this Worker exists.

resource "cloudflare_workers_script" "ui_router" {
  account_id         = var.account_id
  name               = local.ui_worker_name
  content            = file("${path.module}/../../../edge/ui-router.js")
  module             = true
  compatibility_date = "2025-04-02" # pinned for predictable behaviour, matching media_router; this script sets no cf overrides today

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
#
# Free plan permits exactly one rule in the http_ratelimit phase per zone
# (apply fails outright past that — "exceeded the maximum number of rules").
# This module originally defined two: vote-submission and auth-endpoint
# throttles. Auth wins the single slot — credential-stuffing/brute-force
# volumetric protection has no other backstop, whereas vote submission is
# already bounded by the API's own per-voter, per-matchup limits (one vote
# per side, enforced server-side). Revisit if the Cloudflare plan changes.
resource "cloudflare_ruleset" "ratelimit" {
  zone_id = var.zone_id
  name    = "war-${var.env}-ratelimit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules {
    description = "Throttle auth endpoints per address"
    expression  = "(starts_with(http.request.uri.path, \"/api/v1/auth/\"))"
    action      = "block"
    enabled     = true

    ratelimit {
      characteristics = ["ip.src", "cf.colo.id"]
      # Free plan only permits a 10s period ("not entitled to use the period
      # 60, can only use a period among [10]"). Scaled to preserve the same
      # average rate as the original 60 requests/60s.
      period              = 10
      requests_per_period = 10
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
  #
  # No rule here for /media/* — it used to set cache = true / respect_origin,
  # but that's inert now: media_router (above) fetches with its own cf
  # overrides, and Cloudflare's documented precedence is Worker script
  # settings over Cache Rules. A rule here would silently do nothing for
  # every /media/* request and mislead whoever reads it next into thinking
  # it's what makes media caching work.
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

output "worker_name" {
  value = cloudflare_workers_script.ui_router.name
}

output "media_worker_name" {
  value = cloudflare_workers_script.media_router.name
}
