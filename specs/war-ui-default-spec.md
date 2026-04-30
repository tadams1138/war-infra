# War — Default UI Specification
**Repo:** `war-ui-default`  
**Version:** 1.0  
**Status:** Draft  
**Date:** 2026-04-28

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Principles](#2-architecture-principles)
3. [Repository Structure](#3-repository-structure)
4. [Routing & Pages](#4-routing--pages)
5. [API Integration](#5-api-integration)
6. [Component Specifications](#6-component-specifications)
7. [Auth Flow](#7-auth-flow)
8. [Error Handling](#8-error-handling)
9. [Tech Stack](#9-tech-stack)
10. [CI/CD](#10-cicd)
11. [Gherkin Acceptance Tests](#11-gherkin-acceptance-tests)

---

## 1. Overview

The Default UI is a **fully static** single-page application (SPA) that serves as the baseline frontend for all Wars that do not have a custom UI registered. It is built at compile time and deployed as static files to a CDN — there is no server-side rendering.

All data is fetched at runtime from the War REST API. The UI contains no business logic — it renders what the API returns.

---

## 2. Architecture Principles

- **Static files only.** Build output is plain HTML, CSS, and JavaScript. No Node.js server, no SSR, no edge functions.
- **CDN-hosted.** Assets are deployed to a CDN and served from the edge.
- **API consumer.** All data comes from `war-api` via `fetch()` calls. No data is computed or stored in the UI.
- **No business logic.** Scoring, matchup ordering, ranking — all returned by the API. The UI renders it.
- **Token storage.** JWT stored in memory (JavaScript variable). Refresh token stored in an `httpOnly` cookie set by the API. Never `localStorage`.
- **Client-side routing.** A single `index.html` is served for all routes; the SPA router handles navigation. The CDN/infra layer must rewrite all paths to `index.html` (see `war-infra` spec).

---

## 3. Repository Structure

```
war-ui-default/
├── src/
│   ├── pages/
│   │   ├── Home.tsx            # Browse wars
│   │   ├── WarDetail.tsx       # War overview
│   │   ├── VoteMode.tsx        # Binary matchup voting
│   │   ├── Rankings.tsx        # Leaderboard
│   │   ├── CreateWar.tsx       # War creation wizard
│   │   ├── MyWars.tsx          # Voter dashboard
│   │   └── Login.tsx           # OAuth entry point
│   ├── components/
│   │   ├── ContestantCard.tsx  # Image + name, used in vote mode
│   │   ├── MatchupView.tsx     # Two ContestantCards side by side
│   │   ├── RankingsTable.tsx   # Leaderboard rows
│   │   ├── ProgressBar.tsx     # Vote progress indicator
│   │   ├── WarCard.tsx         # War summary for browse/list
│   │   └── ImageCarousel.tsx   # Multi-image contestant gallery
│   ├── api/
│   │   └── client.ts           # Typed API wrapper (all fetch calls)
│   ├── auth/
│   │   └── context.tsx         # Auth state (JWT in memory)
│   ├── router/
│   │   └── index.tsx           # Client-side route definitions
│   └── main.tsx
├── public/
│   └── index.html              # SPA shell
├── vite.config.ts
├── package.json
└── README.md
```

---

## 4. Routing & Pages

All routes are client-side. The CDN rewrites all paths to `index.html`.

| Route | Page | Auth required | Description |
|---|---|---|---|
| `/` | Home | No | Browse active public Wars |
| `/wars/:id` | WarDetail | No | War overview, contestant gallery |
| `/wars/:id/vote` | VoteMode | Yes | Binary matchup voting |
| `/wars/:id/rankings` | Rankings | No | Leaderboard |
| `/wars/new` | CreateWar | Yes | War creation wizard |
| `/my-wars` | MyWars | Yes | Voter's Wars |
| `/login` | Login | No | OAuth provider selection |

Unauthenticated users visiting a protected route are redirected to `/login` with a `returnTo` query param.

---

## 5. API Integration

All API calls are encapsulated in `src/api/client.ts`. Pages and components **never call `fetch()` directly** — they use typed functions from this module.

```typescript
// Example typed API functions
getWars(params: GetWarsParams): Promise<WarListResponse>
getWar(warId: string): Promise<WarDetailResponse>
joinWar(warId: string): Promise<void>
getNextMatchup(warId: string): Promise<NextMatchupResponse | null>  // null = completed
castVote(warId: string, matchupId: string, winnerId: string): Promise<void>
getProgress(warId: string): Promise<ProgressResponse>
getRankings(warId: string): Promise<RankingsResponse>
createWar(payload: CreateWarPayload): Promise<WarResponse>
activateWar(warId: string): Promise<WarResponse>
addContestant(warId: string, payload: ContestantPayload): Promise<ContestantResponse>
uploadContestantImages(warId: string, contestantId: string, files: File[]): Promise<ImagesResponse>
```

The client module automatically:
- Attaches `Authorization: Bearer <jwt>` from in-memory auth state
- Handles `401` responses by attempting a token refresh before retrying once
- Throws typed errors that map to user-facing messages (see §8)

---

## 6. Component Specifications

### MatchupView
The core voting UI. Displays two `ContestantCard` components side by side.

- Each card shows: primary image (full bleed), contestant name
- Tapping/clicking a card casts a vote (calls `castVote`)
- While the vote is in-flight, both cards are disabled with a loading state
- After a successful vote, the next matchup is fetched automatically
- If the voter has already voted on this matchup (navigated back), both cards are disabled and the previously chosen card is highlighted
- `ImageCarousel` is accessible via a swipe/arrow on each card if the contestant has multiple images

### ProgressBar
Displays `voted / total` matchups as a percentage bar and text label ("7 of 10").

### RankingsTable
Renders the leaderboard returned by `GET /rankings`. Columns: Rank, Image, Name, Win %, Wins/Total.

- Polls the API every 30 seconds while the War is `active`
- Unranked contestants (zero votes) displayed at the bottom with "—" in rank column

### WarCard
Summary tile used on the Home and MyWars pages. Displays: title, category badge, status badge, contestant count, time remaining (if `ends_at` is set).

### CreateWar Wizard
Multi-step form:
1. **Metadata** — title, category, visibility, optional end date
2. **Contestants** — add contestants one at a time (name, bio, upload images)
3. **Review** — summary of all contestants and images
4. **Activate** — calls `POST /activate`; on success, redirects to the War's vote page

---

## 7. Auth Flow

1. User visits `/login`
2. Clicks a provider button → browser navigates to `GET /api/v1/auth/{provider}/login`
3. Provider redirects back to API callback → API sets `httpOnly` refresh token cookie and redirects to `/#token=<jwt>`
4. SPA reads JWT from URL fragment, stores in memory, clears fragment from URL
5. On JWT expiry, the client module silently calls `POST /auth/refresh` (cookie sent automatically) and retries
6. Logout calls `DELETE /auth/session` and clears in-memory JWT

---

## 8. Error Handling

Error handling is uniform across all pages. The `api/client.ts` module throws typed errors; pages render appropriate UI states.

| API Status | User-facing message |
|---|---|
| `401` | "Please log in to continue" → redirect to `/login` |
| `403` War closed | "This War is locked — voting is closed" |
| `403` Not joined | "Join this War to vote" |
| `404` | "This War doesn't exist or has been removed" |
| `422` | "Something went wrong — please try again" |
| `5xx` | "Server error — please try again shortly" |
| Network failure | "Unable to reach the server — check your connection" |

---

## 9. Tech Stack

| Component | Choice | Notes |
|---|---|---|
| Framework | React + TypeScript | |
| Build tool | Vite | Fast builds; static output |
| Routing | React Router v6 | Client-side SPA routing |
| Styling | Tailwind CSS | Utility-first; no runtime |
| State | React Context + hooks | No Redux needed at this scale |
| Testing | Vitest + React Testing Library | |
| Deployment | Static files on CDN | No server required |

---

## 10. CI/CD

See `war-infra` spec for pipeline definitions. This repo triggers:

**On PR:**
- Lint (`eslint`)
- Type check (`tsc --noEmit`)
- Unit tests (`vitest`)
- Build (`vite build`) — must succeed

**On merge to `main`:**
- Build
- Upload `dist/` to CDN (staging)
- Smoke test (Playwright: load home page, verify API response renders)
- Promote to production CDN

---

## 11. Gherkin Acceptance Tests

```gherkin
Feature: Browse Wars

  Scenario: Anonymous user browses public Wars
    Given the home page is loaded without authentication
    When active public Wars exist
    Then War cards are displayed with title, category, and contestant count
    And a "Login to Vote" CTA is shown

  Scenario: No active Wars
    Given no active public Wars exist
    When the home page loads
    Then an empty state message is displayed

Feature: Vote Mode

  Scenario: Voter is served a matchup
    Given an authenticated voter who has joined an active War
    When they navigate to /wars/:id/vote
    Then two contestant cards are displayed
    And a progress bar shows "0 of N matchups"

  Scenario: Voter casts a vote and sees next matchup
    Given a voter on the vote screen with matchup M1
    When they tap Contestant A's card
    Then a vote is submitted to the API
    And the next matchup M2 is loaded
    And the progress bar increments

  Scenario: Voter completes all matchups
    Given a voter who has voted on all but one matchup
    When they cast the final vote
    And the API returns 204 for /matchups/next
    Then a completion screen is shown
    And a link to the rankings page is displayed

  Scenario: Unauthenticated user visits vote page
    Given a user is not logged in
    When they navigate to /wars/:id/vote
    Then they are redirected to /login
    And the returnTo param points back to the vote page

Feature: Rankings

  Scenario: Rankings page loads for anonymous user
    Given a public active War with votes
    When an anonymous user navigates to /wars/:id/rankings
    Then the leaderboard is displayed with rank, name, and win %

  Scenario: Rankings poll while War is active
    Given a user viewing the rankings of an active War
    When 30 seconds elapse
    Then the UI re-fetches rankings from the API
    And the leaderboard updates if rankings changed

  Scenario: Unranked contestants shown at bottom
    Given a War where Contestant C has received no votes
    When the rankings page loads
    Then Contestant C appears at the bottom with rank "—"

Feature: Create War

  Scenario: Creator completes the War wizard and activates
    Given an authenticated voter on /wars/new
    When they complete all wizard steps with 3 contestants and images
    And they click Activate
    Then the API is called to activate the War
    And they are redirected to the War's vote page

  Scenario: Activate is blocked with fewer than 2 contestants
    Given a creator on the Review step with only 1 contestant
    When they attempt to activate
    Then an error message is shown
    And the War is not activated
```
