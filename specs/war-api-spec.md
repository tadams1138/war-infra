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
9. [Vote Integrity, Abuse Prevention & Audit Trail](#9-vote-integrity-abuse-prevention--audit-trail)
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
- **Immutable votes.** The `votes` table is INSERT-only. Rows are never updated or deleted, and a voter's decision on a pair is final (see §9).
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
│   ├── rankings/       # Win-count leaderboard
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
- Apple
- Facebook
- Microsoft Live
- Twitter / X

Extensible to GitHub, Discord, etc. without schema changes.

### Identity Rules
- Each (provider, provider_user_id) pair maps to exactly one `voters` record
- Voters may not link multiple OAuth providers to one account
- First login auto-creates a Voter; subsequent logins return the existing record

### Session Tokens
- Successful OAuth callback issues a signed **JWT** (1h expiry) and a **refresh token** (30d)
- All protected endpoints require `Authorization: Bearer <jwt>`
- Refresh tokens are stored server-side (hashed, never in plaintext) for revocation — see §4.1

### 4.1 Token Delivery

**No token is ever placed in a URL.** The OAuth callback sets the refresh token as an `HttpOnly` cookie and redirects with no credential in the path, query, or fragment. The SPA then exchanges the cookie for its first JWT:

```
1. Browser    → GET /api/v1/auth/{provider}/login
                API sets a signed `oauth_state` cookie, redirects to the provider

2. Provider   → GET /api/v1/auth/{provider}/callback?code=...&state=...
                API validates state, exchanges the code, upserts the Voter,
                sets the refresh-token cookie, and redirects to /auth/callback
                — carrying no token of any kind

3. SPA        → POST /api/v1/auth/refresh   (cookie sent automatically)
                Response body contains the JWT; SPA holds it in memory only
```

A URL fragment is not sent to servers, but it still lands in browser history, and any script on the page can read `location.hash`. Since the httpOnly cookie already exists at that moment, one extra request removes the exposure entirely.

**Refresh cookie attributes:** `HttpOnly; Secure; SameSite=Lax; Path=/api/v1/auth`

`SameSite=Lax` is what makes `POST /auth/refresh` safe from CSRF — browsers omit `Lax` cookies on cross-site POST, so a hostile page cannot mint a JWT. The API additionally rejects the request if `Origin` is not a registered UI origin. `Lax` rather than `Strict` because step 2 is a cross-site top-level navigation from the provider, which `Strict` would block.

### 4.2 Refresh Token Rotation

Every call to `/auth/refresh` **invalidates the presented token and issues a new one**. Tokens are grouped into a *family* per login session.

- Each token is single-use; using it marks it `used_at` and issues a successor in the same family
- Presenting an **already-used** token means the token leaked and both parties now hold it. The entire family is revoked immediately and the response is `401` — the legitimate voter is logged out and must re-authenticate
- Presenting a revoked or expired token returns `401`
- `DELETE /auth/session` revokes the whole family

Reuse detection is the reason rotation is worth its complexity: without it, a stolen 30-day refresh token grants a year-round silent session with no signal that anything is wrong.

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

#### Effective Status

`ends_at` is enforced **lazily on every read and write**. A War is treated as closed the instant `ends_at` passes, regardless of what the `status` column currently holds:

```
effective_status(war) = 'closed'  if war.ends_at IS NOT NULL AND war.ends_at <= now()
                      = war.status  otherwise
```

All endpoints evaluate `effective_status`, never the raw column. A vote cast one second after `ends_at` returns `403`, and `GET /wars/:id` reports `"status": "closed"`, even though the stored value is still `active`.

A nightly scheduled task (`war-infra-spec.md` §12) converges the stored `status` so that list queries can filter on an indexed column rather than a computed expression. That task is **housekeeping only** — correctness never depends on it having run. If it fails for a week, voting behaviour stays correct and only query efficiency and reporting freshness degrade.

### Contestant
A participant in a War. Has a name, optional bio, media appropriate to the War's `media_mode`, and attributes defined by the War's `contestant_schema`.

### Contestant Schema

Different campaigns describe their contestants with entirely different facts. A pageant needs country, age, and height; a presidential primary needs party, state, and office held. These are not two layouts of the same data — they are different fields, and a fixed `name` + `bio` model has nowhere to put either set.

A War therefore declares an **ordered list of typed fields** at creation, and each contestant supplies values for them:

```json
"contestant_schema": [
  { "key": "country", "label": "Country", "type": "string" },
  { "key": "age",     "label": "Age",     "type": "number" },
  { "key": "height",  "label": "Height",  "type": "string" }
]
```

```json
"attributes": { "country": "Brazil", "age": 24, "height": "175cm" }
```

A presidential primary declares `party`, `state`, and `office` instead. **The same code renders both** — no per-campaign templates, no layout variants, no branching.

| Rule | Value |
|---|---|
| Maximum fields per War | 12 |
| `key` format | `^[a-z][a-z0-9_]{0,31}$` |
| `label` length | ≤ 64 characters |
| `type` | `string` \| `number` \| `text` \| `url` \| `date` |
| Editable | Draft only, like all other War configuration |

**All values render as text.** They are never interpreted as markup. `url` is the sole exception: it renders as a link, and the API rejects any value whose scheme is not `http` or `https` at write time — so a `javascript:` URL never reaches storage, let alone a client.

Fields are optional: a contestant may omit any key. Order comes from the schema, not from the contestant.

This is deliberately *not* a presentation mechanism. It changes what data a contestant carries, not how it looks. Radically different presentation is what custom UIs are for (`war-ui-custom-spec.md` §1).

### Media Mode

A War declares at creation whether its contestants are presented as **images** or as **embedded video**. The mode is fixed for the War's lifetime and applies to every contestant in it.

| Mode | Contestant media | Presentation |
|---|---|---|
| `image` (default) | 1–10 images, ordered; `display_order = 0` is primary | Two cards side by side, each swipeable through that contestant's images |
| `video` | exactly one embedded video | Two players; the left video plays, then the right (§11.3) |

**Mixed media within a War is not permitted.** A matchup pairing a video against a photograph has no coherent presentation — there is no way to play one and show the other that treats both contestants equally. Activation fails with `422` if any contestant's media does not match the War's mode.

Mode affects presentation only. Matchup generation, pair selection, side randomisation, vote recording, and ranking are identical in both modes.

### Matchup
An **unordered** head-to-head pairing of two contestants. For `n` contestants: `n(n-1)/2` matchups. Generated on War activation. Immutable after generation.

A pairing has no direction: **A vs B and B vs A are the same matchup**. This is enforced structurally by storing contestants in canonical order (`contestant_a_id < contestant_b_id`, §6), so a mirrored duplicate row cannot exist and a voter cannot accumulate one vote for each side of the same pair.

Which contestant is *displayed* on which side is a separate, per-voter presentation concern (§7.4) and carries no meaning.

### Vote
A voter's pick in a Matchup. **Immutable and final** — one vote per voter per matchup, enforced by a unique constraint. There is no supersede mechanism and no way to change a decided vote (§9).

Every contestant carries two denormalised counters, maintained in the same transaction as the vote insert:

| Counter | Meaning |
|---|---|
| `win_count` | Votes where this contestant was the winner |
| `appearance_count` | Votes cast on any matchup containing this contestant |

Because votes are immutable, both counters increase monotonically and never require recomputation. They drive both pair selection (§7.4) and rankings (§8).

---

## 6. Data Model

```sql
voters (
  id               UUID PRIMARY KEY,
  provider         VARCHAR(32) NOT NULL,       -- 'google' | 'apple' | 'facebook' | 'microsoft' | 'twitter'
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
  media_mode       VARCHAR(8) NOT NULL DEFAULT 'image',     -- 'image' | 'video' (§5)
  contestant_schema JSONB NOT NULL DEFAULT '[]',            -- ordered field definitions (§5)
  ends_at          TIMESTAMPTZ,
  ui_slug          VARCHAR(64),                            -- optional custom UI
  created_at       TIMESTAMPTZ DEFAULT now()
)

contestants (
  id               UUID PRIMARY KEY,
  war_id           UUID REFERENCES wars(id),
  name             VARCHAR(256) NOT NULL,
  bio              TEXT,
  attributes       JSONB NOT NULL DEFAULT '{}',   -- keyed by the War's contestant_schema (§5)
  win_count        INT NOT NULL DEFAULT 0,        -- votes won (§5)
  appearance_count INT NOT NULL DEFAULT 0,        -- votes cast on pairs containing this contestant
  created_at       TIMESTAMPTZ DEFAULT now()
)

-- Refresh token families, rotated on every use (§4.2)
refresh_tokens (
  id               UUID PRIMARY KEY,
  voter_id         UUID REFERENCES voters(id),
  family_id        UUID NOT NULL,                -- one family per login session
  token_hash       TEXT NOT NULL,                -- SHA-256; plaintext is never stored
  expires_at       TIMESTAMPTZ NOT NULL,
  used_at          TIMESTAMPTZ,                  -- set on rotation; reuse ⇒ revoke family
  revoked_at       TIMESTAMPTZ,
  created_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (token_hash)
)

-- A contestant's media: images or one embedded video, per the War's media_mode (§5)
contestant_media (
  id                UUID PRIMARY KEY,
  contestant_id     UUID REFERENCES contestants(id),
  kind              VARCHAR(8) NOT NULL,         -- 'image' | 'video'
  display_order     INT NOT NULL DEFAULT 0,      -- 0 is primary

  -- kind = 'image' (§11.1)
  storage_key       TEXT,                        -- base key; variant URLs derived
  original_ext      VARCHAR(8),
  width             INT,                         -- source dimensions, for aspect ratio
  height            INT,

  -- kind = 'video' (§11.3) — we store an identity, never a raw URL
  provider          VARCHAR(16),                 -- 'youtube' | 'vimeo'
  provider_video_id VARCHAR(64),
  start_seconds     INT,                         -- optional clip window
  end_seconds       INT,
  duration_seconds  INT NOT NULL DEFAULT 0,      -- effective play length, validated on add
  poster_url        TEXT,                        -- from the provider's oEmbed response
  title             TEXT,

  created_at        TIMESTAMPTZ DEFAULT now(),

  CHECK (
    (kind = 'image' AND storage_key IS NOT NULL)
    OR
    (kind = 'video' AND provider IS NOT NULL AND provider_video_id IS NOT NULL)
  )
)

matchups (
  id               UUID PRIMARY KEY,
  war_id           UUID REFERENCES wars(id),
  contestant_a_id  UUID REFERENCES contestants(id),
  contestant_b_id  UUID REFERENCES contestants(id),
  created_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (war_id, contestant_a_id, contestant_b_id),
  CHECK (contestant_a_id < contestant_b_id)       -- canonical order: A vs B == B vs A
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
  presented_left_id UUID REFERENCES contestants(id) NOT NULL,  -- side shown (§7.4)
  created_at       TIMESTAMPTZ DEFAULT now(),
  UNIQUE (matchup_id, voter_id)                   -- one final vote per voter per pair (§9)
)

-- Indexes
CREATE INDEX ON votes (voter_id, matchup_id);     -- unvoted-pair lookup (§7.4)
CREATE INDEX ON refresh_tokens (family_id);       -- family revocation on reuse (§4.2)
CREATE INDEX ON contestant_media (contestant_id, display_order);
CREATE INDEX ON matchups (war_id);
CREATE INDEX ON contestants (war_id);
CREATE INDEX ON wars (status, visibility);        -- browse/filter (§7.2)
CREATE INDEX ON wars (ends_at) WHERE ends_at IS NOT NULL;  -- expiry sweep (§7.7)

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
**Contract:** published as OpenAPI 3.1 at `GET /api/v1/openapi.json`, generated from route schemas (§11.2)

### Media Representation

Wherever a contestant appears in a response it carries a `media` array, ordered by `display_order`. Its contents depend on the War's `media_mode` (§5). Clients render what they are given and never construct media URLs themselves.

**`kind: "image"`** — clients build a `srcset` from `variants`:

```json
{
  "kind": "image",
  "id": "uuid",
  "display_order": 0,
  "aspect_ratio": 0.75,
  "variants": [
    { "width": 400,  "url": "https://war.tmad.dev/media/contestants/{cid}/{mid}-400.webp"  },
    { "width": 800,  "url": "https://war.tmad.dev/media/contestants/{cid}/{mid}-800.webp"  },
    { "width": 1600, "url": "https://war.tmad.dev/media/contestants/{cid}/{mid}-1600.webp" }
  ]
}
```

A variant is omitted when the source was narrower than that width — images are never upscaled (§11.1).

**`kind: "video"`** — clients embed via the provider's player API (§11.3):

```json
{
  "kind": "video",
  "id": "uuid",
  "display_order": 0,
  "provider": "youtube",
  "video_id": "dQw4w9WgXcQ",
  "start_seconds": 0,
  "end_seconds": 30,
  "duration_seconds": 30,
  "title": "...",
  "poster_url": "https://i.ytimg.com/vi/.../hqdefault.jpg",
  "aspect_ratio": 1.778
}
```

The API returns a provider and an id, **never an embed URL**. The client constructs the player URL from its own allow-list, so a compromised or mistaken database value cannot cause an arbitrary third-party frame to load.

In responses below this array is abbreviated as `media: [ … ]`.

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
| `POST` | `/wars/:id/contestants/:cId/images` | 🔒 | Upload images (draft only, multipart; `image` mode) |
| `POST` | `/wars/:id/contestants/:cId/video` | 🔒 | Attach embedded video (draft only; `video` mode) |
| `PATCH` | `/wars/:id/contestants/:cId/media/:mId` | 🔒 | Reorder / set primary (draft only) |
| `DELETE` | `/wars/:id/contestants/:cId/media/:mId` | 🔒 | Remove media item (draft only) |

**Contestant attributes.** `POST` and `PATCH` accept an `attributes` object validated against the War's `contestant_schema` (§5):

- A key not present in the schema → `422`
- A value whose type does not match its declared `type` → `422`
- `string` ≤ 256 chars, `text` ≤ 2000, `url` ≤ 512 and scheme `http`/`https` only
- Omitted keys are permitted; every field is optional

Responses return attributes **resolved against the schema**, so clients need not fetch it separately and cannot render fields out of order:

```json
"attributes": [
  { "key": "country", "label": "Country", "type": "string", "value": "Brazil" },
  { "key": "age",     "label": "Age",     "type": "number", "value": 24 }
]
```

**`POST /images` rules:**
- Rejected with `409` if the War's `media_mode` is `video`
- Maximum **10 images per contestant** → else `422`
- New images append at the next `display_order`; `PATCH` reorders

**`POST /video` body:** `{ "url": "...", "start_seconds": 0, "end_seconds": 30 }`

**Rules:**
- Rejected with `409` if the War's `media_mode` is `image`, or if the contestant already has a video
- `url` must belong to a supported provider → else `422` (§11.3)
- Effective duration (`end_seconds − start_seconds`, or the full video) must be ≤ **60 seconds** → else `422`
- The API resolves the URL through the provider's oEmbed endpoint at add time and stores the provider, video id, poster, and title. A video that is private, deleted, or not embeddable is rejected with `422` **at add time**, not discovered mid-War

---

### 7.4 Matchups & Voting

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/wars/:id/matchups/next` | 🔒 | Next unvoted matchup for this voter |
| `POST` | `/wars/:id/matchups/:mId/vote` | 🔒 | Cast vote (final; see §9) |
| `GET` | `/wars/:id/my-progress` | 🔒 | Voter's vote count vs total |

Every voter is served **every pair** in the War, in randomised order, and is never served a pair they have already voted on. When all pairs are voted, `/matchups/next` returns `204`.

A voter is under no obligation to finish. Unvoted pairs are simply absent from the data — abandoning midway is expected, not penalised, and produces no record of any kind (§9.2).

#### Pair Selection

`/matchups/next` returns the voter's unvoted pair whose two contestants have the **lowest combined `appearance_count`**, with ties broken by a per-voter deterministic shuffle:

```sql
SELECT m.*
FROM matchups m
JOIN contestants ca ON ca.id = m.contestant_a_id
JOIN contestants cb ON cb.id = m.contestant_b_id
WHERE m.war_id = :war_id
  AND NOT EXISTS (
    SELECT 1 FROM votes v
    WHERE v.matchup_id = m.id AND v.voter_id = :voter_id
  )
ORDER BY (ca.appearance_count + cb.appearance_count) ASC,
         md5(m.id::text || :voter_id::text)
LIMIT 1
```

This keeps every contestant's `appearance_count` near-equal across the War, which is what makes raw win counts a correct ranking (§8). Without it, an over-shown contestant accumulates wins purely from exposure.

The `md5(matchup_id || voter_id)` term is a **stable** shuffle: the order is random across voters and across pairs, but identical every time for a given voter, so the sequence survives reconnects and device changes. It never uses `random()`, which would reshuffle on every request.

#### Side Randomisation

Which contestant appears on the left is decided by the API, not the client, and is derived from the same stable hash so a page refresh does not swap the cards:

```
left = contestant_a  if  hash(matchup_id || voter_id || 'side') is even
     = contestant_b  otherwise
```

The presented side is recorded on the vote (`presented_left_id`). Position bias is real and measurable in pairwise voting; recording the side costs one column and is the only way the audit trail in §9.3 can ever detect it. Clients must render the order the API returns and must not shuffle it themselves.

**`GET /matchups/next` response `200`:**
```json
{
  "matchup": {
    "id": "uuid",
    "left":  { "id": "uuid", "name": "...", "media": [ … ] },
    "right": { "id": "uuid", "name": "...", "media": [ … ] }
  },
  "progress": { "voted": 3, "total": 253 }
}
```

`total` is the full pair count for the War (`n(n-1)/2`), not a per-voter sample.

**`204`** when the voter has voted on every pair.

#### Prefetching the next matchup

The response also carries a `prefetch` block naming the media of the matchup that **would be served next**:

```json
"prefetch": {
  "matchup_id": "uuid",
  "media": [ … ]
}
```

Clients warm those URLs while the voter is deciding the current pair. Without it every vote is followed by a visible blank while the next images download — at roughly 3 seconds per decision, a 500ms load is a sixth of the interaction, and it lands precisely when the voter is waiting to act.

`prefetch` is advisory. Because pair selection depends on `appearance_count`, which other voters are changing concurrently, the prefetched matchup may not be the one actually served. A miss costs a wasted request, never a wrong pair — the served matchup is always whatever `/matchups/next` returns at the time. It is omitted when the voter has one pair or fewer remaining.

In `video` mode `prefetch` carries the poster image only. Prefetching third-party video would mean loading a second player for a matchup that may never be shown.

**`POST /vote` body:** `{ "winner_id": "<uuid>" }`  
**Rules:**
- `winner_id` must be a contestant in this matchup → else `422`
- War must be `active` by effective status (§5) → else `403`
- Voter must have joined → else `403`
- **A vote is final.** If this voter already voted on this matchup:
  - same `winner_id` → `200` (treated as a retry; no new row, no counter change)
  - different `winner_id` → `409` (rejected; no state change)

The same-winner case makes the endpoint idempotent without an idempotency key, so a client retrying after a dropped connection succeeds rather than erroring. A genuine change of mind is refused.

The vote insert and both counter increments (`win_count` on the winner, `appearance_count` on both contestants) occur in **one transaction**.

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
      "contestant": { "id": "uuid", "name": "...", "media": [ … ] },
      "wins": 320,
      "appearances": 400
    }
  ]
}
```

`appearances` is shown for transparency — it lets a viewer confirm contestants have been shown comparably often, which is the assumption the ranking rests on (§8).

**Caching.** This endpoint sets `Cache-Control: public, max-age=30`, matching the UI's 30-second poll interval (`war-ui-default-spec.md` §6). Thousands of concurrent viewers collapse to roughly one origin query per 30 seconds per edge location. Rankings for `invite_only` Wars set `Cache-Control: private, max-age=30` so they are never stored at a shared cache.

---

### 7.6 Custom UI Registry

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/ui-registry` | — | List registered UI slugs |
| `GET` | `/ui-registry/:slug` | — | Resolve slug to static base path |

See §10 for full detail.

---

### 7.7 Internal Endpoints

Endpoints under `/api/v1/internal/*` are invoked by the scheduler (`war-infra-spec.md` §12), never by clients. They accept no user JWT and are blocked at the edge for all other callers.

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/internal/close-expired-wars` | 🔑 | Set `status = 'closed'` for Wars past `ends_at` |

**🔑 Auth:** `X-Internal-Token` header matching the `INTERNAL_TASK_TOKEN` secret. Any other value, or its absence, returns `401`.

**`POST /internal/close-expired-wars`:**

```sql
UPDATE wars SET status = 'closed'
WHERE status = 'active' AND ends_at IS NOT NULL AND ends_at <= now()
```

**Response `200`:** `{ "closed": 4 }`

**Rules:**
- Idempotent — safe to run repeatedly, concurrently, and after arbitrary delay. A re-run with nothing newly expired affects zero rows and still returns `200`.
- Changes no observable behaviour, because §5 already treats these Wars as closed. It only materialises the stored value.
- Excluded from any public API documentation or generated client.

---

## 8. Scoring Algorithm

Contestants are ranked by **raw win count**, descending.

```
score(c) = c.win_count
```

- Ties broken by `appearance_count` **ascending** (same wins from fewer showings ranks higher), then alphabetically by name
- Contestants with `appearance_count = 0` are listed last as unranked, with `rank: null`
- Read directly from the counters in §5 — no aggregate scan over `votes`

### 8.1 Why raw wins, and what it depends on

Every contestant appears in exactly `n − 1` pairs. If every voter voted on every pair, every contestant would have an identical `appearance_count`, and ranking by win count, by win percentage, or by any confidence-adjusted variant would produce the **identical order**. Percentages would be wins divided by a constant.

Voters abandon midway, though, and rankings are displayed while a War is still active — so at any moment the data is partial. Partial data is not in itself a problem: because pair order is randomised, every contestant has equal *expected* exposure, so raw win count is unbiased.

The risk is variance, not bias. In a sparse early War, one contestant may be shown 30 times and another 3 times by luck alone, and the over-shown contestant accumulates more wins for no merit.

**This is corrected at selection time, not display time.** The exposure-balanced ordering in §7.4 keeps `appearance_count` near-equal across contestants, which restores the equal-denominator condition that makes raw wins exact. The alternative — leaving selection random and correcting in the leaderboard with win percentages or a confidence bound — was rejected: percentages let a 3-for-3 contestant outrank a 320-of-400 one, and a confidence-adjusted sort displays a number that isn't the sort key, which reads as a bug.

Ranking therefore stays a plain, explainable count of head-to-heads won, and the correction lives where it cannot be seen.

**Invariant.** `appearance_count` should stay tightly clustered across a War's contestants. A widening spread means pair selection is not balancing and the ranking's core assumption is weakening — worth surfacing in monitoring before it distorts results.

---

## 9. Vote Integrity, Abuse Prevention & Audit Trail

### 9.1 Votes are immutable

The `votes` table is **INSERT-only**. No row is ever updated or deleted, and there is no supersede mechanism.

A voter gets exactly one vote per pair, enforced by `UNIQUE (matchup_id, voter_id)`. Three mechanisms together guarantee a voter cannot contribute conflicting votes on the same pairing:

| Mechanism | Prevents |
|---|---|
| `CHECK (contestant_a_id < contestant_b_id)` | A vs B and B vs A existing as separate matchups |
| `UNIQUE (matchup_id, voter_id)` | Two votes by one voter on the same matchup |
| `/matchups/next` excludes voted pairs | A voter being offered a decided pair again |

The first is the important one. It makes the failure mode structurally impossible rather than merely guarded against: since a mirrored pairing cannot exist as a row, a voter cannot pick A in "A vs B" and later pick B in "B vs A" and leave both contestants with one win.

A second vote attempt with the **same** `winner_id` returns `200` and changes nothing — this is how a retry after a dropped connection is absorbed. A second attempt with a **different** `winner_id` returns `409` and changes nothing.

### 9.2 Non-votes are not recorded

A pair the voter never decided leaves **no trace** — no skip record, no abstention, no timestamp. A voter who loses connectivity, closes the tab, or simply stops is indistinguishable from one who never reached that pair, and neither affects any contestant's counters.

There is consequently no "skip" action in the API. The only way to leave a pair undecided is to not vote on it.

### 9.3 Audit trail

Each vote row retains `voter_id`, `matchup_id`, `winner_id`, `presented_left_id`, and `created_at`. Because votes are immutable, this is a complete and tamper-evident record of every decision made.

`presented_left_id` exists specifically to make **position bias** measurable: if winners correlate with the side they were displayed on, the ranking is picking up a UI artefact rather than preference. That signal is unrecoverable if the client shuffles sides, which is why §7.4 places the decision in the API.

Retained for future audit tooling (coordinated voting patterns, timing anomalies, position bias). Tooling itself remains out of scope for v1.

### 9.4 Rate Limiting

A pairwise voting platform is precisely the kind of thing people will script. The audit trail in §9.3 lets abuse be *detected* after the fact; rate limiting is what makes it expensive up front.

Limits are enforced in **two layers**. The edge (`war-infra-spec.md` §13.1) sheds volumetric abuse before it reaches the origin; the API enforces per-identity limits the edge cannot see, because the edge does not decode JWTs.

| Scope | Limit | Key | Response |
|---|---|---|---|
| Vote casting | 60 / minute | `voter_id` | `429` + `Retry-After` |
| Vote casting, sustained | 2,000 / day | `voter_id` | `429` |
| OAuth login start | 10 / minute | client IP | `429` |
| Token refresh | 30 / minute | client IP | `429` |
| War creation | 10 / hour | `voter_id` | `429` |
| Image upload | 100 / hour | `voter_id` | `429` |

**Keyed by `voter_id`, not IP, for authenticated endpoints.** IP-keyed limits punish shared networks — a school or office voting in the same War would throttle each other — while barely inconveniencing an attacker with a proxy pool. Identity is the meaningful unit here, and every voting endpoint already requires a JWT.

The 60/minute vote limit sits well above human pace. At the ~3 seconds per decision the UX implies, a fast voter reaches roughly 20/minute; the limit only bites on automation.

Counters are held in-process. With fixed instance counts and no autoscaling (`war-infra-spec.md` §17), effective limits scale with instance count — acceptable at v1 scale, and the reason the ceiling is set conservatively. A shared store (Redis or equivalent) becomes necessary before autoscaling is enabled.

`429` responses always carry `Retry-After`. Clients surface this as a wait, never as a failure (`war-ui-default-spec.md` §8).

---

## 10. Custom UI Registration

Each custom War UI is a separately built static bundle — see [`war-ui-custom-spec.md`](war-ui-custom-spec.md) for the template contract those bundles must satisfy. **All custom UIs are hosted in one shared object storage bucket behind a single CDN origin**, keyed by slug prefix — there is no bucket, origin, or routing rule per slug (see `war-infra-spec.md` §5.5).

```
war-ui-custom-{env}/
├── miss-universe-2026/index.html
└── best-pizza-nyc/index.html
```

Because layout is uniform, `static_base_path` is derived, not configured — it is always `/ui/{slug}/`. The column is retained so the mapping stays explicit and a future layout change does not require a migration of routing behaviour.

Registering a slug is therefore a **database row plus a file upload**. It provisions nothing: no bucket, no origin, no routing rule, no redeploy. The API's registry is the only place a slug is declared.

When a War has `ui_slug` set, the routing layer serves that slug's bundle for the War's URLs (see `war-infra-spec.md` §6).

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
| Component | Choice | Why this one |
|---|---|---|
| Runtime | Node.js 22 (TypeScript) | |
| Framework | **Fastify** | JSON Schema validation on every route, and §7's OpenAPI document generates from those same schemas — one definition, not three |
| Database | PostgreSQL | |
| Query builder | **Kysely** | §12 mandates hand-written SQL migrations with a `schema_migrations` table. Prisma Migrate wants to own the schema and would fight that; Kysely types queries without owning migrations |
| Migrations | `node-pg-migrate` | Plain SQL files, ordered, with the tracking table §12 requires |
| OAuth | `openid-client` + provider SDKs | Passport's session-oriented middleware model fits poorly with the stateless JWT flow in §4 |
| JWT | `jose` | |
| Image processing | **`sharp`** | Variant generation and EXIF stripping on upload (§11.1) |
| Object storage | `@aws-sdk/client-s3` against an S3-compatible endpoint | Provider per `war-infra-spec.md` §14 |
| Rate limiting | `@fastify/rate-limit` | Per-voter limits complementing the edge rules (§9.4) |
| Testing | Vitest + Supertest + **Testcontainers** | Integration tests run against a real PostgreSQL, not a mock or shared test DB |

### 11.1 Image Processing

Uploaded images are **never served as uploaded**. On upload the API:

1. Validates type and size (≤ 10MB; JPEG, PNG, WebP)
2. Re-encodes to WebP at three widths — **400, 800, 1600** — preserving aspect ratio and never upscaling
3. **Strips all EXIF metadata**, which routinely carries GPS coordinates and device identifiers from phone photos
4. Writes variants to the public media prefix and the original to a private prefix
5. Records the storage key; variant URLs are derived by convention

```
war-media-{env}/
├── contestants/{contestant_id}/{image_id}-400.webp     (public)
├── contestants/{contestant_id}/{image_id}-800.webp     (public)
├── contestants/{contestant_id}/{image_id}-1600.webp    (public)
└── originals/{contestant_id}/{image_id}.{ext}          (private, never served)
```

Originals are retained so variant widths can be changed later without re-uploading every image. They are never public-read and are not served through the edge.

Processing is **synchronous** within the upload request. A 10MB source produces three variants in well under a second, and there is no queue primitive in the v1 infrastructure (`war-infra-spec.md` §18.2) to make it asynchronous. Bulk contestant uploads happen in draft mode where latency is tolerable.

**Why this matters.** Serving a 10MB original to a phone showing two cards side by side is simultaneously the worst mobile experience and the largest line on the egress bill — image delivery is the dominant traffic driver for the whole platform (`war-infra-spec.md` §16). A 400px WebP is typically 20–40KB, a 100×+ reduction over an unprocessed upload.

### 11.3 Embedded Video

In `video` mode a contestant is represented by one short video hosted **elsewhere**. The platform stores a reference and never stores, transcodes, or serves video bytes.

#### Supported providers

| Provider | Player API | Embed origin |
|---|---|---|
| YouTube | IFrame Player API | `https://www.youtube-nocookie.com` |
| Vimeo | Player.js | `https://player.vimeo.com` |

The allow-list is deliberately short. Both providers expose a JavaScript player with a reliable **playback-ended event**, which the sequential playback in `war-ui-default-spec.md` §6 depends on. An arbitrary URL in an `<iframe>` gives no such event, and embedding arbitrary third-party origins is a security exposure with no upside here.

YouTube is embedded through `youtube-nocookie.com`, which suppresses tracking cookies for viewers who never press play.

#### Validation at add time

`POST /video` resolves the submitted URL before storing anything:

1. Parse the URL against the provider allow-list; extract the video id → `422` if unrecognised
2. Call the provider's **oEmbed** endpoint. A non-200 means the video is private, deleted, or has embedding disabled → `422` with a message naming the cause
3. Store `provider`, `provider_video_id`, `poster_url`, `title`, and the clip window — **never the submitted URL**
4. Compute and store `duration_seconds`; reject over 60 seconds

Validating at add time rather than at play time is the point: a creator finds out their video cannot be embedded while still in draft, not after voters hit a dead player mid-War.

#### Duration limits and why they matter

| Limit | Value |
|---|---|
| Maximum effective duration | 60 seconds |
| Recommended | ≤ 20 seconds |

Video changes the economics of the whole platform. An image matchup takes about 3 seconds to decide; a video matchup takes **twice the video length**, because both must play. At 20 seconds each that is ~40 seconds per matchup:

| Contestants | Pairs | Image mode | Video mode @ 20s |
|---|---|---|---|
| 12 | 66 | ~3 min | ~44 min |
| 23 | 253 | ~13 min | ~2.8 hours |
| 90 | 4,005 | ~3.3 hours | ~44 hours |

Partial completion is already the expected outcome (§7.4), so this does not break anything — but it does mean a video War gathers votes **an order of magnitude more slowly** per voter. Two consequences:

- Exposure-balanced pair selection (§7.4) matters far more here, because far fewer pairs get decided
- Video Wars should be created with few contestants. The API does not enforce a lower cap, but creation UI should steer toward it

#### Clip windows

`start_seconds` / `end_seconds` let a creator point at a segment of a longer video rather than requiring a purpose-cut upload. Both providers support start/end parameters natively, so the clip is enforced by the player.

#### Availability is not guaranteed

A third-party video can be deleted or made private after it was validated. The platform cannot prevent this. When a player reports the video is unavailable, the client shows an unavailable state **and still allows the vote** (`war-ui-default-spec.md` §6) — blocking the vote would let one broken third-party link stall every matchup that contestant appears in.

### 11.2 OpenAPI Contract

The API publishes an OpenAPI 3.1 document at `GET /api/v1/openapi.json`, generated from the Fastify route schemas — it is never hand-maintained, so it cannot drift from the implementation.

This document is the **contract between the three repos**. `war-ui-default` generates its typed client from it (`war-ui-default-spec.md` §5) rather than hand-writing request and response types. With three independently deployed repos and no shared package, contract drift is the highest-probability integration failure, and generation is what removes it.

Endpoints under `/api/v1/internal/*` (§7.7) are excluded from the published document.

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
- Changing a vote once cast (votes are final — §9.1)
- Asynchronous image processing (synchronous on upload — §11.1)
- Distributed rate-limit counters (in-process only — §9.4)
- Linking multiple OAuth providers to one voter account
- ELO or Borda count scoring, and win-percentage or confidence-adjusted ranking (§8.1)

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

  Scenario: No token is placed in the redirect URL
    Given a user completing OAuth with any provider
    When the callback redirects them back to the SPA
    Then the redirect location contains no token in its path, query, or fragment
    And the refresh token is set as an HttpOnly cookie

  Scenario: The SPA obtains its first JWT by exchanging the cookie
    Given a refresh cookie set by a completed OAuth callback
    When the SPA POSTs to /api/v1/auth/refresh
    Then a JWT is returned in the response body

  Scenario: Refresh rotates the token
    Given a valid refresh token
    When it is exchanged at /auth/refresh
    Then a new refresh token is issued
    And the presented token is marked used

  Scenario: Reusing a rotated refresh token revokes the family
    Given a refresh token that has already been exchanged once
    When it is presented again
    Then the response status is 401
    And every token in its family is revoked
    And the voter must re-authenticate

  Scenario: Refresh rejects a cross-origin caller
    Given a valid refresh cookie
    When /auth/refresh is called with an unregistered Origin header
    Then the response status is 403

  Scenario: Logout revokes the whole family
    Given an authenticated voter
    When they call DELETE /auth/session
    Then their refresh token family is revoked
    And a subsequent refresh returns 401
```

### Images

```gherkin
Feature: Image Processing

  Scenario: Uploaded images are re-encoded into variants
    Given a 10MB JPEG uploaded for a contestant
    When the upload completes
    Then WebP variants are stored at 400, 800, and 1600 pixels wide
    And the original is retained in a private prefix

  Scenario: EXIF metadata is stripped
    Given an uploaded photo containing GPS coordinates in its EXIF data
    When the variants are generated
    Then no EXIF metadata is present in any variant

  Scenario: Images are never upscaled
    Given an uploaded image 600 pixels wide
    When the variants are generated
    Then a 400px variant exists
    And no 800px or 1600px variant is produced

  Scenario: Originals are not publicly reachable
    Given a stored original image
    When it is requested through the public media path
    Then it is not served

  Scenario: Responses expose variants, not raw URLs
    Given a contestant with images
    When any endpoint returns that contestant
    Then each image includes a variants array with width and url

  Scenario: A contestant may hold up to ten images
    Given a contestant with ten images in a draft War
    When an eleventh image is uploaded
    Then the response status is 422

  Scenario: The next matchup's media is offered for prefetch
    Given a voter with at least two pairs remaining
    When they request /matchups/next
    Then the response includes a prefetch block naming the following matchup's media
```

### Contestant Schema

```gherkin
Feature: Contestant Schema

  Scenario: A pageant and a primary use different fields with the same code
    Given a War declaring country, age, and height
    And another War declaring party, state, and office
    When contestants are fetched from each
    Then each returns its own fields resolved with labels and values

  Scenario: An attribute outside the schema is rejected
    Given a War whose schema declares only country
    When a contestant is created with an attribute keyed party
    Then the response status is 422

  Scenario: A mistyped attribute is rejected
    Given a schema declaring age as a number
    When a contestant is created with age set to "twenty-four"
    Then the response status is 422

  Scenario: A dangerous URL never reaches storage
    Given a schema declaring a field of type url
    When a contestant is created with a javascript: value for it
    Then the response status is 422
    And no contestant record is created

  Scenario: Omitted fields are permitted
    Given a schema declaring country, age, and height
    When a contestant is created supplying only country
    Then the contestant is created
    And only country is present in its resolved attributes

  Scenario: Attributes resolve in schema order
    Given a schema declaring country then age
    When a contestant supplies them in the opposite order
    Then the resolved attributes list country before age

  Scenario: The schema is fixed once a War is active
    Given an active War
    When its contestant_schema is modified
    Then the response status is 403
```

### Media Mode

```gherkin
Feature: Media Mode

  Scenario: A video War rejects image uploads
    Given a draft War with media_mode video
    When an image is uploaded for a contestant
    Then the response status is 409

  Scenario: An image War rejects video attachment
    Given a draft War with media_mode image
    When a video URL is attached to a contestant
    Then the response status is 409

  Scenario: Activation requires media matching the mode
    Given a draft War with media_mode video
    And a contestant with no video attached
    When the creator activates the War
    Then the response status is 422
    And the War remains draft

  Scenario: An unembeddable video is rejected when added
    Given a video URL whose owner has disabled embedding
    When it is attached to a contestant
    Then the response status is 422
    And no media record is created

  Scenario: An unsupported provider is rejected
    Given a video URL from a provider outside the allow-list
    When it is attached to a contestant
    Then the response status is 422

  Scenario: Overlong videos are rejected
    Given a video whose effective duration is 90 seconds
    When it is attached to a contestant
    Then the response status is 422

  Scenario: A clip window shortens a longer video
    Given a five-minute video with start_seconds 60 and end_seconds 80
    When it is attached to a contestant
    Then the media record stores a duration of 20 seconds

  Scenario: Video responses carry an identity, never an embed URL
    Given a contestant with a video
    When any endpoint returns that contestant
    Then the media object names a provider and a video id
    And it contains no embed URL
```

### Rate Limiting

```gherkin
Feature: Rate Limiting

  Scenario: Voting beyond the per-voter limit is throttled
    Given a voter who has cast 60 votes within one minute
    When they cast another vote
    Then the response status is 429
    And a Retry-After header is present

  Scenario: Limits are keyed by voter, not by address
    Given two voters sharing one public IP address
    When one of them reaches the vote rate limit
    Then the other can still vote

  Scenario: Throttled votes are not recorded
    Given a voter who is being rate limited
    When their vote is rejected with 429
    Then no Vote record is created
    And no counters change
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

### War Expiry

```gherkin
Feature: War Expiry

  Scenario: An expired War reports as closed before the nightly task runs
    Given an active War whose ends_at passed one minute ago
    And the close-expired-wars task has not yet run
    When anyone GETs /api/v1/wars/:id
    Then the response status field is "closed"

  Scenario: Voting is rejected the moment a War expires
    Given an active War whose ends_at passed one second ago
    And the close-expired-wars task has not yet run
    When a joined voter POSTs a vote
    Then the response status is 403

  Scenario: A War with no end date never expires
    Given an active War with ends_at set to NULL
    When the close-expired-wars task runs
    Then the War remains "active"

  Scenario: The nightly task materialises the stored status
    Given an active War whose ends_at passed six hours ago
    When the close-expired-wars task runs
    Then the stored status column becomes "closed"
    And the response reports 1 War closed

  Scenario: The nightly task is idempotent
    Given the close-expired-wars task has already closed all expired Wars
    When it runs again
    Then zero Wars are modified
    And the response status is 200

  Scenario: Internal endpoints reject a missing or wrong token
    When POST /api/v1/internal/close-expired-wars is called without a valid X-Internal-Token
    Then the response status is 401
    And no War records are modified

  Scenario: Internal endpoints do not accept user JWTs
    Given a valid user JWT for any voter
    When POST /api/v1/internal/close-expired-wars is called with that JWT and no internal token
    Then the response status is 401
```

### Voting

```gherkin
Feature: Voting

  Scenario: Voter casts a vote
    Given a voter who joined an active War
    And matchup M has not been voted on by this voter
    When they POST /vote with a valid winner_id
    Then a Vote record is created
    And the winner's win_count increases by 1
    And both contestants' appearance_count increase by 1

  Scenario: A vote is final
    Given a voter who voted Contestant A in matchup M
    When they POST /vote for matchup M with winner_id = Contestant B
    Then the response status is 409
    And no new Vote record is created
    And no counters change

  Scenario: Re-submitting the same vote is treated as a retry
    Given a voter who voted Contestant A in matchup M
    When they POST /vote for matchup M with winner_id = Contestant A again
    Then the response status is 200
    And no new Vote record is created
    And no counters change

  Scenario: A pairing has no direction
    Given contestants A and B in an active War
    Then exactly one matchup exists for that pair
    And attempting to insert the mirrored pairing violates a constraint

  Scenario: A voter is never served a pair they have voted on
    Given a voter who has voted on matchup M
    When they request /matchups/next repeatedly until 204
    Then matchup M is never returned

  Scenario: Every pair is served before completion
    Given an active War with 4 contestants and therefore 6 pairs
    When a voter requests and votes until /matchups/next returns 204
    Then they have voted on all 6 pairs exactly once

  Scenario: Pair order is randomised but stable per voter
    Given two voters in the same active War
    Then the order pairs are served in differs between them
    And each voter's own order is identical across repeated requests

  Scenario: Pair selection favours the least-shown contestants
    Given an active War where contestant C has the lowest appearance_count
    When a voter requests /matchups/next
    And they have unvoted pairs both containing and not containing C
    Then the returned pair contains C

  Scenario: The displayed side is decided by the API and recorded
    Given a voter served matchup M
    Then the response names which contestant is left and which is right
    And the order is identical if the request is repeated
    When they vote
    Then presented_left_id is stored on the Vote record

  Scenario: Abandoning produces no record
    Given a voter served matchup M who never votes on it
    When they leave the War
    Then no Vote record exists for matchup M
    And neither contestant's counters changed

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

  Scenario: Contestants are ranked by raw win count
    Given Contestant A has 320 wins and Contestant B has 300 wins
    When rankings are fetched
    Then Contestant A ranks above Contestant B

  Scenario: Ties are broken by fewer appearances
    Given Contestants A and B both have 50 wins
    And Contestant A has 60 appearances and Contestant B has 80
    When rankings are fetched
    Then Contestant A ranks above Contestant B

  Scenario: A high win rate on few showings does not top the board
    Given Contestant A has 3 wins from 3 appearances
    And Contestant B has 320 wins from 400 appearances
    When rankings are fetched
    Then Contestant B ranks above Contestant A

  Scenario: Contestants with no appearances are unranked
    Given Contestant C has an appearance_count of 0
    When rankings are fetched
    Then Contestant C appears at the bottom
    And its rank is null

  Scenario: Exposure stays balanced as a War progresses
    Given an active War that has received several hundred votes
    When contestants' appearance_counts are compared
    Then they are clustered within a narrow range

  Scenario: Rankings are cacheable for public Wars
    Given a public War
    When rankings are fetched
    Then the response sets Cache-Control public with max-age 30

  Scenario: Invite-only rankings are not stored in a shared cache
    Given an invite_only War
    When rankings are fetched by a member
    Then the response sets Cache-Control private

  Scenario: Invite-only War rankings blocked for anonymous users
    Given an invite_only War
    When an unauthenticated user GETs rankings
    Then the response status is 401
```
