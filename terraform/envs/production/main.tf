# War — production environment
# See specs/war-infra-spec.md §3. Same composition as staging, with larger
# sizing and a standby database node.

terraform {
  required_version = "~> 1.9"

  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.43" }
    cloudflare   = { source = "cloudflare/cloudflare", version = "~> 4.40" }
    time         = { source = "hashicorp/time", version = "~> 0.12" }
  }

  backend "s3" {
    endpoints                   = { s3 = "https://nyc3.digitaloceanspaces.com" }
    bucket                      = "war-tfstate"
    key                         = "envs/production/terraform.tfstate"
    region                      = "us-east-1" # ignored by Spaces; required by the backend
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = false
  }
}

locals {
  env    = "production"
  domain = "war.tmad.dev"
}

# ── Credentials ───────────────────────────────────────────────────────────────
# Supplied by the pipeline as TF_VAR_* from GitHub Actions secrets (spec §9).

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

variable "cloudflare_account_id" {
  type      = string
  sensitive = true
}

variable "internal_task_token" {
  type      = string
  sensitive = true
}

variable "spaces_access_key" {
  type      = string
  sensitive = true
}

variable "spaces_secret_key" {
  type      = string
  sensitive = true
}

# Spaces uses S3-compatible credentials, which the API token does not cover.
# Without these, every digitalocean_spaces_bucket resource fails to apply.
provider "digitalocean" {
  token             = var.do_token
  spaces_access_id  = var.spaces_access_key
  spaces_secret_key = var.spaces_secret_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── Data ──────────────────────────────────────────────────────────────────────

module "data" {
  source = "../../modules/data"

  env        = local.env
  node_size  = "db-s-1vcpu-2gb"
  node_count = 2 # primary + standby for HA (spec §5.3)
  pool_size  = 40

  trusted_app_id = module.compute.app_id
}

# ── Storage ───────────────────────────────────────────────────────────────────

module "storage" {
  source = "../../modules/storage"
  env    = local.env
}

# ── Compute ───────────────────────────────────────────────────────────────────
# Creates the app; platform/production.yaml owns its spec thereafter.

module "compute" {
  source = "../../modules/compute"

  env                   = local.env
  domain                = local.domain
  database_cluster_name = module.data.cluster_name
}

# DO's API can report a just-created app as having no active deployment yet
# ("Warning: No active deployment found for app") right when
# digitalocean_app.war's create call returns; module.compute.app_default_host
# is that same first read and cannot recover from a stale value by itself.
# time_sleep + a fresh data source read guards against that. Separately —
# and this is what actually broke the DNS record even once the read was
# fresh — default_ingress is a full URL ("https://<app>.ondigitalocean.app"),
# not a bare hostname, despite the compute module's own doc comment; a
# cloudflare_record CNAME's content must be a bare hostname, and prepending
# "https://" again for scheduler's api_origin would have double-scheme'd it.
# trimprefix below and the plain read here are both fixes for that, not the
# sleep/re-read.
resource "time_sleep" "app_ingress" {
  depends_on      = [module.compute]
  create_duration = "30s"
}

data "digitalocean_app" "war" {
  app_id     = module.compute.app_id
  depends_on = [time_sleep.app_ingress]
}

# ── Edge ──────────────────────────────────────────────────────────────────────

module "edge" {
  source = "../../modules/edge"

  env                = local.env
  zone_id            = var.cloudflare_zone_id
  account_id         = var.cloudflare_account_id
  domain             = local.domain
  app_default_host   = trimprefix(data.digitalocean_app.war.default_ingress, "https://")
  media_cdn_host     = module.storage.media_cdn_host
  ui_custom_cdn_host = module.storage.ui_custom_cdn_host
}

# ── Scheduler ─────────────────────────────────────────────────────────────────

module "scheduler" {
  source = "../../modules/scheduler"

  env                 = local.env
  account_id          = var.cloudflare_account_id
  api_origin          = data.digitalocean_app.war.default_ingress
  internal_task_token = var.internal_task_token
}

# ── Outputs ───────────────────────────────────────────────────────────────────
# app_id is consumed by the deploy pipelines as the DO_APP_ID environment
# variable (spec §15.7).

output "app_id" {
  value = module.compute.app_id
}

output "public_base_url" {
  value = "https://${local.domain}"
}

output "media_bucket" {
  value = module.storage.media_bucket
}

output "ui_custom_bucket" {
  value = module.storage.ui_custom_bucket
}

output "database_cluster_name" {
  value = module.data.cluster_name
}
