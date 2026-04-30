# War — Project Specification
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-04-28

---

## Table of Contents

1. [Overview](#1-overview)
2. [Goals & Non-Goals](#2-goals--non-goals)
3. [Users & Roles](#3-users--roles)
4. [Architecture Principles](#4-architecture-principles)
5. [Authentication](#5-authentication)
6. [Core Domain Concepts](#6-core-domain-concepts)
7. [Data Model](#7-data-model)
8. [API Specification](#8-api-specification)
9. [UI Specification](#9-ui-specification)
10. [Scoring Algorithm](#10-scoring-algorithm)
11. [Vote Integrity & Audit Trail](#11-vote-integrity--audit-trail)
12. [Tech Stack](#12-tech-stack)
13. [Out of Scope (v1)](#13-out-of-scope-v1)
14. [Gherkin Acceptance Tests](#14-gherkin-acceptance-tests)

---

## 1. Overview

War is a web-first (mobile-compatible) social voting platform where authenticated users participate in **Wars** — themed campaigns where a set of contestants are ranked through head-to-head binary matchups. The result is a crowd-sourced leaderboard driven by pairwise comparison.

Pairwise comparison forces deliberate choices and produces statistically stronger rankings than single-click polls. War gamifies that process into a shareable, social voting experience.

---

## 2. Goals & Non-Goals

### Goals
- Provide a clean API layer that serves both the web frontend and future mobile apps identically
- Support multiple OAuth login providers, each producing a unique, non-mergeable voter identity
- Allow War creators to configure campaigns with multiple image-rich contestants
- Serve voters binary matchups (one at a time) and persist their choices with full history
- Surface a Win %-based leaderboard accessible to anonymous and authenticated users alike
- Maintain a tamper-evident vote audit trail for future analysis

### Non-Goals (v1)
- Real-time leaderboard streaming (polled / on-demand refresh only)
- Push notifications
- War creator moderation tools (removing voters, resetting votes)
- Vote tamper detection analytics (audit data is collected; tooling is future)
- Admin moderation dashboard
- Paid or promoted Wars
- Weighted votes (all voters are equal)
- Comments or reactions on contestants
- Linking multiple OAuth providers to a single voter account

---

## 3. Users & Roles

| Role | Description |
|---|---|
| **Anonymous Visitor** | Can browse and view rankings of Public Wars; cannot vote |
| **Voter** | Authenticated user; can join Wars, cast and change votes, view rankings |
| **War Creator** | A Voter who created a specific War; can manage it through Draft → Active → Closed |

---

## 4. Architecture Principles

### API/UI Separation
The system is designed **API-first**. The backend exposes a versioned REST API that is the **single source of truth** for all business logic. The web frontend and any future mobile app are **thin clients** — they render data returned by the API and submit user actions back to it. No business logic lives in the UI layer.

```
┌─────────────────────────────────────────┐
│             Clients (thin)              │
│  ┌──────────────┐  ┌──────────────────┐ │
│  │  Web App     │  │  Mobile App (*)  │ │
│  │  (Next.js)   │  │  (React Native)  │ │
│  └──────┬───────┘  └────────┬─────────┘ │
└─────────┼────────────────────┼───────────┘
          │   HTTPS / REST     │
          ▼                    ▼
┌─────────────────────────────────────────┐
│           REST API (versioned)          │
│  /api/v1/...                            │
│  - Auth            - Matchups           │
│  - Wars            - Votes              │
│  - Contestants     - Rankings           │
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

### Key Constraints
- All responses are JSON
- All endpoints are stateless; authentication is via Bearer token (JWT)
- Pagination is cursor-based for all list endpoints
- The UI **never computes scores or rankings** — it only displays what the API returns
- The UI **never constructs matchup pairings** — the API generates and owns all matchups

---

## 5. Authentication

### OAuth Providers (v1)
- Google
- Microsoft Live
- Facebook

The provider list is extensible (Apple, GitHub, Twitter/X) without schema changes.

### Identity Rules
- Each OAuth provider + provider user ID pair maps to exactly **one Voter** record
- Voters may not link multiple OAuth providers to one account
- On first login, a Voter record is auto-created
- On subsequent logins, the existing Voter record is returned

### Session
- On successful OAuth callback, the API issues a signed **JWT** (short-lived, e.g. 1h) and a **refresh token** (long-lived, e.g. 30d)
- All protected API endpoints require `Authorization: Bearer <jwt>`
- The UI stores tokens in memory (web) or secure storage (mobile); never in localStorage

---

## 6. Core Domain Concepts

### War
A named voting campaign.

| Field | Notes |
|---|---|
| Title | e.g. "Miss Universe 2026" |
| Category / Tag | Optional; used for filtering |
| Status | `draft` → `active` → `closed` |
| Visibility | `public` or `invite_only` |
| End Date | Optional; when reached, War auto-closes |
| Contestants | 2–n participants |

**Status transitions:**
```
draft ──► active ──► closed
                └──► closed (manual or end date reached)
```
- Edits (contestants, images, metadata) only permitted in `draft`
- Votes only accepted in `active`
- Rankings visible in all statuses (to appropriate audience)

### Contestant
A participant within a War.

| Field | Notes |
|---|---|
| Name | Display name |
| Images | One or more uploaded images; first is primary |
| Bio | Optional short description |
| Score | Computed by API (not stored) |

### Matchup
A generated head-to-head pairing between two contestants. For `n` contestants there are `n(n-1)/2` unique matchups.

- Generated automatically when a War transitions from `draft` → `active`
- Immutable after generation
- Each matchup is presented to each voter independently

### Vote
A voter's pick in a single Matchup.

- One **active** vote per (voter, matchup) pair
- Voters may change their vote while the War is `active`
- Vote history is **never deleted** — every change creates a new record (see §11)

---

## 7. Data Model

```sql
-- Voters
voters (
  id              UUID PRIMARY KEY,
  provider        VARCHAR(32) NOT NULL,       -- 'google' | 'microsoft' | 'facebook'
  provider_user_id VARCHAR(256) NOT NULL,
  display_name    VARCHAR(256),
  avatar_url      TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (provider, provider_user_id)
)

-- Wars
wars (
  id              UUID PRIMARY KEY,
  creator_id      UUID REFERENCES voters(id),
  title           VARCHAR(256) NOT NULL,
  category        VARCHAR(64),
  status          VARCHAR(16) NOT NULL DEFAULT 'draft',  -- draft|active|closed
  visibility      VARCHAR(16) NOT NULL DEFAULT 'public', -- public|invite_only
  ends_at         TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now()
)

-- Contestants
contestants (
  id              UUID PRIMARY KEY,
  war_id          UUID REFERENCES wars(id),
  name            VARCHAR(256) NOT NULL,
  bio             TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
)

-- Contestant Images
contestant_images (
  id              UUID PRIMARY KEY,
  contestant_id   UUID REFERENCES contestants(id),
  url             TEXT NOT NULL,
  display_order   INT NOT NULL DEFAULT 0,    -- 0 = primary
  created_at      TIMESTAMPTZ DEFAULT now()
)

-- Matchups (generated on war activation)
matchups (
  id              UUID PRIMARY KEY,
  war_id          UUID REFERENCES wars(id),
  contestant_a_id UUID REFERENCES contestants(id),
  contestant_b_id UUID REFERENCES contestants(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (war_id, contestant_a_id, contestant_b_id)
)

-- War Memberships
war_memberships (
  war_id          UUID REFERENCES wars(id),
  voter_id        UUID REFERENCES voters(id),
  joined_at       TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (war_id, voter_id)
)

-- Votes (append-only audit log)
votes (
  id              UUID PRIMARY KEY,
  matchup_id      UUID REFERENCES matchups(id),
  voter_id        UUID REFERENCES voters(id),
  winner_id       UUID REFERENCES contestants(id),
  created_at      TIMESTAMPTZ DEFAULT now(),
  superseded_by_id UUID REFERENCES votes(id)  -- NULL = current active vote
)
```

**Active vote** for a (voter, matchup) pair is always the record where `superseded_by_id IS NULL`.

---

## 8. API Specification

Base path: `/api/v1`  
All responses: `Content-Type: application/json`  
Authentication: `Authorization: Bearer <jwt>` (where marked 🔒)

---

### 8.1 Auth

#### `GET /auth/{provider}/login`
Redirects to the OAuth provider's authorization URL.

**Path params:** `provider` ∈ `[google, microsoft, facebook]`

---

#### `GET /auth/{provider}/callback`
OAuth redirect target. Exchanges code for tokens, creates or fetches Voter, issues JWT.

**Response `200`:**
```json
{
  "token": "<jwt>",
  "refresh_token": "<refresh_token>",
  "voter": {
    "id": "uuid",
    "display_name": "Jane Doe",
    "avatar_url": "https://..."
  }
}
```

---

#### `POST /auth/refresh`
Exchange a refresh token for a new JWT.

**Body:** `{ "refresh_token": "..." }`  
**Response `200`:** `{ "token": "<new_jwt>" }`

---

#### `DELETE /auth/session` 🔒
Invalidate the current session / refresh token.

**Response `204`:** No content

---

#### `GET /auth/me` 🔒
Return the current authenticated voter's profile.

**Response `200`:**
```json
{
  "id": "uuid",
  "display_name": "Jane Doe",
  "avatar_url": "https://...",
  "provider": "google",
  "created_at": "2026-01-01T00:00:00Z"
}
```

---

### 8.2 Wars

#### `GET /wars`
List wars. Anonymous access permitted for public wars.

**Query params:**
| Param | Type | Description |
|---|---|---|
| `status` | string | Filter by `draft`, `active`, `closed` |
| `category` | string | Filter by category tag |
| `cursor` | string | Pagination cursor |
| `limit` | int | Page size (default 20, max 100) |

**Response `200`:**
```json
{
  "data": [
    {
      "id": "uuid",
      "title": "Miss Universe 2026",
      "category": "Beauty",
      "status": "active",
      "visibility": "public",
      "contestant_count": 5,
      "ends_at": "2026-12-31T23:59:59Z",
      "created_at": "2026-04-01T00:00:00Z"
    }
  ],
  "next_cursor": "..."
}
```

---

#### `POST /wars` 🔒
Create a new War in `draft` status.

**Body:**
```json
{
  "title": "Miss Universe 2026",
  "category": "Beauty",
  "visibility": "public",
  "ends_at": "2026-12-31T23:59:59Z"
}
```

**Response `201`:** Full War object.

---

#### `GET /wars/:warId`
Get War details including contestants. Anonymous access for public wars.

**Response `200`:**
```json
{
  "id": "uuid",
  "title": "Miss Universe 2026",
  "status": "active",
  "visibility": "public",
  "category": "Beauty",
  "ends_at": "...",
  "contestants": [
    {
      "id": "uuid",
      "name": "Contestant A",
      "bio": "...",
      "images": [
        { "id": "uuid", "url": "https://...", "display_order": 0 }
      ]
    }
  ]
}
```

---

#### `PATCH /wars/:warId` 🔒
Update War metadata. Only permitted when `status = draft`. Requester must be War creator.

**Body:** Any subset of `{ title, category, visibility, ends_at }`  
**Response `200`:** Updated War object.  
**Error `403`:** War is not in draft status or requester is not creator.

---

#### `POST /wars/:warId/activate` 🔒
Transition War from `draft` → `active`. Generates all matchup pairings. Requester must be War creator. Requires at least 2 contestants.

**Response `200`:** Updated War object with `status: active`.  
**Error `422`:** Fewer than 2 contestants.

---

#### `POST /wars/:warId/close` 🔒
Transition War from `active` → `closed`. Requester must be War creator.

**Response `200`:** Updated War object with `status: closed`.

---

#### `POST /wars/:warId/join` 🔒
Authenticated voter joins a War (creates WarMembership).

**Response `201`:** `{ "war_id": "...", "voter_id": "...", "joined_at": "..." }`  
**Error `409`:** Voter already joined.

---

### 8.3 Contestants

#### `POST /wars/:warId/contestants` 🔒
Add a contestant to a War in `draft` status.

**Body:** `{ "name": "Contestant A", "bio": "..." }`  
**Response `201`:** Contestant object (no images yet).  
**Error `403`:** War not in draft or requester not creator.

---

#### `PATCH /wars/:warId/contestants/:contestantId` 🔒
Update contestant name or bio. Draft only.

**Response `200`:** Updated Contestant object.

---

#### `DELETE /wars/:warId/contestants/:contestantId` 🔒
Remove a contestant. Draft only.

**Response `204`:** No content.

---

#### `POST /wars/:warId/contestants/:contestantId/images` 🔒
Upload one or more images for a contestant. Draft only. Multipart form data.

**Body:** `multipart/form-data` with one or more `image` fields.  
**Response `201`:**
```json
{
  "images": [
    { "id": "uuid", "url": "https://...", "display_order": 1 }
  ]
}
```

---

#### `PATCH /wars/:warId/contestants/:contestantId/images/:imageId` 🔒
Update image display order (reorder / set as primary). Draft only.

**Body:** `{ "display_order": 0 }`  
**Response `200`:** Updated image object.

---

#### `DELETE /wars/:warId/contestants/:contestantId/images/:imageId` 🔒
Remove an image. Draft only.

**Response `204`:** No content.

---

### 8.4 Matchups & Voting

#### `GET /wars/:warId/matchups/next` 🔒
Return the next unvoted matchup for the authenticated voter in this War. Matchups are served in a randomised order that is stable per voter (seeded shuffle).

**Response `200`:**
```json
{
  "matchup": {
    "id": "uuid",
    "contestant_a": {
      "id": "uuid",
      "name": "Contestant A",
      "images": [{ "url": "https://...", "display_order": 0 }]
    },
    "contestant_b": {
      "id": "uuid",
      "name": "Contestant B",
      "images": [{ "url": "https://...", "display_order": 0 }]
    }
  },
  "progress": {
    "voted": 3,
    "total": 10
  }
}
```

**Response `204`:** No content — voter has completed all matchups.  
**Error `403`:** Voter has not joined this War.

---

#### `POST /wars/:warId/matchups/:matchupId/vote` 🔒
Cast a vote. If the voter has already voted on this matchup, the existing vote is superseded and a new record is created (War must be `active`).

**Body:** `{ "winner_id": "<contestant_uuid>" }`  
**Response `201`:** `{ "vote_id": "uuid", "matchup_id": "...", "winner_id": "...", "created_at": "..." }`  
**Error `403`:** War is closed or voter not joined.  
**Error `422`:** `winner_id` is not a contestant in this matchup.

---

#### `GET /wars/:warId/my-progress` 🔒
Return the authenticated voter's voting progress in a War.

**Response `200`:**
```json
{
  "voted": 7,
  "total": 10,
  "completed": false
}
```

---

### 8.5 Rankings

#### `GET /wars/:warId/rankings`
Return contestants ranked by Win %. Anonymous access permitted for Public Wars.

**Response `200`:**
```json
{
  "war_id": "uuid",
  "status": "active",
  "updated_at": "2026-04-28T12:00:00Z",
  "rankings": [
    {
      "rank": 1,
      "contestant": {
        "id": "uuid",
        "name": "Contestant A",
        "images": [{ "url": "https://...", "display_order": 0 }]
      },
      "wins": 320,
      "total_votes": 400,
      "win_pct": 80.0
    }
  ]
}
```

**Scoring rules (computed by API):**
- `win_pct = wins / total_votes * 100` rounded to 1 decimal place
- Ranked descending by `win_pct`
- Ties broken by `total_votes` descending (more exposure = more meaningful score)
- Contestants with `total_votes = 0` appear at the bottom as unranked

---

## 9. UI Specification

The UI is a **thin client**. All data originates from the API. No ranking, scoring, or matchup logic is implemented in the frontend.

### 9.1 Pages & Views

#### Home / Browse (`/`)
- Lists active Public Wars (calls `GET /wars?status=active`)
- Filter by category
- Each card: War title, category, contestant count, time remaining
- Anonymous users see a "Login to vote" CTA; authenticated users see "Join & Vote"

#### War Detail (`/wars/:id`)
- Shows War title, status, contestant gallery
- Two CTAs: **Vote** (authenticated + joined), **View Rankings**
- If not joined, shows **Join War** button
- All visible to anonymous users for public wars

#### Vote Mode (`/wars/:id/vote`)
- Protected: requires authentication + war membership
- Calls `GET /wars/:id/matchups/next` on load and after each vote
- Shows two contestant cards side by side (primary image, name)
  - Image carousel available if contestant has multiple images
- Voter taps/clicks a card to vote (calls `POST /vote`)
- Progress bar: "7 of 10 matchups"
- On completion (`204` response from `/next`): shows completion screen with link to rankings

#### Rankings View (`/wars/:id/rankings`)
- Calls `GET /wars/:id/rankings`
- Publicly accessible
- Shows ranked list: position, contestant image, name, win %, wins/total
- Anonymous users see "Login to vote" banner
- Poll for updates every 30s while War is `active`

#### My Wars (`/my-wars`) 🔒
- Wars the voter has joined or created
- Quick links to resume voting or view rankings

#### Create War (`/wars/new`) 🔒
- Multi-step form: metadata → add contestants → review → activate
- Image upload per contestant
- Activate button calls `POST /wars/:id/activate`

### 9.2 Auth Flow
- Login page at `/login` with buttons per provider
- On click, redirect to `GET /api/v1/auth/{provider}/login`
- After callback, JWT stored in memory; UI re-renders with authenticated state
- Logout calls `DELETE /auth/session`, clears token

### 9.3 Error States
All error handling is driven by API response codes. The UI maps these to user-facing messages:

| Code | Message |
|---|---|
| `401` | "Please log in to continue" |
| `403` War closed | "This War is locked — no more changes" |
| `403` Not joined | "Join this War to vote" |
| `404` | "This War doesn't exist or has been removed" |
| `422` | "Something went wrong — please try again" |
| `5xx` | "Server error — please try again shortly" |

---

## 10. Scoring Algorithm

**Win Percentage (Win %)**

Computed entirely server-side by the API at query time (not stored).

```
win_pct(contestant) = SUM(votes where winner_id = contestant.id)
                    / SUM(votes where contestant.id IN (matchup.contestant_a_id, matchup.contestant_b_id))
                    * 100
```

- Only **active** votes (where `superseded_by_id IS NULL`) are counted
- Computed across **all voters** in the War
- Rounded to 1 decimal place
- Tie-breaking: higher `total_votes` wins; still tied → alphabetical by name

---

## 11. Vote Integrity & Audit Trail

Votes are **append-only**. The `votes` table is never updated or deleted.

### Change Flow
When a voter changes a vote on matchup M:
1. Find current active vote V1 for (voter, matchup M) where `superseded_by_id IS NULL`
2. Insert new vote V2 with the new `winner_id`
3. Update V1: set `superseded_by_id = V2.id`

The active vote is always `SELECT * FROM votes WHERE matchup_id = ? AND voter_id = ? AND superseded_by_id IS NULL`.

The full history is available for future audit analysis, including:
- Detecting improbably rapid vote changes
- Identifying bulk voting patterns from a single voter
- Correlating vote reversals across voters (coordinated manipulation)

Audit tooling is out of scope for v1 but the data model supports it from day one.

---

## 12. Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| **Web Frontend** | Next.js (React) | SSR for public ranking pages (SEO); CSR for vote mode |
| **Mobile (future)** | React Native or PWA | Consumes identical API |
| **Backend API** | Node.js + Express or Next.js API routes | Stateless, versioned under `/api/v1` |
| **Database** | PostgreSQL | Relational model suits foreign keys and audit trail well |
| **Auth** | NextAuth.js or Auth0 | Handles OAuth provider complexity |
| **Image Storage** | Cloudinary or AWS S3 | Contestant image uploads |
| **Hosting** | Vercel (frontend), Railway / Render (API + DB) | |

---

## 13. Out of Scope (v1)

- Real-time leaderboard streaming (WebSockets / SSE)
- Push notifications (web or mobile)
- War creator moderation (removing voters, resetting individual votes)
- Vote tamper detection analytics (data collected; tooling is future)
- Admin moderation dashboard
- Linking multiple OAuth providers to one voter account
- Paid or promoted Wars
- Weighted votes
- Comments or reactions on contestants
- ELO or Borda count scoring (Win % only for v1)

---

## 14. Gherkin Acceptance Tests

### 14.1 Authentication

```gherkin
Feature: OAuth Authentication

  Scenario: New voter signs in with Google
    Given a user has never signed in before
    When they authenticate via Google OAuth
    Then a new Voter record is created
    And a JWT and refresh token are returned
    And the voter's display name and avatar are populated from Google

  Scenario: Returning voter signs in with Google
    Given a voter has previously signed in with Google
    When they authenticate again via Google OAuth
    Then no new Voter record is created
    And the existing Voter record is returned

  Scenario: Same email, different provider, creates separate voters
    Given voter A has signed in with Google using email "user@example.com"
    When a user signs in with Microsoft using the same email "user@example.com"
    Then a separate Voter record is created
    And the two accounts are not linked

  Scenario: Anonymous user accesses a protected endpoint
    Given a user is not authenticated
    When they call GET /api/v1/auth/me
    Then the response status is 401
```

---

### 14.2 War Management

```gherkin
Feature: War Lifecycle

  Scenario: Creator creates a War in draft
    Given an authenticated voter
    When they POST /api/v1/wars with a valid title and visibility
    Then a War is created with status "draft"
    And the creator_id is set to the authenticated voter

  Scenario: Creator activates a War with enough contestants
    Given a War in "draft" status with 3 contestants
    When the creator POSTs to /api/v1/wars/:id/activate
    Then the War status becomes "active"
    And 3 matchups are generated (n=3 → 3 matchups)

  Scenario: Cannot activate a War with fewer than 2 contestants
    Given a War in "draft" status with 1 contestant
    When the creator POSTs to /api/v1/wars/:id/activate
    Then the response status is 422
    And the War remains in "draft" status

  Scenario: Non-creator cannot activate a War
    Given a War in "draft" status created by Voter A
    When Voter B POSTs to /api/v1/wars/:id/activate
    Then the response status is 403

  Scenario: Cannot edit a War after activation
    Given a War in "active" status
    When the creator PATCHes /api/v1/wars/:id with a new title
    Then the response status is 403
    And the title is unchanged

  Scenario: War auto-closes when end date is reached
    Given an active War with ends_at in the past
    When the system processes the end date
    Then the War status becomes "closed"
```

---

### 14.3 Contestant & Image Management

```gherkin
Feature: Contestant Management

  Scenario: Creator adds a contestant to a draft War
    Given a War in "draft" status
    When the creator POSTs to /api/v1/wars/:id/contestants with a name
    Then a Contestant is created with no images

  Scenario: Creator uploads images to a contestant
    Given a Contestant in a draft War
    When the creator POSTs two images to /contestants/:id/images
    Then both images are stored
    And the first uploaded image has display_order 0 (primary)

  Scenario: Creator reorders contestant images
    Given a Contestant with two images (orders 0 and 1)
    When the creator PATCHes image B to display_order 0
    Then image B becomes the primary image

  Scenario: Cannot upload images to a contestant in an active War
    Given a War in "active" status
    When the creator POSTs an image to a contestant
    Then the response status is 403

  Scenario: Matchup count is correct after activation
    Given a War with 5 contestants
    When the War is activated
    Then exactly 10 matchups are generated
```

---

### 14.4 Voting

```gherkin
Feature: Voting

  Scenario: Voter joins a War and receives first matchup
    Given an active War with 10 matchups
    And an authenticated voter who has joined the War
    When they GET /wars/:id/matchups/next
    Then a matchup is returned with two contestants
    And progress shows "voted: 0, total: 10"

  Scenario: Voter casts a vote
    Given a voter who has not yet voted on matchup M
    When they POST /wars/:id/matchups/:matchupId/vote with a valid winner_id
    Then a Vote record is created with superseded_by_id NULL
    And the next call to /matchups/next returns a different matchup

  Scenario: Voter changes their vote on an active War
    Given a voter who voted Contestant A in matchup M
    When they POST /wars/:id/matchups/:matchupId/vote with winner_id = Contestant B
    Then a new Vote record is created with superseded_by_id NULL
    And the original Vote record has superseded_by_id pointing to the new vote
    And the rankings now count Contestant B's win (not A's) for this matchup

  Scenario: Voter cannot change vote on a closed War
    Given a War in "closed" status
    And a voter who previously voted on matchup M
    When they POST /wars/:id/matchups/:matchupId/vote
    Then the response status is 403

  Scenario: Non-joined voter cannot vote
    Given an active War
    And an authenticated voter who has NOT joined the War
    When they POST a vote
    Then the response status is 403

  Scenario: Voter completes all matchups
    Given a voter who has voted on all 10 matchups in a War
    When they GET /wars/:id/matchups/next
    Then the response status is 204

  Scenario: Anonymous user cannot vote
    Given an active War
    When an unauthenticated request POSTs a vote
    Then the response status is 401
```

---

### 14.5 Rankings

```gherkin
Feature: Rankings

  Scenario: Rankings are accessible to anonymous users on a public War
    Given a public War in "active" status
    When an unauthenticated user GETs /wars/:id/rankings
    Then the response status is 200
    And ranked contestants are returned

  Scenario: Rankings reflect only active (non-superseded) votes
    Given matchup M where Voter X originally voted for Contestant A
    And Voter X later changed their vote to Contestant B
    When GET /wars/:id/rankings is called
    Then Contestant B receives the win for that matchup
    And Contestant A does not receive the win for that matchup

  Scenario: Win percentage is calculated correctly
    Given Contestant A appears in 4 matchups
    And across all voters Contestant A received 300 wins from 400 total votes
    When GET /wars/:id/rankings is called
    Then Contestant A's win_pct is 75.0

  Scenario: Tie-breaking by total vote volume
    Given Contestant A has win_pct 60.0 with 100 total votes
    And Contestant B has win_pct 60.0 with 80 total votes
    When GET /wars/:id/rankings is called
    Then Contestant A ranks above Contestant B

  Scenario: Contestants with zero votes are unranked
    Given a War where Contestant C has received no votes
    When GET /wars/:id/rankings is called
    Then Contestant C appears at the bottom of the list as unranked

  Scenario: Rankings cannot be viewed anonymously on an invite-only War
    Given an invite_only War
    When an unauthenticated user GETs /wars/:id/rankings
    Then the response status is 401
```

---

*End of Specification*
