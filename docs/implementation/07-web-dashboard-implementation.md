# 07 — Web Dashboard Implementation

*Last updated: 2026-04-17*

Covers: the future public + municipal-facing web interface built on Next.js + Mapbox GL JS. This is **Phase 2+**, not part of the 8-week iOS/TestFlight MVP, but it is now specified deeply enough that a developer could build it without inventing a parallel product.

## Objective

Build a web interface that turns RoadSense from "an app that collects data" into "a trusted public map and analysis surface for Nova Scotia road quality."

The web product is where we:

- aggregate data across contributors
- explain confidence, freshness, and limits clearly
- help the public explore rough roads near them
- give municipalities and journalists a sober view of coverage, trends, and problem corridors

It is **not**:

- a personal driver dashboard
- a CRUD-heavy admin console
- a raw-trace explorer
- a place to expose contributor-level or device-level data

## Phase Scope

### Phase W1 — Public launch

Includes:

- public interactive map
- municipality-aware URLs
- search by municipality / place / road
- road-segment detail drawer
- pothole overlay
- coverage mode
- methodology page
- privacy page
- one lightweight `Worst Roads` analysis surface

Does not include:

- user accounts
- personal contribution history
- exports
- municipal-only auth partitions
- custom report builders
- arbitrarily queryable date ranges

### Phase W2 — Municipal / analyst layer

Adds:

- trend pages
- municipality coverage tables
- export endpoints
- saved / shareable report URLs
- optional municipal-auth surfaces if they are ever needed

## Product Principles

1. **Map first.** The map is the hero surface; analysis supports it.
2. **Trust is a feature.** Confidence, recency, methodology, and privacy posture must be visible.
3. **Public by default.** Language and layout should work for a resident, not only a transportation analyst.
4. **One mode at a time.** Quality, Potholes, and Coverage are separate views, not layered clutter.
5. **No dashboard sludge.** No admin-template card farms, no giant left nav, no vanity KPI rows above the fold.

## System Role

The phone and the web have different jobs.

- **Phone:** passive collection, quick visualization, reassurance that the app is working.
- **Web:** public aggregation, analysis, comparison, trust-building explanation, and shareable civic reporting.

This split matters because the web app should not inherit the iPhone UI. The design language should be related, but the information density and navigation model should be different.

## Implementation Assumptions

These are locked assumptions for the web build:

1. The web app is public, read-only, and unauthenticated in W1.
2. The web app never sees raw readings, raw traces, or any contributor identifier.
3. Existing read APIs remain the source of truth for segment detail, potholes, stats, and standard quality tiles.
4. Phase W1 adds **two** new backend read surfaces because the current ones are not enough:
   - `GET /tiles/coverage/{z}/{x}/{y}.mvt`
   - `GET /segments/worst?municipality=<name>&limit=<n>`
5. Municipality routing is driven by a **static manifest** in the web app, not a new backend endpoint. Nova Scotia municipality metadata is stable enough that the extra API surface is not worth it yet.
6. The web app does **not** use the Supabase JS client in the browser. Use `fetch` and Mapbox GL JS directly. This keeps bundle size down and reduces auth mistakes.

## Recommended Repo Layout

Create the web app under `apps/web/` once implementation starts:

```text
apps/web/
├── app/
│   ├── layout.tsx
│   ├── page.tsx
│   ├── municipality/
│   │   └── [slug]/
│   │       └── page.tsx
│   ├── reports/
│   │   └── worst-roads/
│   │       └── page.tsx
│   ├── methodology/
│   │   └── page.tsx
│   ├── privacy/
│   │   └── page.tsx
│   └── api/
│       └── og/
│           └── route.ts
├── components/
│   ├── chrome/
│   ├── map/
│   ├── drawer/
│   ├── legend/
│   ├── search/
│   ├── reports/
│   └── content/
├── lib/
│   ├── api/
│   ├── municipality-manifest.ts
│   ├── url-state.ts
│   ├── map-style.ts
│   ├── formatters.ts
│   └── assertions.ts
├── public/
│   └── icons/
└── tests/
    ├── unit/
    ├── integration/
    └── e2e/
```

Reasoning:

- `app/` owns routes and server-rendered shells.
- `components/` owns UI pieces with no backend knowledge.
- `lib/api/` owns typed fetch wrappers around backend contracts.
- `tests/` mirrors the red/green plan below.

## Runtime Boundaries

### Server components

Use server components for:

- `layout.tsx`
- route shells for `/`, `/municipality/[slug]`, `/reports/worst-roads`
- methodology/privacy pages
- initial stats fetch
- SEO / metadata generation
- report-page initial data fetch

Why: these surfaces are cacheable, mostly static, and should load without a client-side waterfall.

### Client components

Use client components for:

- Mapbox map canvas
- mode switcher
- segment detail drawer state
- hover / selection handling
- pothole overlay fetch tied to map movement
- search box interactions
- mobile bottom-sheet behavior

Why: these surfaces depend on browser events, viewport, and map SDK state.

### Shared presentational components

Keep legend cards, trust strips, stats pills, report rows, and drawers as pure presentational components where possible. Fetching logic belongs in route loaders or thin hooks, not inside every card.

## URL Model

The URL must be shareable and meaningful. A copied URL should reconstruct the user-visible state well enough that a recipient sees the same road / municipality / mode.

### Canonical routes

- `/` — Nova Scotia map, default viewport
- `/municipality/[slug]` — municipality-focused view using static manifest bounds
- `/reports/worst-roads` — ranked view
- `/methodology`
- `/privacy`

### Query parameters

Allowed query parameters:

- `mode=quality|potholes|coverage`
- `segment=<uuid>` — selected segment drawer opens on load
- `lat=<float>`
- `lng=<float>`
- `z=<float>`
- `q=<string>` — last search term, optional, for share/debug only

Rules:

1. `mode` defaults to `quality`.
2. `segment` must be ignored if the segment fetch returns 404.
3. `lat/lng/z` are advisory; if invalid, fall back to route defaults.
4. `/municipality/[slug]` route-owned bounds override bogus viewport params on first load.
5. URL updates should use `replaceState` while panning and `pushState` only for meaningful transitions such as changing municipality, mode, or selected segment.

## Municipality Manifest

Store a static manifest in `lib/municipality-manifest.ts`.

Each entry must include:

```ts
type MunicipalityConfig = {
  slug: string
  name: string
  bbox: [minLng: number, minLat: number, maxLng: number, maxLat: number]
  center: [lng: number, lat: number]
  defaultZoom: number
}
```

Notes:

- `slug` is a frontend routing concern only.
- `name` must match backend `road_segments.municipality` values exactly, because `GET /segments/worst` uses the display name, not the slug.
- Keep this file hand-curated and tested. Do not generate it at runtime.

## Visual Direction

### Overall look

- Light-first design matching the iOS civic-utility feel
- Warm neutrals, Atlantic blue accent, same road-quality semantic ramp as iOS
- Minimal drop shadows; prefer borders, spacing, and layering
- Map owns at least 60% of the initial desktop viewport

### Typography

- Editorial serif for major page titles and explanatory content
- Modern sans for controls, labels, tables, and map UI
- Headlines should feel public-interest and calm, not startup-marketing loud

### Color tokens

Reuse the iOS semantic palette:

- `smooth`
- `fair`
- `rough`
- `veryRough`
- `unscored`
- `accent.community`
- neutral confidence ramp

Add coverage-only tokens:

- `coverage.none`
- `coverage.emerging`
- `coverage.published`
- `coverage.strong`

Coverage colors must be visually distinct from roughness colors so users do not confuse "well covered" with "smooth."

### Motion

Motion must orient, not decorate:

- panel slide-ins
- subtle road highlight on hover/select
- smooth mode transitions

Avoid:

- animated counters
- parallax
- chart fireworks
- floating blobs / marketing motion

## Route Specifications

## `/` — Home Map

### Purpose

Primary discovery surface for the public.

### Above-the-fold requirements

The first viewport must answer:

1. What am I looking at?
2. What do the colors mean?
3. How current is this?
4. How trustworthy is this?

### Desktop layout

- compact top nav
- floating left control stack
- dominant map canvas
- right-side detail drawer when a segment is selected
- persistent trust strip near top or bottom edge

### Mobile layout

- map full-bleed
- compact top bar
- bottom sheet for controls and legend
- selected segment opens in the same bottom-sheet stack

### Data dependencies

- `GET /stats`
- `GET /tiles/{z}/{x}/{y}.mvt`
- `GET /segments/{id}` when selected
- `GET /potholes?bbox=...` in potholes mode only
- `GET /tiles/coverage/{z}/{x}/{y}.mvt` in coverage mode only

### Loading states

- shell renders immediately with legend skeleton and trust strip placeholder
- map skeleton shows geographic frame, not blank white rectangle
- stats strip may skeletonize, but it must not shift layout when loaded
- drawer uses inline skeleton, not full-page spinner

### Empty/error states

- map API unavailable: `Road data is temporarily unavailable. Try again shortly.`
- segment unavailable: `We could not load details for this road segment.`
- no published signal on selected segment: `No community road-quality signal here yet.`

## `/municipality/[slug]`

### Purpose

Shareable municipality-focused variant of the home map.

### Behavior

- validates `slug` against static manifest
- 404 if no match
- initializes viewport to municipality bounds
- preselects municipality filter in chrome
- preserves `mode` and `segment` query params if valid

### SEO / metadata

Generate title/description per municipality:

- `Road conditions in Halifax | RoadSense NS`
- `Explore community-reported road quality, potholes, and coverage in Halifax.`

## `/reports/worst-roads`

### Purpose

A ranked, inspectable report surface for public and press use. It is not a maintenance queue.

### Data dependency

- `GET /segments/worst?municipality=<name>&limit=<n>`

### Layout

- short caveat header
- municipality selector
- top-N ranked list
- mini trend strip per row
- small synchronized map preview or inline "locate on map" affordance

### Row contents

Each row must show:

- rank
- road name
- municipality
- category
- short trust label (`High confidence`, `Medium confidence`)
- trend label
- roughness score rounded for display
- pothole count if non-zero

### Ranking explanation

Keep a visible note:

`Rankings are based on published community averages and may change as more drivers contribute data.`

## `/methodology`

Must cover in plain language first:

- what the app collects
- what it does not collect
- how server-side road matching works
- what confidence means
- why some roads are missing
- why coverage is not the same thing as smoothness
- why data is refreshed in batches rather than live
- why unpaved roads are treated differently

Technical appendix can follow below the plain-language section.

## `/privacy`

Must align with [06-security-and-privacy.md](06-security-and-privacy.md).

Cover:

- what data is collected
- what is filtered on-device
- that no accounts exist in W1
- that the public web app is read-only
- that raw traces are never exposed on the web
- that there are no advertising trackers or session-replay tools

## Interaction Model

### Modes

Allowed W1 modes:

- `quality`
- `potholes`
- `coverage`

Only one mode may be active at once.

### Hover / selection

Desktop:

- hover may preview
- click selects and opens drawer

Mobile:

- tap selects
- second tap on already-selected road expands details if needed

Rules:

- only one selected segment at a time
- clicking empty map clears selection only
- hovered state must never permanently alter route state

### Search

W1 search behavior:

1. Check municipality manifest first for exact or close name match.
2. If not matched, fall back to Mapbox geocoding constrained to Nova Scotia.
3. On result selection, pan/zoom map and preserve current mode.
4. If the result is a municipality, route to `/municipality/[slug]`.

Do **not** build a custom road-name backend search in W1. The added backend complexity is not justified until real usage proves geocoding inadequate.

## Component Boundaries

These boundaries should hold unless real implementation pain proves otherwise.

### Route shell components

- `AppShell`
- `TopNav`
- `TrustStrip`
- `MunicipalityPageShell`
- `WorstRoadsPageShell`

### Map subsystem

- `MapView`
- `MapModeSwitcher`
- `MapLegend`
- `MapSearchBox`
- `MapViewportController`
- `QualityLayerController`
- `CoverageLayerController`
- `PotholeOverlayController`

### Detail surfaces

- `SegmentDrawer`
- `SegmentStats`
- `TrendChip`
- `ConfidenceBadge`
- `PotholeListCard`

### Report surfaces

- `WorstRoadsList`
- `WorstRoadRow`
- `ReportCaveat`

### Content pages

- `MethodologyContent`
- `PrivacyContent`

## Data Contracts

W1 web should use the following contracts.

### Existing contract: `GET /tiles/{z}/{x}/{y}.mvt`

Use for `quality` mode only.

This already returns:

- category
- confidence
- total_readings
- unique_contributors
- pothole_count

It is **not** sufficient for coverage mode because it hides low-confidence and unscored roads.

### New contract: `GET /tiles/coverage/{z}/{x}/{y}.mvt`

Required for coverage mode.

Purpose: show where the network has no signal, emerging signal, published signal, or strong signal without exposing raw low-sample contributor counts.

**Request**

- same path semantics and cache behavior as standard tiles
- optional `?v=<int>` cache-buster for daily rotation
- same anon auth expectations as other read endpoints

**Response — 200 OK**

- `Content-Type: application/vnd.mapbox-vector-tile`
- `Cache-Control: public, max-age=3600, s-maxage=3600`
- source-layer: `segment_coverage`

**Attributes**

| Attribute | Type | Meaning |
|---|---|---|
| `id` | string (UUID) | segment id |
| `road_name` | string? | road label when available |
| `road_type` | string | motorway, primary, ... |
| `coverage_level` | string | `none`, `emerging`, `published`, `strong` |
| `updated_at` | timestamp? | last aggregate refresh time when available |

**Coverage-level derivation**

- `none` — no aggregate row or `total_readings = 0`
- `emerging` — aggregate exists but `unique_contributors < 3`
- `published` — `unique_contributors >= 3` and `< 10`
- `strong` — `unique_contributors >= 10`

Do **not** include `total_readings` or `unique_contributors` in the coverage tile for `none` or `emerging` segments. The point of this tile is public coverage shading, not low-sample enumeration.

**Response — 204 No Content**

Same semantics as the standard tile endpoint.

### Existing contract: `GET /segments/{id}`

Use for drawer detail. The web app should reuse the same human-readable labels as iOS:

- `High confidence`
- `Updated last night`
- `34 contributors`

Do not leak raw enum values directly into the UI.

### Existing contract: `GET /potholes?bbox=...`

Use only in `potholes` mode and only after debounced map movement. Do not fetch this endpoint on every load regardless of mode.

### Existing contract: `GET /stats`

Use for:

- trust strip
- high-level map intro
- methodology freshness context

### New contract: `GET /segments/worst?municipality=<name>&limit=<n>`

Required for `/reports/worst-roads`.

**Request**

- `municipality` optional exact municipality display name from static manifest
- `limit` required, integer, `1 <= limit <= 100`

**Semantics**

- published roads only
- exclude `unscored`
- exclude `unpaved`
- sort by `avg_roughness_score DESC`, then `pothole_count DESC`, then `total_readings DESC`

**Response — 200 OK**

```json
{
  "generated_at": "2026-04-17T03:20:00Z",
  "municipality": "Halifax",
  "rows": [
    {
      "rank": 1,
      "segment_id": "c8a1b2d3-...",
      "road_name": "Barrington Street",
      "municipality": "Halifax",
      "road_type": "primary",
      "category": "very_rough",
      "confidence": "high",
      "avg_roughness_score": 1.181,
      "score_last_30d": 1.242,
      "score_30_60d": 1.011,
      "trend": "worsening",
      "total_readings": 182,
      "unique_contributors": 37,
      "pothole_count": 3,
      "last_reading_at": "2026-04-16T22:15:00Z"
    }
  ]
}
```

**Response — 400 validation_failed**

- bad municipality name
- missing / invalid limit

This endpoint is intentionally aggregate-only. No raw-reading or contributor history is exposed.

## Rendering and Cache Strategy

### Server-rendered and cacheable

- `/`
- `/municipality/[slug]`
- `/reports/worst-roads`
- `/methodology`
- `/privacy`

Use route-level revalidation:

- home and municipality pages: `revalidate = 300`
- worst roads page: `revalidate = 300`
- methodology/privacy: static unless content changes

### Browser-fetched

- standard vector tiles
- coverage tiles
- segment detail drawer fetch
- pothole bbox fetch

Why: these are viewport-driven and not good fits for server rendering.

### Cache busting

- respect backend cache headers
- daily tile version query param can remain the same pattern as iOS
- do not invent client-side polling for freshness badges

## Environment Variables

Web app env vars should be:

- `NEXT_PUBLIC_MAPBOX_TOKEN`
- `NEXT_PUBLIC_MAPBOX_STYLE_ID` or explicit style URL
- `NEXT_PUBLIC_API_BASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SITE_URL`

Rules:

1. No service-role secrets in Vercel browser-exposed env.
2. If server components need privileged read behavior in W2, use server-only env vars and separate route handlers then. Do not preemptively add them in W1.
3. `SITE_URL` drives canonical URLs and OG metadata.

## Red / Green TDD Delivery Plan

Every slice below is implementation-order guidance. The sequence matters because each slice creates the seam for the next one.

### Slice 0 — App shell, design tokens, and route skeleton

**RED**

- unit tests for `parseUrlState()` and `serializeUrlState()`
- route tests that `/`, `/municipality/halifax`, `/reports/worst-roads`, `/methodology`, `/privacy` all render stable shells
- snapshot test that nav and trust-strip placeholders exist without client JS

**GREEN**

- create `apps/web/`
- wire Next.js App Router
- implement global CSS variables, typography tokens, and spacing scale
- implement layout shell and placeholder route pages

**REFACTOR**

- extract shared shell primitives
- confirm zero duplicate route chrome

### Slice 1 — Municipality manifest and route ownership

**RED**

- unit tests that every slug is unique
- unit tests that every manifest `name` is non-empty and every bbox has 4 finite numbers
- route test: invalid municipality slug returns 404
- route test: valid municipality route seeds expected viewport defaults

**GREEN**

- implement `municipality-manifest.ts`
- wire `/municipality/[slug]`
- connect metadata generation and shareable titles

**REFACTOR**

- centralize slug lookup / assertion helpers

### Slice 2 — Quality map vertical slice

**RED**

- component test: home page shows map shell, legend, trust strip, and mode switcher
- Playwright test: home page loads, map becomes visible, quality legend is visible within first viewport
- Playwright test: mode defaults to `quality`
- Playwright test: selecting a municipality route lands on the correct title and map state

**GREEN**

- implement `MapView`
- load `GET /tiles/{z}/{x}/{y}.mvt`
- render quality line layers
- render legend and trust strip backed by `GET /stats`

**REFACTOR**

- separate map style config from React components
- remove any duplicated source/layer definitions

### Slice 3 — Segment detail drawer

**RED**

- unit test for segment-response formatter labels
- component test: selecting a segment opens drawer skeleton, then resolved content
- Playwright test: clicking a visible segment opens drawer with road name, confidence, last updated, and contributor count
- Playwright test: bad `segment=` query param fails gracefully

**GREEN**

- fetch `GET /segments/{id}`
- implement drawer content hierarchy
- sync `segment` query param to URL

**REFACTOR**

- isolate drawer fetch logic in a single hook
- keep drawer presentation separate from fetch state

### Slice 4 — Search and municipality switching

**RED**

- unit tests for municipality-first search resolution
- integration test for geocoder result normalization
- Playwright test: selecting a municipality result routes to `/municipality/[slug]`
- Playwright test: place search pans map without changing mode

**GREEN**

- implement `MapSearchBox`
- municipality-first search
- Mapbox geocoding fallback constrained to Nova Scotia

**REFACTOR**

- debounce search cleanly
- use `useDeferredValue` for typeahead input if needed

### Slice 5 — Potholes mode

**RED**

- component test: switching to potholes mode mutes road-quality emphasis and enables pothole legend copy
- integration test: pothole bbox requests are debounced and skipped outside potholes mode
- Playwright test: switching to potholes mode shows markers and opening a marker shows detail card content

**GREEN**

- implement potholes mode layer behavior
- fetch `GET /potholes?bbox=...` after debounced viewport settles
- add marker/detail-card UI

**REFACTOR**

- centralize viewport-to-bbox conversion
- ensure no duplicate fetches during small pan movements

### Slice 6 — Coverage mode

**RED**

- contract tests for `GET /tiles/coverage/{z}/{x}/{y}.mvt`
- component test: coverage legend copy explicitly says coverage is not condition
- Playwright test: coverage mode visually differs from quality mode and keeps trust cues visible
- Playwright test: switching between quality and coverage preserves selection state correctly

**GREEN**

- implement coverage tile source/layers
- add coverage legend
- wire `mode=coverage`

**REFACTOR**

- eliminate duplicated map source registration across modes
- keep coverage color tokens distinct from roughness tokens

### Slice 7 — Worst Roads report

**RED**

- contract tests for `GET /segments/worst`
- route test: page renders caveat header, filter shell, and list skeleton server-side
- Playwright test: changing municipality updates the ranked list
- Playwright test: clicking a row transitions to the relevant map context or opens segment detail affordance

**GREEN**

- implement report page
- fetch `GET /segments/worst`
- render list with ranking caveat, trend, and locate action

**REFACTOR**

- extract reusable confidence/trend chips
- ensure report rows and map detail use the same display formatters

### Slice 8 — Methodology, privacy, and trust polish

**RED**

- snapshot tests for methodology/privacy content anchors
- Playwright test: methodology page explains confidence and missing roads in plain language
- Playwright test: privacy page does not mention accounts or trackers

**GREEN**

- implement long-form content pages
- add trust-strip links to both pages

**REFACTOR**

- keep prose content in structured modules, not giant JSX blobs

### Slice 9 — Accessibility, responsiveness, and performance hardening

**RED**

- accessibility tests for focus order, labels, and drawer semantics
- Playwright mobile viewport tests for home and municipality pages
- performance test: first meaningful map view and first drawer-open within budget
- visual regression screenshots at desktop/tablet/mobile widths

**GREEN**

- fix keyboard navigation
- fix focus management on drawer open/close
- fix mobile sheet layout
- trim layout shift and bundle weight

**REFACTOR**

- remove incidental complexity introduced during hardening

## Testing Strategy

The web app needs four layers of tests.

### 1. Unit tests — Vitest

Use for:

- URL-state parsing
- municipality-manifest validation
- display-formatting helpers
- ranking / label formatting
- search-result normalization

Do **not** unit test Mapbox GL internals.

### 2. Component / integration tests — React Testing Library + MSW

Use for:

- drawer states
- legend mode switching
- trust strip rendering
- report list rendering
- search interactions with mocked geocoder and mocked backend responses

Mock backend contracts with MSW using payloads copied from [03-api-contracts.md](03-api-contracts.md).

### 3. End-to-end tests — Playwright

Required W1 flows:

1. Load `/` and see map + legend + trust strip.
2. Load `/municipality/halifax` and see municipality title/context.
3. Select a road and open detail drawer.
4. Switch between quality, potholes, and coverage.
5. Search for a municipality and route correctly.
6. Open `/reports/worst-roads`, change municipality, and inspect a row.
7. Open methodology/privacy pages and verify trust copy exists.

### 4. Visual regression tests

Use Playwright screenshots for:

- desktop home
- desktop municipality route
- mobile home
- mobile segment drawer
- worst roads page

Store snapshots in git only if they remain stable enough to be useful. If they become noisy, keep visual review manual but repeatable.

## Accessibility Requirements

Must-have W1 accessibility behavior:

- keyboard-reachable nav, mode switcher, search, and drawer actions
- visible focus ring
- semantic button roles
- drawer announces itself as a dialog or complementary region consistently
- text alternative for the legend
- report/list alternative to map-only understanding
- no hover-only critical interaction

Mapbox canvas itself is not enough. The page must remain understandable without pointer hover.

## Performance Budgets

These are web-specific budgets, not reused iOS budgets.

- route shell HTML visible: < 500ms on warm Vercel edge
- first meaningful map visible: < 2.5s on mid-tier laptop over normal broadband
- first segment drawer open after click: < 300ms when cached, < 800ms uncached
- Lighthouse accessibility score: >= 95 on methodology/privacy pages
- CLS: < 0.1 on route load

If map performance slips, prefer reducing UI chrome and duplicate re-renders before inventing a different mapping stack.

## Phase W1 Backend Additions Required By Web

The following are non-negotiable if W1 web ships with the current product scope:

1. `GET /tiles/coverage/{z}/{x}/{y}.mvt`
2. `GET /segments/worst?municipality=<name>&limit=<n>`

Without these, the spec would be dishonest:

- coverage mode cannot show missing/emerging coverage truthfully
- worst-roads page cannot exist as a real report surface

## Definition of Done

W1 web is done when all of the following are true:

1. A first-time visitor can understand the legend and freshness cues within 10 seconds.
2. `/`, `/municipality/[slug]`, `/reports/worst-roads`, `/methodology`, and `/privacy` all load with correct metadata and no broken route state.
3. Quality, potholes, and coverage modes all work and are visually distinguishable.
4. Selecting a road opens a clear detail drawer backed by real data.
5. Worst-roads report renders from a real endpoint, not mocked data.
6. Mobile web preserves map prominence and usable detail access.
7. Accessibility and performance budgets above are met.

## Web Policy Decisions

- **Keep one web codebase.** If municipal-only features ever exist, add them behind separate routes and server-side auth rather than splitting the product into a second frontend.
- **Use dynamic reads for W1 reports.** If journalists or partners later need frozen, citeable daily snapshots, add them as a follow-on reporting layer rather than front-loading that complexity.
