# Object storage — see specs/war-infra-spec.md §5.4, §5.5
#
# Two buckets per environment:
#   war-media-{env}       contestant image variants (public) + originals (private)
#   war-ui-custom-{env}   every custom UI, keyed by slug prefix
#
# There is deliberately no bucket per custom UI. All slugs share one bucket
# behind one CDN origin, so registering a slug provisions nothing (spec §5.5).

# Required in every module that uses it, not just the root — Terraform does
# not infer a non-default-namespace provider's source for a child module from
# the root's required_providers alone.
terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean" }
  }
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "nyc3"
}

# ── Media ─────────────────────────────────────────────────────────────────────

resource "digitalocean_spaces_bucket" "media" {
  name   = "war-media-${var.env}"
  region = var.region
  acl    = "private" # objects are made public individually; see policy below
}

# Variants are public-read. Originals are NOT — they exist only so variant
# widths can change later without re-uploading (spec §11), and are never served.
resource "digitalocean_spaces_bucket_policy" "media" {
  region = digitalocean_spaces_bucket.media.region
  bucket = digitalocean_spaces_bucket.media.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadVariants"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = ["arn:aws:s3:::${digitalocean_spaces_bucket.media.name}/contestants/*"]
      }
    ]
  })
}

resource "digitalocean_cdn" "media" {
  origin = digitalocean_spaces_bucket.media.bucket_domain_name
  ttl    = 86400
}

# ── Custom UIs ────────────────────────────────────────────────────────────────

resource "digitalocean_spaces_bucket" "ui_custom" {
  name   = "war-ui-custom-${var.env}"
  region = var.region
  acl    = "private"
}

resource "digitalocean_spaces_bucket_policy" "ui_custom" {
  region = digitalocean_spaces_bucket.ui_custom.region
  bucket = digitalocean_spaces_bucket.ui_custom.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadBundles"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = ["arn:aws:s3:::${digitalocean_spaces_bucket.ui_custom.name}/*"]
      }
    ]
  })
}

resource "digitalocean_cdn" "ui_custom" {
  origin = digitalocean_spaces_bucket.ui_custom.bucket_domain_name
  ttl    = 3600
}

output "media_bucket" {
  value = digitalocean_spaces_bucket.media.name
}

output "media_cdn_host" {
  value = digitalocean_cdn.media.endpoint
}

output "ui_custom_bucket" {
  value = digitalocean_spaces_bucket.ui_custom.name
}

# Bound into the ui-router Worker as STORAGE_CDN_ORIGIN (spec §6.1).
output "ui_custom_cdn_host" {
  value = digitalocean_cdn.ui_custom.endpoint
}
