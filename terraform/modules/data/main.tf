# Managed PostgreSQL — see specs/war-infra-spec.md §5.3
#
# The connection pooler is the reason this module exists as more than a single
# resource. The API must connect through PgBouncer, never directly: §13 of the
# spec alerts on pool utilisation, and App Platform's instance counts multiplied
# by a per-instance client pool exhausts a small cluster's connection limit
# quickly without one.

# Required in every module that uses it, not just the root — Terraform does
# not infer a non-default-namespace provider's source for a child module from
# the root's required_providers alone.
terraform {
  required_version = "~> 1.9"

  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.43" }
  }
}

variable "env" {
  type        = string
  description = "staging | production"
}

variable "region" {
  type    = string
  default = "nyc3"
}

variable "node_size" {
  type        = string
  description = "Cluster node slug, e.g. db-s-1vcpu-1gb"
}

variable "node_count" {
  type        = number
  description = "1 for staging; 2 (primary + standby) for production"
  default     = 1
}

variable "pg_version" {
  type    = string
  default = "16"
}

variable "pool_size" {
  type        = number
  description = "Backend connections the pooler holds open"
  default     = 20
}

resource "digitalocean_database_cluster" "pg" {
  name       = "war-${var.env}-pg"
  engine     = "pg"
  version    = var.pg_version
  size       = var.node_size
  region     = var.region
  node_count = var.node_count

  maintenance_window {
    day  = "tuesday"
    hour = "07:00:00" # low-traffic window, ahead of the 03:00 UTC scheduled task
  }

  tags = ["war", var.env]
}

resource "digitalocean_database_db" "war" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "war"
}

resource "digitalocean_database_user" "api" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "war_api"

  # Terraform planned an in-place update to this resource on the second real
  # apply despite neither argument above ever changing - the only other
  # top-level attributes the provider's schema documents, mysql_auth_plugin
  # and settings, are MySQL- and Kafka-specific respectively and shouldn't
  # apply to a "pg" cluster, but the provider records an empty settings {}
  # block in state regardless and later plans to remove it. Either attempted
  # update fails outright: "PUT .../users/war_api: 400 ... missing the
  # following required fields: user_settings" - a provider-side request-
  # construction bug for this engine, not something fixable from here.
  # Ignoring both stops Terraform from ever taking that path for attributes
  # that have no meaning for this cluster anyway. mysql_auth_plugin drifted
  # first (staging); settings surfaced only later, on production's first
  # apply - add the next one here too if the provider finds a third.
  lifecycle {
    ignore_changes = [mysql_auth_plugin, settings]
  }
}

# Transaction-mode pooling. Session-mode would hold a backend connection for the
# whole client session and defeat the purpose; the API uses no session state
# (no advisory locks, no prepared-statement reuse across requests) so
# transaction mode is safe.
resource "digitalocean_database_connection_pool" "api" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "war-${var.env}-pool"
  mode       = "transaction"
  size       = var.pool_size
  db_name    = digitalocean_database_db.war.name
  user       = digitalocean_database_user.api.name
}

# Restrict the cluster to the App Platform app. Passed in rather than derived,
# because the app is created from platform/{env}.yaml (see modules/compute).
#
# Unconditional, not gated behind `count`: both envs always pass a real
# module.compute.app_id, and on a from-scratch apply that id is "known after
# apply" (the app is created in the same plan) — a value Terraform cannot use
# to decide a resource's *count*, even though it's completely fine to use as
# a plain attribute value (which is all this does). Gating existence on
# `trusted_app_id == ""` produced "Invalid count argument" on every first
# apply; do not reintroduce it.
variable "trusted_app_id" {
  type        = string
  description = "App Platform app id permitted to reach the cluster"
}

resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id

  rule {
    type  = "app"
    value = var.trusted_app_id
  }
}

output "cluster_id" {
  value = digitalocean_database_cluster.pg.id
}

output "cluster_name" {
  value = digitalocean_database_cluster.pg.name
}

output "database_name" {
  value = digitalocean_database_db.war.name
}

# The pooled URI. This is what belongs in DATABASE_URL — never
# digitalocean_database_cluster.pg.uri, which bypasses the pooler.
output "pooled_uri" {
  value     = digitalocean_database_connection_pool.api.private_uri
  sensitive = true
}
