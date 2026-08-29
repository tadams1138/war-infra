# App Platform app — see specs/war-infra-spec.md §5.2, §15.2
#
# OWNERSHIP SPLIT — read this before changing anything here.
#
# Terraform *creates* the app and owns its identity. It does not own its spec.
# The full spec lives in platform/{env}.yaml and is applied by the deploy
# pipelines, because the API's image tag changes on every merge and pinning it
# here would mean every application deploy required a terraform apply.
#
# `ignore_changes = [spec]` is what makes the two coexist: Terraform creates a
# minimal valid app once, the first pipeline deploy replaces the spec with the
# real one, and Terraform never reverts it. Without this, `terraform apply`
# would roll the running API back to the placeholder below.
#
# Consequence: after bootstrap, this module's spec block is inert. Change
# platform/{env}.yaml, not this file.

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "nyc"
}

variable "domain" {
  type        = string
  description = "Public hostname, e.g. staging.war.tmad.dev"
}

variable "database_cluster_name" {
  type = string
}

variable "registry_repository" {
  type    = string
  default = "war-api"
}

resource "digitalocean_app" "war" {
  spec {
    name   = "war-${var.env}"
    region = var.region

    domain {
      name = var.domain
      type = "PRIMARY"
    }

    database {
      name         = "db"
      engine       = "PG"
      cluster_name = var.database_cluster_name
      production   = true
    }

    # Placeholder only — replaced by platform/{env}.yaml on first deploy.
    service {
      name               = "war-api"
      instance_size_slug = "basic-xxs"
      instance_count     = 1
      http_port          = 8080

      image {
        registry_type = "DOCR"
        repository    = var.registry_repository
        tag           = "bootstrap"
      }
    }

    # Alerts are declared here rather than in the YAML so that a pipeline
    # mistake cannot silently drop monitoring (spec §13). They are re-asserted
    # by platform/{env}.yaml; keeping both in sync is intentional redundancy.
    alert {
      rule = "DEPLOYMENT_FAILED"
    }

    alert {
      rule = "DOMAIN_FAILED"
    }
  }

  lifecycle {
    ignore_changes = [spec]
  }
}

output "app_id" {
  value = digitalocean_app.war.id
}

# The *.ondigitalocean.app hostname. Cloudflare proxies to this; it is never
# advertised and should not appear in any user-facing URL.
output "app_default_host" {
  value = digitalocean_app.war.default_ingress
}

output "live_url" {
  value = digitalocean_app.war.live_url
}
