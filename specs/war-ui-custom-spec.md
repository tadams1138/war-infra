# War — Custom UI Specification
**Repo:** `war-ui-{slug}` (one per War brand)  
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-08-02

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Principles](#2-architecture-principles)
3. [Repository Structure](#3-repository-structure)
4. [Template Contract](#4-template-contract)
5. [Template Data Contexts](#5-template-data-contexts)
6. [Runtime Responsibilities](#6-runtime-responsibilities)
7. [Constraints](#7-constraints)
8. [Registration & Hosting](#8-registration--hosting)
9. [Tech Stack](#9-tech-stack)
10. [CI/CD](#10-cicd)
11. [Out of Scope](#11-out-of-scope)
12. [Gherkin Acceptance Tests](#12-gherkin-acceptance-tests)

---

## 1. Overview

A **custom UI** is a brand-specific frontend for a single War. When a War sets `ui_slug`, its pages are served from that slug's bundle instead of the default UI (`war-api-spec.md` §10).

A custom UI replaces *presentation only*. It consumes the same API, enforces no rules of its own, and cannot change how voting, ranking, or scoring behave. A "Miss Universe 2026" UI can look nothing like the default UI and still produce identical votes and identical rankings.

Custom UIs are optional. A War with no `ui_slug` uses the default UI (`war-ui-default-spec.md`).

### 1.1 When a custom UI is *not* the answer

Most campaign-to-campaign variation does not need one. Before building a custom UI, check whether the difference is really presentational:

| The difference is… | Solved by | Custom UI needed? |
|---|---|---|
| Different contestant facts — country and age vs party and state | `contestant_schema` on the War (`war-api-spec.md` §5) | No |
| Video contestants instead of photographs | `media_mode` on the War | No |
| Different title, category, end date, visibility | Ordinary War configuration | No |
| **Radically different branding, layout, and styling** | **A custom UI** | **Yes** |

A presidential primary and a beauty pageant describe contestants with entirely different fields, and both are served perfectly well by the default UI — the schema carries the difference, and the same components render both. That is a *data* difference, not a presentational one.

A custom UI is warranted when a campaign needs markup and styling the default UI cannot express: sponsor branding, a bespoke layout, a visual identity of its own. It is the heaviest option and the last one to reach for.

### 1.2 Mustache is a custom-UI mechanism only

Templates exist here because a separately-authored static bundle needs full control of its own markup. **The default UI does not use them** — it is React (`war-ui-default-spec.md` §9), and rendering user-supplied templates there would mean two rendering models in one application plus an injection surface with nothing to gain.

So per-campaign template variation is not something the default UI offers, and is not something it needs: schema-driven fields cover the variation that actually occurs. Templates are the price of admission for full markup control, and they come bundled with the rest of a custom UI's cost.

---

## 2. Architecture Principles

- **Static files only.** Build output is HTML, CSS, JavaScript, and templates. No server, no SSR, no edge functions.
- **Presentation only.** No business logic. Scoring, matchup order, side placement, and progress are all decided by the API and rendered as received.
- **Logicless templates.** The three required views are Mustache templates. Mustache is chosen *because* it cannot express conditionals beyond section presence or perform arithmetic — a custom UI structurally cannot reimplement ranking or recompute progress.
- **Contract-verified.** The presence of the required templates is enforced in CI (`war-infra-spec.md` §8.3), so a bundle missing a core view cannot deploy.
- **Shared origin.** All custom UIs are key prefixes in one bucket behind one origin (`war-infra-spec.md` §5.5). Registering one provisions no infrastructure.

---

## 3. Repository Structure

```
war-ui-{slug}/
├── templates/
│   ├── war-detail.mustache     # REQUIRED — War overview + contestant gallery
│   ├── vote-mode.mustache      # REQUIRED — binary matchup
│   └── rankings.mustache       # REQUIRED — leaderboard
├── src/
│   ├── main.ts                 # Bootstraps the runtime (§6)
│   └── styles.css              # Brand styling
├── public/
│   └── index.html              # SPA shell
├── package.json                # must expose `lint` and `build` scripts
├── vite.config.ts
└── README.md
```

The build must emit to `dist/` with `index.html` at its root.

The repository name determines the slug: `war-ui-miss-universe-2026` deploys to `/ui/miss-universe-2026/`. No configuration declares it.

---

## 4. Template Contract

Three templates are required. A missing one fails the pipeline before any deploy occurs.

| Template | Renders | Corresponds to |
|---|---|---|
| `war-detail.mustache` | War overview, contestant gallery, entry points to vote and rankings | `GET /wars/:id` |
| `vote-mode.mustache` | The two contestant cards and progress | `GET /wars/:id/matchups/next` |
| `rankings.mustache` | The leaderboard | `GET /wars/:id/rankings` |

A custom UI may add any further templates and routes it likes. Only these three are contractual.

### 4.1 Required behaviours

Regardless of styling, each template must satisfy the behaviour its data context implies:

- **`vote-mode`** must render `left` and `right` **in the order given** and must not reorder, sort, or randomise them. Side placement is decided and recorded by the API to make position bias measurable (`war-api-spec.md` §9.3); shuffling client-side destroys that signal irrecoverably.
- **`vote-mode`** must present exactly two choices and no skip or abstain control. Undecided pairs are recorded as nothing at all (`war-api-spec.md` §9.2).
- **`rankings`** must render rows in the order supplied and display `rank` as given. It must not sort by `wins`, compute percentages, or derive its own ordering.
- **`war-detail`** must not present a vote entry point when `can_vote` is false.
- **`war-detail`** must iterate `attributes` rather than naming fields. A template hard-coding `{{country}}` works for one campaign and silently renders nothing for the next; `{{#attributes}}{{label}}: {{value}}{{/attributes}}` works for every campaign the schema can describe (`war-api-spec.md` §5).
- In `video` mode, **`vote-mode`** must render the two players in the given order and must not enable voting before both have played. The runtime supplies `can_vote` for this; the template renders the section rather than deciding it.

---

## 5. Template Data Contexts

Contexts are derived from API responses by the runtime (§6). Because Mustache cannot compute, every value a template needs is **precomputed** — including display strings, percentages, and booleans.

### 5.1 `war-detail.mustache`

```json
{
  "war": {
    "id": "uuid",
    "title": "Miss Universe 2026",
    "category": "pageant",
    "status": "active",
    "is_active": true,
    "is_closed": false,
    "ends_at_display": "3 days remaining",
    "contestant_count": 90
  },
  "contestants": [
    {
      "id": "uuid",
      "name": "...",
      "bio": "...",
      "attributes": [
        { "key": "country", "label": "Country", "type": "string", "value": "Brazil" },
        { "key": "age",     "label": "Age",     "type": "number", "value": 24 }
      ],
      "image": { "srcset": "...400.webp 400w, ...800.webp 800w", "src": "...800.webp",
                 "alt": "...", "aspect_ratio": 0.75 }
    }
  ],
  "is_authenticated": true,
  "has_joined": false,
  "can_vote": true,
  "urls": { "vote": "/ui/{slug}/vote", "rankings": "/ui/{slug}/rankings", "login": "/login" }
}
```

### 5.2 `vote-mode.mustache`

```json
{
  "war": { "id": "uuid", "title": "..." },
  "matchup": {
    "id": "uuid",
    "left":  { "id": "uuid", "name": "...", "image": { "srcset": "...", "src": "...",
                                                        "alt": "...", "aspect_ratio": 0.75 } },
    "right": { "id": "uuid", "name": "...", "image": { … } }
  },
  "progress": { "voted": 7, "total": 253, "percent": 3, "display": "7 of 253" },
  "is_complete": false,
  "urls": { "rankings": "/ui/{slug}/rankings" }
}
```

When the voter has decided every pair, `is_complete` is true and `matchup` is absent — the template renders its completion state from the `is_complete` section.

### 5.3 `rankings.mustache`

```json
{
  "war": { "id": "uuid", "title": "...", "is_active": true },
  "rankings": [
    {
      "rank": 1,
      "rank_display": "1",
      "is_unranked": false,
      "contestant": { "id": "uuid", "name": "...", "image": { … } },
      "wins": 320,
      "appearances": 400
    }
  ],
  "updated_at_display": "updated just now"
}
```

Unranked contestants (`war-api-spec.md` §8) arrive with `is_unranked: true` and `rank_display: "—"`, already positioned last. The template renders the order it receives.

**Rankings show win counts, never percentages.** A percentage is not supplied in any context, because ranking is by raw wins and a derived percentage would misrepresent contestants with few appearances (`war-api-spec.md` §8.1).

---

## 6. Runtime Responsibilities

The runtime is the JavaScript that fetches from the API, builds the contexts above, renders templates, and submits votes. It handles:

- Attaching the in-memory JWT and performing single-flight refresh on `401` (`war-ui-default-spec.md` §7)
- Mapping API errors to user-facing states, including `429` with `Retry-After` (`war-ui-default-spec.md` §8)
- Submitting votes, advancing to the next matchup, and prefetching the one after
- Sequential video playback in `video` mode (`war-ui-default-spec.md` §6)
- Precomputing every derived value in §5

**A custom UI does not implement any of this.** The runtime is served from the platform at a stable URL and loaded with a script tag:

```html
<script type="module" src="/runtime/v1.js"></script>
```

Same origin as the custom UI, so no CORS. No npm dependency, no registry, no version bump, no build-time coupling. Types for local development come from `/runtime/v1.d.ts`.

```ts
// src/main.ts — the whole bootstrap
import type { WarRuntime } from './runtime'   // ambient, from /runtime/v1.d.ts

WarRuntime.mount({
  templates: {
    'war-detail': await fetch('./templates/war-detail.mustache').then(r => r.text()),
    'vote-mode':  await fetch('./templates/vote-mode.mustache').then(r => r.text()),
    'rankings':   await fetch('./templates/rankings.mustache').then(r => r.text()),
  },
  root: document.getElementById('app')!,
})
```

**Patches arrive without a redeploy.** Because the runtime is fetched rather than bundled, a fix ships with the next default-UI deploy and reaches every custom UI within its ten-minute cache window (`war-ui-default-spec.md` §5.2). No brand has to bump anything. This matters most for the refresh flow, where a bug logs voters out (`war-api-spec.md` §4.2) — a class of defect no brand should be able to carry a stale copy of.

**Major versions are pinned by path.** `/runtime/v1.js` keeps serving when `v2` ships; only a major upgrade requires a custom UI to change anything.

Re-implementing the runtime is not supported. A custom UI that does so is on its own for auth correctness and will not receive platform fixes.

---

## 7. Constraints

| Constraint | Value | Enforced by |
|---|---|---|
| Built bundle size | < 2 MB total | CI `size-check` |
| Required templates | all three present | CI `template-check` |
| Slug format | `^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$` | CI, before any upload |
| Build output | `dist/` with `index.html` at root | Deploy step |
| Server-side code | none | Static hosting |

The 2MB budget covers everything in `dist/` — a custom UI is a brand skin, and contestant imagery is served from the media CDN rather than bundled.

The slug pattern is a security control, not cosmetic: all custom UIs share one bucket, so an unvalidated slug could write into another brand's prefix (`war-infra-spec.md` §8.3).

---

## 8. Registration & Hosting

A custom UI is registered by inserting a `ui_registrations` row and uploading the bundle (`war-api-spec.md` §10). Both are done by `scripts/register-ui.sh` in `war-infra`.

Registration creates **no infrastructure** — no bucket, no CDN origin, no routing rule, no redeploy of anything already running. The bundle lands at the `{slug}/` prefix of the shared bucket, and the edge function routes `/ui/{slug}/*` to it (`war-infra-spec.md` §6.1).

Deep links work because that edge function rewrites storage 404s to the slug's `index.html` with HTTP 200.

---

## 9. Tech Stack

| Component | Choice | Notes |
|---|---|---|
| Templating | Mustache | Logicless by design (§2) |
| Build tool | Vite | Any tool works provided `npm run build` emits `dist/` |
| Styling | Author's choice | No constraint beyond the size budget |
| Runtime | `/runtime/v1.js`, loaded by script tag | Served by the platform; never bundled (§6) |
| Testing | Author's choice | Only the CI checks in §7 are mandatory |

Unlike the default UI, the toolchain is not prescribed. The pipeline interacts with a custom UI through two npm scripts — `lint` and `build` — so any stack exposing those is acceptable.

---

## 10. CI/CD

Pipeline defined in `war-infra-spec.md` §8.3; the repo supplies only a caller:

```yaml
# war-ui-{slug}/.github/workflows/deploy.yml
jobs:
  deploy:
    uses: tadams1138/war-infra/.github/workflows/ui-custom.yml@master
    with:
      deploy: true          # false in pr.yml
    secrets: inherit
```

**On PR:** lint → build → template-check → size-check  
**On merge to `master`:** the above, then sync to staging → purge → smoke test → manual gate → promote the same artefact to production

Production deploys the artefact staging validated; it is never rebuilt.

---

## 11. Out of Scope

- Custom UIs for more than one War per repo (one slug per repo)
- Server-side rendering or any server-side code
- Overriding scoring, matchup order, or side placement
- Adding API endpoints or extending the data contexts in §5
- Authentication flows other than the standard OAuth entry points
- Per-slug infrastructure of any kind

---

## 12. Gherkin Acceptance Tests

```gherkin
Feature: Template Contract

  Scenario: A bundle missing a required template cannot deploy
    Given a custom UI repo without templates/vote-mode.mustache
    When the pipeline runs
    Then the template-check stage fails
    And no bundle is uploaded

  Scenario: An oversized bundle cannot deploy
    Given a custom UI whose dist/ totals 3MB
    When the pipeline runs
    Then the size-check stage fails
    And no bundle is uploaded

  Scenario: An unsafe slug is rejected before upload
    Given a slug containing a path traversal sequence
    When the pipeline resolves the slug
    Then the run fails
    And nothing is written to storage

Feature: Presentation Fidelity

  Scenario: Contestant sides are rendered as supplied
    Given a matchup context with contestant B as left and contestant A as right
    When vote-mode.mustache renders
    Then B appears in the left position
    And A appears in the right position

  Scenario: No skip control is offered
    Given a matchup context
    When vote-mode.mustache renders
    Then exactly two selectable choices are present
    And no skip or abstain control exists

  Scenario: Rankings are rendered in the supplied order
    Given a rankings context listing contestants in a given order
    When rankings.mustache renders
    Then rows appear in that order
    And no percentage is displayed

  Scenario: Unranked contestants render as supplied
    Given a rankings context where a contestant has is_unranked true
    When rankings.mustache renders
    Then that contestant shows "—" for rank
    And appears after all ranked contestants

  Scenario: Voting entry point is hidden when voting is unavailable
    Given a war-detail context with can_vote false
    When war-detail.mustache renders
    Then no vote entry point is present

Feature: Hosting

  Scenario: A registered custom UI is served at its slug path
    Given a registered slug "miss-universe-2026" with an uploaded bundle
    When a request is made to /ui/miss-universe-2026/
    Then that bundle's index.html is returned

  Scenario: Deep links into a custom UI resolve
    Given a registered custom UI
    When a request is made to a client-side route within it
    Then the slug's index.html is returned with HTTP 200

  Scenario: Registering a custom UI provisions nothing
    Given a new custom UI bundle
    When it is registered and uploaded
    Then it is served at its slug path
    And no infrastructure apply was required
    And no other custom UI was affected
```
