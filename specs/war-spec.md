# War — Project Overview
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-04-28

---

## 1. Overview

War is a web-first (mobile-compatible) social voting platform where authenticated users participate in **Wars** — themed campaigns where a set of contestants are ranked through head-to-head binary matchups. The result is a crowd-sourced leaderboard driven by pairwise comparison.

Pairwise comparison forces deliberate choices and produces statistically stronger rankings than single-click polls. War gamifies that process into a shareable, social voting experience.

---

## 2. Goals & Non-Goals

### Goals
- Provide a clean API layer that serves both the web frontend and future mobile apps identically
- Support multiple OAuth login providers, each producing a unique, non-mergeable voter identity
- Allow War creators to configure campaigns with image-rich or short-video contestants
- Let each campaign describe its contestants with its own fields, so a pageant and a primary are served by the same code
- Serve voters binary matchups (one at a time) and persist their choices with full history
- Surface a win-count leaderboard accessible to anonymous and authenticated users alike
- Maintain a tamper-evident vote audit trail for future analysis

### Non-Goals (v1)
- Real-time leaderboard streaming (polled / on-demand refresh only)
- Push notifications
- War creator moderation tools (removing voters, resetting votes)
- Vote tamper detection analytics (audit data is collected; tooling is future)
- Admin moderation dashboard
- Paid or promoted Wars
- Weighted votes (all voters are equal)
- Changing a vote once cast (votes are final)
- Comments or reactions on contestants
- Linking multiple OAuth providers to a single voter account
- Hosting or transcoding video (video contestants embed third-party players only)
- Mixing images and video within one campaign

---

## 3. Users & Roles

| Role | Description |
|---|---|
| **Anonymous Visitor** | Can browse and view rankings of Public Wars; cannot vote |
| **Voter** | Authenticated user; can join Wars, cast votes (final — see `war-api-spec.md` §9), view rankings |
| **War Creator** | A Voter who created a specific War; can manage it through Draft → Active → Closed |

---

## 4. Architecture

The system is **API-first**. The backend exposes a versioned REST API that is the single source of truth for all business logic. Clients are thin — they render data returned by the API and submit user actions back to it.

```
┌─────────────────────────────────────────┐
│             Clients (thin)              │
│  ┌──────────────┐  ┌──────────────────┐ │
│  │  Web App     │  │  Mobile App (*)  │ │
│  │  (React SPA) │  │  (React Native)  │ │
│  └──────┬───────┘  └────────┬─────────┘ │
└─────────┼────────────────────┼───────────┘
          │   HTTPS / REST     │
          ▼                    ▼
┌─────────────────────────────────────────┐
│           REST API  /api/v1/...         │
└──────────────────────┬──────────────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
   ┌─────────────┐         ┌──────────────┐
   │  PostgreSQL │         │ Object Store │
   │  (primary)  │         │  (images)    │
   └─────────────┘         └──────────────┘
```

*Mobile app is a future deliverable; the API is designed to support it from day one.*

For detailed specifications see:
- [`war-api-spec.md`](war-api-spec.md) — REST API, data model, auth, scoring, vote integrity
- [`war-ui-default-spec.md`](war-ui-default-spec.md) — default web frontend
- [`war-ui-custom-spec.md`](war-ui-custom-spec.md) — per-brand custom frontends and their template contract
- [`war-infra-spec.md`](war-infra-spec.md) — hosting, CI/CD, environments

---

## 5. Out of Scope (v1)

- Real-time leaderboard streaming (WebSockets / SSE)
- Push notifications (web or mobile)
- War creator moderation (removing voters, resetting individual votes)
- Vote tamper detection analytics (data collected; tooling is future)
- Admin moderation dashboard
- Linking multiple OAuth providers to one voter account
- Paid or promoted Wars
- Weighted votes
- Comments or reactions on contestants
- ELO or Borda count scoring (raw win counts only for v1)
- Changing a vote once cast (votes are final)
