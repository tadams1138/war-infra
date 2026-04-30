# War — Infrastructure Specification
**Repo:** `war-infra`  
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-04-28

---

## Table of Contents

1. [Overview](#1-overview)
2. [Repository Structure](#2-repository-structure)
3. [Environments](#3-environments)
4. [Repos & Ownership](#4-repos--ownership)
5. [Hosting Architecture](#5-hosting-architecture)
6. [URL Routing](#6-url-routing)
7. [CDN & Static File Strategy](#7-cdn--static-file-strategy)
8. [CI/CD Pipelines](#8-cicd-pipelines)
9. [Environment Variables & Secrets](#9-environment-variables--secrets)
10. [Database Migrations](#10-database-migrations)
11. [Image Storage](#11-image-storage)
12. [Monitoring & Alerting](#12-monitoring--alerting)
13. [Tech Stack](#13-tech-stack)
14. [Out of Scope (v1)](#14-out-of-scope-v1)
15. [Gherkin Acceptance Tests](#15-gherkin-acceptance-tests)

---

## 1. Overview

`war-infra` is the single source of truth for all infrastructure, environment configuration, and CI/CD pipeline definitions across the War platform. It does not contain application code. All four application repos (`war-api`, `war-ui-default`, `war-ui-{slug}`) reference pipeline templates defined here.

Infrastructure is defined as code (IaC) and all environment changes are applied via automated pipelines — no manual cloud console changes in staging or production.

---

## 2. Repository Structure

```
war-infra/
├── terraform/
│   ├── modules/
│   │   ├── api/              # API service (container, DB, secrets)
│   │   ├── cdn/              # CDN distributions (default UI + custom UIs)
│   │   └── storage/          # Object store buckets (images, static assets)
│   ├── envs/
│   │   ├── staging/
│   │   │   └── main.tf
│   │   └── production/
│   │       └── main.tf
│   └── variables.tf
├── pipelines/
│   ├── api.yml               # Reusable pipeline for war-api
│   ├── ui-default.yml        # Reusable pipeline for war-ui-default
│   ├── ui-custom.yml         # Reusable pipeline for war-ui-{slug} repos
│   └── infra.yml             # Pipeline for this repo (Terraform apply)
├── scripts/
│   ├── register-ui.sh        # Register a new custom UI slug
│   └── smoke-test.sh         # Post-deploy smoke tests
├── docs/
│   └── runbook.md
└── README.md
```

---

## 3. Environments

| Environment | Purpose | Deployment trigger |
|---|---|---|
| **staging** | Pre-production testing | Merge to `master` in any app repo |
| **production** | Live platform | Manual promotion after staging smoke tests pass |

All environments use isolated resources (separate DB, separate CDN distributions, separate object store buckets).

---

## 4. Repos & Ownership

| Repo | Type | Pipeline template |
|---|---|---|
| `war-api` | Backend API (containerised) | `pipelines/api.yml` |
| `war-ui-default` | Static SPA | `pipelines/ui-default.yml` |
| `war-ui-{slug}` | Static custom UI (one per War brand) | `pipelines/ui-custom.yml` |
| `war-infra` | Infrastructure IaC | `pipelines/infra.yml` |

Each app repo references the pipeline template from this repo using GitHub Actions reusable workflows:

```yaml
# Example in war-api/.github/workflows/deploy.yml
jobs:
  deploy:
    uses: your-org/war-infra/.github/workflows/api.yml@master
    secrets: inherit
```

---

## 5. Hosting Architecture

```
                        ┌─────────────────────────────┐
                        │        CloudFront CDN        │
                        │   (single distribution)      │
                        └────────────┬────────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                       │
     /api/v1/*             /ui/default/*          /ui/{slug}/*
              │                      │                       │
    ┌─────────▼──────┐    ┌──────────▼──────┐   ┌──────────▼──────┐
    │  war-api        │    │  S3 bucket       │   │  S3 bucket       │
    │  (ECS / Render) │    │  war-ui-default  │   │  war-ui-{slug}   │
    └─────────────────┘    └─────────────────┘   └─────────────────┘
              │
    ┌─────────▼──────┐
    │  PostgreSQL RDS │
    │  (or Supabase)  │
    └─────────────────┘
```

- A **single CDN distribution** handles all traffic, routing by path prefix
- The API runs as a containerised service (ECS Fargate or Render)
- All static UIs are hosted in S3 buckets (one per UI) behind the same CDN
- All paths not matching `/api/v1/*` or `/ui/*` route to the default UI

---

## 6. URL Routing

All routing rules are defined in the CDN distribution (CloudFront behaviours or equivalent).

| Path pattern | Target | Notes |
|---|---|---|
| `/api/v1/*` | `war-api` container | Forwarded as-is; no path rewrite |
| `/ui/default/*` | `war-ui-default` S3 bucket | Path prefix stripped; `index.html` fallback |
| `/ui/{slug}/*` | `war-ui-{slug}` S3 bucket | Slug resolved via CDN origin group; `index.html` fallback |
| `/*` (catch-all) | `war-ui-default` S3 bucket | Default UI serves all unmatched paths |

### SPA Fallback Rule
All static UI origins must be configured with a **custom error response**: HTTP 404 → serve `index.html` with HTTP 200. This enables client-side routing within each SPA.

### Custom UI Slug Resolution
The CDN origin for `/ui/{slug}/*` is parameterised per slug. When a new custom UI is registered, a new CDN origin and behaviour are added via Terraform (triggered by `scripts/register-ui.sh`).

---

## 7. CDN & Static File Strategy

- Static assets (JS, CSS, images) are deployed to S3 with **long cache TTLs** (`Cache-Control: max-age=31536000, immutable`) using content-hashed filenames (handled by Vite build output)
- `index.html` is deployed with **no-cache** (`Cache-Control: no-store`) so deploys are picked up immediately
- CloudFront invalidation is triggered on every deploy for `index.html` paths only
- Contestant images (uploaded via the API) are stored in a **separate S3 bucket** with public read access, served via the same CDN under `/media/*`

---

## 8. CI/CD Pipelines

### 8.1 `pipelines/api.yml` — war-api

```
Trigger: push to master (in war-api repo)

Stages:
  lint          →  eslint + tsc --noEmit
  test          →  vitest (unit + integration, against test DB)
  build         →  docker build
  push          →  push image to ECR / container registry
  migrate       →  run DB migrations against staging DB
  deploy-stg    →  deploy image to staging ECS service
  smoke-test    →  scripts/smoke-test.sh staging api
  deploy-prod   →  (manual approval gate) deploy to production
  smoke-test    →  scripts/smoke-test.sh production api
```

### 8.2 `pipelines/ui-default.yml` — war-ui-default

```
Trigger: push to master (in war-ui-default repo)

Stages:
  lint          →  eslint
  typecheck     →  tsc --noEmit
  test          →  vitest
  build         →  vite build
  deploy-stg    →  aws s3 sync dist/ s3://war-ui-default-staging/
  invalidate    →  CloudFront invalidation for /ui/default/index.html
  smoke-test    →  scripts/smoke-test.sh staging ui-default
  deploy-prod   →  (manual approval gate) aws s3 sync to production bucket
  invalidate    →  CloudFront invalidation (production)
  smoke-test    →  scripts/smoke-test.sh production ui-default
```

### 8.3 `pipelines/ui-custom.yml` — war-ui-{slug}

```
Trigger: push to master (in any war-ui-{slug} repo)

Stages:
  lint          →  eslint (or equivalent)
  build         →  vite build (or equivalent)
  size-check    →  assert dist/ total < 2MB
  template-check→  assert war-detail, vote-mode, rankings templates present
  deploy-stg    →  aws s3 sync dist/ s3://war-ui-{slug}-staging/
  invalidate    →  CloudFront invalidation for /ui/{slug}/index.html
  smoke-test    →  scripts/smoke-test.sh staging ui {slug}
  deploy-prod   →  (manual approval gate) sync to production
  invalidate    →  CloudFront invalidation (production)
  smoke-test    →  scripts/smoke-test.sh production ui {slug}
```

### 8.4 `pipelines/infra.yml` — war-infra

```
Trigger: push to master (in war-infra repo)

Stages:
  validate      →  terraform validate
  plan-stg      →  terraform plan (staging)
  apply-stg     →  terraform apply (staging, auto-approve)
  plan-prod     →  terraform plan (production)
  apply-prod    →  (manual approval gate) terraform apply (production)
```

---

## 9. Environment Variables & Secrets

All secrets are stored in **AWS Secrets Manager** (or equivalent) and injected into the API container at runtime. They are never stored in any repo.

| Variable | Used by | Description |
|---|---|---|
| `DATABASE_URL` | war-api | PostgreSQL connection string |
| `JWT_SECRET` | war-api | JWT signing key |
| `REFRESH_TOKEN_SECRET` | war-api | Refresh token signing key |
| `GOOGLE_CLIENT_ID` | war-api | Google OAuth client ID |
| `GOOGLE_CLIENT_SECRET` | war-api | Google OAuth client secret |
| `MICROSOFT_CLIENT_ID` | war-api | Microsoft OAuth client ID |
| `MICROSOFT_CLIENT_SECRET` | war-api | Microsoft OAuth client secret |
| `FACEBOOK_CLIENT_ID` | war-api | Facebook OAuth client ID |
| `FACEBOOK_CLIENT_SECRET` | war-api | Facebook OAuth client secret |
| `S3_MEDIA_BUCKET` | war-api | S3 bucket name for contestant images |
| `CDN_BASE_URL` | war-api | Base URL for CDN (used to construct image URLs) |
| `VITE_API_BASE_URL` | war-ui-* | API base URL (injected at build time) |

GitHub Actions secrets (for CI/CD):
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — deploy access
- `CLOUDFRONT_DISTRIBUTION_ID` — for cache invalidation

---

## 10. Database Migrations

- Migrations are plain SQL files in `war-api/db/migrations/`, named `001_init.sql`, `002_add_ui_slug.sql`, etc.
- Applied in order by the `migrate` pipeline stage before each deploy
- A `schema_migrations` table tracks which migrations have been applied
- Migrations must be **backwards-compatible** (no destructive column drops until the old code is fully retired)
- Rollback is manual (documented in `docs/runbook.md`)

---

## 11. Image Storage

Contestant images are uploaded via `war-api` and stored in S3:

```
s3://war-media-{env}/
└── contestants/
    └── {contestant_id}/
        └── {image_id}.{ext}
```

- Served via CDN at `https://cdn.war.app/media/contestants/{contestant_id}/{image_id}.{ext}`
- Upload is handled server-side by the API (pre-signed URL or direct upload via SDK)
- Images are public-read; no signed URL required for display
- Max image size: 10MB per file (enforced by API)
- Accepted formats: JPEG, PNG, WebP

---

## 12. Monitoring & Alerting

| Signal | Tool | Alert threshold |
|---|---|---|
| API error rate (5xx) | CloudWatch / Render metrics | > 1% over 5 min |
| API p99 latency | CloudWatch | > 2000ms over 5 min |
| DB connection pool | CloudWatch RDS | > 80% utilisation |
| Deploy failure | GitHub Actions | Any failed pipeline stage |
| CDN 4xx spike | CloudWatch | > 5% over 5 min |

Alerts route to a nominated Slack channel or email (configured in Terraform).

---

## 13. Tech Stack

| Component | Choice |
|---|---|
| IaC | Terraform |
| Cloud provider | AWS (CloudFront, S3, ECS Fargate, RDS, Secrets Manager) |
| Container registry | Amazon ECR |
| CI/CD | GitHub Actions (reusable workflows) |
| DNS | Route 53 |
| TLS | AWS Certificate Manager |

---

## 14. Out of Scope (v1)

- Multi-region deployment
- Blue/green or canary deploys (straight replacement deploys only)
- WAF / DDoS protection (revisit at scale)
- Automated rollback on smoke test failure (manual rollback via runbook)
- Log aggregation beyond CloudWatch
- Cost alerting / budget alarms

---

## 15. Gherkin Acceptance Tests

```gherkin
Feature: Routing

  Scenario: API requests are routed to the API service
    When a request is made to /api/v1/wars
    Then the request is forwarded to the war-api container
    And the response is JSON

  Scenario: Default UI is served for unmatched paths
    When a request is made to /some/unknown/path
    Then index.html from war-ui-default is returned
    And the HTTP status is 200

  Scenario: Custom UI slug is routed to the correct S3 bucket
    Given a registered slug "miss-universe-2026"
    When a request is made to /ui/miss-universe-2026/
    Then index.html from the war-ui-miss-universe-2026 S3 bucket is returned

  Scenario: SPA deep links return index.html
    Given the default UI is deployed
    When a request is made to /wars/some-war-id/vote
    Then index.html is returned with HTTP 200
    And the client-side router handles the route

Feature: CI/CD Pipelines

  Scenario: API deploy pipeline runs all stages on merge to master
    Given a merged PR in war-api
    When the pipeline triggers
    Then lint, test, build, and migrate stages all pass
    And the image is deployed to staging
    And smoke tests pass before production gate is reached

  Scenario: Custom UI pipeline blocks on missing required template
    Given a war-ui-{slug} repo missing vote-mode.mustache
    When the pipeline runs the template-check stage
    Then the pipeline fails
    And no deployment occurs

  Scenario: Custom UI pipeline blocks on bundle size exceeded
    Given a war-ui-{slug} repo with a built output of 3MB
    When the pipeline runs the size-check stage
    Then the pipeline fails with a size error
    And no deployment occurs

  Scenario: Infrastructure changes require manual approval for production
    Given a Terraform change merged to war-infra master
    When the pipeline reaches the apply-prod stage
    Then it pauses for manual approval
    And only proceeds after a team member approves

Feature: Secrets & Config

  Scenario: Secrets are never stored in repos
    Given any application repo
    When the repo is scanned for secret patterns
    Then no secrets, API keys, or credentials are found

  Scenario: API container receives correct env vars at runtime
    Given the war-api container starts in staging
    When it initialises
    Then DATABASE_URL, JWT_SECRET, and OAuth credentials are available
    And they match the values stored in Secrets Manager
```
