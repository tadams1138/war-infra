# Cloudflare edge — per-environment DNS and Worker routing. See
# specs/war-infra-spec.md §5.1, §6, §7. The zone-wide WAF/rate-limit/cache
# rulesets (§13.1, §13.2) live in terraform/shared instead, applied once —
# see that module for why.
#
# /ui/default/* must reach App Platform, not the ui_router Worker below —
# that's what its route pattern excludes it for.

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

# WAF, rate limiting, and cache rules used to live here, one copy per
# environment. They moved to terraform/shared: staging and production are
# both subdomains of the same Cloudflare zone (one CLOUDFLARE_ZONE_ID, not
# one per env), and Cloudflare permits exactly one custom ruleset per phase
# per zone — production's first-ever apply failed outright trying to create
# a second copy of each ("A similar configuration with rules already
# exists... overwriting will have unintended consequences"). None of the
# three ever actually keyed off env or domain in their rule expressions
# (path-only matches throughout), so moving them to a single zone-wide
# instance changed nothing about what they do — only how many of them exist.
# See terraform/shared/main.tf.

output "worker_name" {
  value = cloudflare_workers_script.ui_router.name
}

output "media_worker_name" {
  value = cloudflare_workers_script.media_router.name
}
