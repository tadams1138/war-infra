# Scheduled tasks — see specs/war-infra-spec.md §12, §15.4
#
# App Platform jobs are deploy-lifecycle only (PRE_DEPLOY / POST_DEPLOY /
# FAILED_DEPLOY) and provide no cron scheduling, so the scheduler role is filled
# at the edge by a Worker with a Cron Trigger.
#
# The Worker calls the App Platform origin hostname directly, bypassing the WAF
# rule in modules/edge that blocks /api/v1/internal/* on the public hostname.

# Required in every module that uses it, not just the root — Terraform does
# not infer a non-default-namespace provider's source for a child module from
# the root's required_providers alone.
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare" }
  }
}

variable "env" { type = string }
variable "account_id" { type = string }

variable "api_origin" {
  type        = string
  description = "App Platform origin, e.g. https://war-staging-xxxxx.ondigitalocean.app"
}

variable "internal_task_token" {
  type      = string
  sensitive = true
}

variable "cron" {
  type        = string
  description = "Cron expression in UTC"
  default     = "0 3 * * *" # 03:00 UTC daily — close-expired-wars
}

resource "cloudflare_workers_script" "scheduled_tasks" {
  account_id = var.account_id
  name       = "war-scheduled-tasks-${var.env}"
  content    = file("${path.module}/../../../edge/scheduled-tasks.js")
  module     = true

  plain_text_binding {
    name = "API_BASE_URL"
    text = var.api_origin
  }

  secret_text_binding {
    name = "INTERNAL_TASK_TOKEN"
    text = var.internal_task_token
  }
}

resource "cloudflare_workers_cron_trigger" "scheduled_tasks" {
  account_id  = var.account_id
  script_name = cloudflare_workers_script.scheduled_tasks.name
  schedules   = [var.cron]
}

output "worker_name" {
  value = cloudflare_workers_script.scheduled_tasks.name
}
