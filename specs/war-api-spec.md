# War — Backend API Specification
**Repo:** `war-api`  
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-04-28

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Principles](#2-architecture-principles)
3. [Repository Structure](#3-repository-structure)
4. [Authentication](#4-authentication)
5. [Core Domain Concepts](#5-core-domain-concepts)
6. [Data Model](#6-data-model)
7. [API Specification](#7-api-specification)
8. [Scoring Algorithm](#8-scoring-algorithm)
9. [Vote Integrity & Audit Trail](#9-vote-integrity--audit-trail)
10. [Custom UI Registration](#10-custom-ui-registration)
11. [Tech Stack](#11-tech-stack)
12. [CI/CD](#12-cicd)
13. [Out of Scope (v1)](#13-out-of-scope-v1)
14. [Gherkin Acceptance Tests](#14-gherkin-acceptance-tests)

---

## 1. Overview

The War API is the single authoritative backend for the War platform. It exposes a versioned REST API consumed by all frontend clients — the default UI, custom War UIs, and future mobile apps. No rendering or business logic lives outside this service.

---

## 2. Architecture Principles

- **API-first.** All business logic (scoring, matchup generation, vote validation) lives here. Clients are thin.
- **Stateless.** Every request is authenticated via Bearer JWT. No server-side session state.
- **Append-only votes.** The `votes` table is never updated or deleted — changes create new records.
- **No HTML rendering.** The API returns JSON only. It serves no HTML pages.
- **CORS.** The API allows requests from registered UI origins (default UI domain + custom UI domains, configured per environment).

```
All Clients (web, mobile, custom UIs)
         │
         │  HTTPS / REST JSON
         ▼
  /api/v1/...  (this service)
         │
    ┌────┴────┐
    ▼         ▼
PostgreSQL  Object Store
            (images)
```

---

## 3. Repository Structure

```
war-api/
├── src/
│   ├── auth/           # OAuth handlers, JWT issuance
│   ├── wars/           # War CRUD, lifecycle transitions
│   ├── contestants/    # Contestant & image management
│   ├── matchups/       # Matchup generation, next-matchup logic
│   ├── votes/          # Vote casting, audit trail
│   ├── rankings/       # Win % computation
│   └── ui-registry/    # Custom UI slug registration (see §10)
├── db/
│   └── migrations/     # SQL migration files
├── test/
│   └── *.spec.ts       # Unit + integration tests
├── .env.example
├── Dockerfile
└── README.md
```

---

## 4. Authentication

### OAuth Providers (v1)
- Google
- Microsoft Live
- Facebook

Extensible to Apple, GitHub, Twitter/X without schema changes.

### Identity Rules
- Each (provider, provider_user_id) pair maps to exactly one `voters` record
- Voters may not link multiple OAuth providers to one account
- First login auto-creates a Voter; subsequent logins return the existing record

### Session Tokens
- Successful OAuth callback issues a signed **JWT** (1h expiry) and a **refresh token** (30d)
- All protected endpoints require `Authorization: Bearer <jwt>`
- Refresh tokens are stored server-side (hashed) for revocation support

---

## 5. Core Domain Concepts

### War
A named voting campaign.

| Field | Notes |
|---|---|
| Title | e.g. "Miss Universe 2026" |
| Category / Tag | Optional; for filtering |
| Status | `draft` → `active` → `closed` |
| Visibility | `public` or `invite_only` |
| End Date | Optional; auto-closes War when reached |
| UI Slug | Optional; references a registered custom UI (see §10) |

**Status transitions:**
```
draft ──► active ──► closed
                └──► closed (manual or end date)
```

### Contestant
A participant in a War. Has a name, optional bio, and one or more uploaded images.

### Matchup
A head-to-head pairing between two contestants. For `n` contestants: `n(n-1)/2` matchups. Generated on War activation. Immutable after generation.

### Vote
A voter's pick in a Matchup. Append-only. The active vote is the latest record where `superseded_by_id IS NULL`.

---

## 6. Data Model

```sql
voters (
  id               UUID PRIMARY KEY,
  provider         VARCHAR(32) NOT NULL,
  provider_user_id VARCHAR(256) NOT NULL,
  display_name     VARCHAR(256),
  avatar_url       TEXT,
  created_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (provider, provider_user_id)
)

wars (
  id               UUID PRIMARY KEY,
  creator_id       UUID REFERENCES voters(id),
  title            VARCHAR(256) NOT NULL,
  category         VARCHAR(64),
  status           VARCHAR(16) NOT NULL DEFAULT 'draft',
  visibility       VARCHAR(16) NOT NULL DEFAULT 'public',
  ends_at          TIMESTAMPTZ,
  ui_slug          VARCHAR(64),                            -- optional custom UI
  created_at       TIMESTAMPTZ DEFAULT now()
)

contestants (
  id               UUID PRIMARY KEY,
  war_id           UUID REFERENCES wars(id),
  name             VARCHAR(256) NOT NULL,
  bio              TEXT,
  created_at       TIMESTAMPTZ DEFAULT now()
)

contestant_images (
  id               UUID PRIMARY KEY,
  contestant_id    UUID REFERENCES contestants(id),
  url              TEXT NOT NULL,
  display_order    INT NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now()
)

matchups (
  id               UUID PRIMARY KEY,
  war_id           UUID REFERENCES wars(id),
  contestant_a_id  UUID REFERENCES contestants(id),
  contestant_b_id  UUID REFERENCES contestants(id),
  created_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (war_id, contestant_a_id, contestant_b_id)
)

war_memberships (
  war_id           UUID REFERENCES wars(id),
  voter_id         UUID REFERENCES voters(id),
  joined_at        TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (war_id, voter_id)
)

votes (
  id               UUID PRIMARY KEY,
  matchup_id       UUID REFERENCES matchups(id),
  voter_id         UUID REFERENCES voters(id),
  winner_id        UUID REFERENCES contestants(id),
  created_at       TIMESTAMPTZ DEFAULT now(),
  superseded_by_id UUID REFERENCES votes(id)
)

-- Custom UI registry (see §10)
ui_registrations (
  slug             VARCHAR(64) PRIMARY KEY,
  label            VARCHAR(256),
  static_base_path TEXT NOT NULL,               -- CDN path prefix for this UI's assets
  registered_at    TIMESTAMPTZ DEFAULT now()
)
```

---

## 7. API Specification

**Base path:** `/api/v1`  
**All responses:** `Content-Type: application/json`  
**Auth:** `Authorization: Bearer <jwt>` where marked 🔒  
**Pagination:** cursor-based on all list endpoints

---

### 7.1 Auth

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/auth/{provider}/login` | — | Redirect to OAuth provider |
| `GET` | `/auth/{provider}/callback` | — | OAuth callback; returns JWT + refresh token |
| `POST` | `/auth/refresh` | — | Exchange refresh token for new JWT |
| `DELETE` | `/auth/session` | 🔒 | Logout / invalidate refresh token |
| `GET` | `/auth/me` | 🔒 | Current voter profile |

**`GET /auth/{provider}/callback` response `200`:**
```json
{
  "token": "<jwt>",
  "refresh_token": "<token>",
  "voter": { "id": "uuid", "display_name": "Jane", "avatar_url": "https://..." }
}
```

---

### 7.2 Wars

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/wars` | — | List public wars (paginated, filterable) |
| `POST` | `/wars` | 🔒 | Create war (status: draft) |
| `GET` | `/wars/:id` | — | War detail + contestants |
| `PATCH` | `/wars/:id` | 🔒 | Update war (draft only) |
| `POST` | `/wars/:id/activate` | 🔒 | draft → active; generates matchups |
| `POST` | `/wars/:id/close` | 🔒 | active → closed |
| `POST` | `/wars/:id/join` | 🔒 | Voter joins war |

**`GET /wars` query params:** `status`, `category`, `cursor`, `limit` (default 20, max 100)

**`POST /wars/:id/activate` rules:**
- Requires ≥ 2 contestants → else `422`
- Generates all `n(n-1)/2` matchups atomically
- Requester must be War creator → else `403`

---

### 7.3 Contestants

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/wars/:id/contestants` | 🔒 | Add contestant (draft only) |
| `PATCH` | `/wars/:id/contestants/:cId` | 🔒 | Update name/bio (draft only) |
| `DELETE` | `/wars/:id/contestants/:cId` | 🔒 | Remove contestant (draft only) |
| `POST` | `/wars/:id/contestants/:cId/images` | 🔒 | Upload images (draft only, multipart) |
| `PATCH` | `/wars/:id/contestants/:cId/images/:imgId` | 🔒 | Reorder / set primary (draft only) |
| `DELETE` | `/wars/:id/contestants/:cId/images/:imgId` | 🔒 | Remove image (draft only) |

---

### 7.4 Matchups & Voting

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/wars/:id/matchups/next` | 🔒 | Next unvoted matchup for this voter |
| `POST` | `/wars/:id/matchups/:mId/vote` | 🔒 | Cast or change vote |
| `GET` | `/wars/:id/my-progress` | 🔒 | Voter's vote count vs total |

**`GET /matchups/next` response `200`:**
```json
{
  "matchup": {
    "id": "uuid",
    "contestant_a": { "id": "uuid", "name": "...", "images": [{ "url": "...", "display_order": 0 }] },
    "contestant_b": { "id": "uuid", "name": "...", "images": [{ "url": "...", "display_order": 0 }] }
  },
  "progress": { "voted": 3, "total": 10 }
}
```
**`204`** when voter has completed all matchups.

**`POST /vote` body:** `{ "winner_id": "<uuid>" }`  
**Rules:**
- `winner_id` must be a contestant in this matchup → else `422`
- War must be `active` → else `403`
- Voter must have joined → else `403`
- If a prior active vote exists, it is superseded (see §9)

---

### 7.5 Rankings

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/wars/:id/rankings` | — (public wars) | Ranked leaderboard |

**Response `200`:**
```json
{
  "war_id": "uuid",
  "status": "active",
  "updated_at": "2026-04-28T12:00:00Z",
  "rankings": [
    {
      "rank": 1,
      "contestant": { "id": "uuid", "name": "...", "images": [{ "url": "...", "display_order": 0 }] },
      "wins": 320,
      "total_votes": 400,
      "win_pct": 80.0
    }
  ]
}
```

---

### 7.6 Custom UI Registry

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/ui-registry` | — | List registered UI slugs |
| `GET` | `/ui-registry/:slug` | — | Resolve slug to static base path |

See §10 for full detail.

---

## 8. Scoring Algorithm

Win % computed at query time from active votes only (`superseded_by_id IS NULL`).

```
win_pct(c) = COUNT(votes WHERE winner_id = c.id)
           / COUNT(votes WHERE c.id IN (matchup.contestant_a_id, matchup.contestant_b_id))
           * 100
```

- Rounded to 1 decimal place
- Ties broken by `total_votes` descending, then alphabetically by name
- Contestants with `total_votes = 0` are listed last as unranked

---

## 9. Vote Integrity & Audit Trail

Votes are append-only. To change a vote on matchup M:

1. Find current active vote V1: `WHERE matchup_id=M AND voter_id=V AND superseded_by_id IS NULL`
2. Insert new vote V2 with new `winner_id`
3. Set `V1.superseded_by_id = V2.id`

Active vote query: `WHERE matchup_id=? AND voter_id=? AND superseded_by_id IS NULL`

Full history is retained for future audit tooling (rapid vote changes, bulk patterns, coordinated reversals).

---

## 10. Custom UI Registration

Each custom War UI is a separately deployed static site (see `war-ui-[custom]` spec). The API maintains a registry mapping a short `slug` to the CDN base path where that UI's assets are hosted.

When a War has `ui_slug` set, the infrastructure routing layer uses this registry to serve the correct frontend bundle for that War's URLs (see `war-infra` spec).

The API exposes the registry read-only:

```
GET /api/v1/ui-registry           → [{ slug, label, static_base_path }]
GET /api/v1/ui-registry/:slug     → { slug, label, static_base_path }
```

Registration of new slugs is an administrative operation (no public endpoint in v1).

---

## 11. Tech Stack

| Component | Choice |
|---|---|
| Runtime | Node.js (TypeScript) |
| Framework | Express or Fastify |
| Database | PostgreSQL |
| ORM / Query builder | Prisma or Kysely |
| Auth | Passport.js (OAuth strategies) + jose (JWT) |
| Image storage | Cloudinary or AWS S3 |
| Testing | Vitest + Supertest |

---

## 12. CI/CD

See `war-infra` spec for pipeline definitions. The API repo contains:

- `Dockerfile` for containerised deployment
- `.env.example` documenting all required environment variables
- Database migration scripts in `db/migrations/`
- GitHub Actions workflow triggers (defined in infra repo, referenced here)

**Pipeline stages:** lint → test → build → push image → deploy (staging) → smoke test → deploy (production)

---

## 13. Out of Scope (v1)

- HTML rendering of any kind
- WebSocket / SSE real-time updates
- Vote tamper detection analytics
- Admin moderation endpoints
- Multi-provider OAuth account linking
- Weighted votes
- ELO or Borda count scoring

---

## 14. Gherkin Acceptance Tests

### Authentication

```gherkin
Feature: OAuth Authentication

  Scenario: New voter signs in with Google
    Given a user has never signed in before
    When they authenticate via Google OAuth
    Then a new Voter record is created
    And a JWT and refresh token are returned

  Scenario: Returning voter signs in
    Given a voter has previously signed in with Google
    When they authenticate again via Google OAuth
    Then no new Voter record is created
    And the existing record is returned

  Scenario: Same email, different provider creates separate voters
    Given voter A signed in with Google using "user@example.com"
    When a user signs in with Microsoft using "user@example.com"
    Then a separate Voter record is created
    And the two accounts are not linked

  Scenario: Unauthenticated request to protected endpoint
    Given a request with no Authorization header
    When they call GET /api/v1/auth/me
    Then the response status is 401
```

### War Lifecycle

```gherkin
Feature: War Lifecycle

  Scenario: Creator activates a War with enough contestants
    Given a War in "draft" status with 3 contestants
    When the creator POSTs to /api/v1/wars/:id/activate
    Then the War status becomes "active"
    And exactly 3 matchups are generated

  Scenario: Cannot activate with fewer than 2 contestants
    Given a War in "draft" with 1 contestant
    When the creator POSTs to activate
    Then the response status is 422
    And the War remains "draft"

  Scenario: Cannot edit after activation
    Given a War in "active" status
    When the creator PATCHes the title
    Then the response status is 403

  Scenario: Non-creator cannot activate
    Given a War created by Voter A
    When Voter B POSTs to activate
    Then the response status is 403
```

### Voting

```gherkin
Feature: Voting

  Scenario: Voter casts a vote
    Given a voter who joined an active War
    And matchup M has not been voted on by this voter
    When they POST /vote with a valid winner_id
    Then a Vote record is created with superseded_by_id NULL

  Scenario: Voter changes a vote
    Given a voter who voted Contestant A in matchup M
    When they POST /vote with winner_id = Contestant B
    Then a new Vote record is created
    And the original Vote has superseded_by_id set
    And rankings count Contestant B's win for matchup M

  Scenario: Cannot vote on a closed War
    Given a War in "closed" status
    When a voter POSTs a vote
    Then the response status is 403

  Scenario: Non-joined voter cannot vote
    Given an active War
    And an authenticated voter who has not joined
    When they POST a vote
    Then the response status is 403
```

### Rankings

```gherkin
Feature: Rankings

  Scenario: Anonymous user views public War rankings
    Given a public War in "active" status
    When an unauthenticated user GETs /wars/:id/rankings
    Then the response status is 200

  Scenario: Win % excludes superseded votes
    Given Voter X originally voted Contestant A in matchup M
    And Voter X later changed their vote to Contestant B
    When rankings are fetched
    Then Contestant B receives the win for matchup M
    And Contestant A does not

  Scenario: Correct win percentage
    Given Contestant A won 300 of 400 total votes cast in their matchups
    When rankings are fetched
    Then Contestant A's win_pct is 75.0

  Scenario: Invite-only War rankings blocked for anonymous users
    Given an invite_only War
    When an unauthenticated user GETs rankings
    Then the response status is 401
```
