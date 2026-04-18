# 08 — Implementation Backlog

*Last updated: 2026-04-18*

Covers: the literal execution backlog for implementing the spec set in [00](00-execution-plan.md) through [07](07-web-dashboard-implementation.md).

This doc is deliberately task-shaped rather than explanatory. The goal is that a solo developer can work through it top to bottom without re-plioritizing the whole project every morning.

## How To Use This Backlog

Rules:

1. Work in dependency order unless a task is explicitly marked parallelizable.
2. For every task, do the **RED** step first: write the test, contract, or manual verification harness before the implementation.
3. Do not start UI polish before the end-to-end data loop exists.
4. Do not start the web dashboard until the iOS/TestFlight MVP is live or intentionally paused.
5. If a task changes an API or persistence contract, update [03-api-contracts.md](03-api-contracts.md) and the relevant implementation doc in the same PR.

## Definition Of Ready

A task is ready when:

- dependencies listed below are complete
- a file/module owner is obvious
- acceptance criteria are concrete
- the RED step is known

## Definition Of Done

A task is done when:

- implementation matches the spec doc it points to
- tests pass at the right layer
- manual verification notes are captured if real-device testing is required
- any new config/env var is documented
- any new endpoint or schema change is reflected in docs

## Phase Map

MVP phases:

1. Project and environment setup
2. Backend foundation
3. iOS foundation
4. End-to-end stub loop
5. Calibration and aggregation hardening
6. iOS UX, privacy, and reliability hardening
7. Internal TestFlight readiness
8. External TestFlight readiness

Post-MVP phases:

9. Web dashboard backend additions
10. Web dashboard frontend
11. Quarterly operational procedures (OSM refresh rematch, etc.) — runs on a calendar, not a release

## Phase 1 — Project And Environment Setup

### B001 — Lock project identity and environments

- **Spec refs:** [00](00-execution-plan.md), [05](05-deployment-and-observability.md), [06](06-security-and-privacy.md)
- **Depends on:** none
- **RED**
  - checklist doc or PR note confirming `RoadSense NS`, `ca.roadsense.ios`, and `roadsense.ca` are used consistently
  - verify no old working-name strings remain in implementation docs
- **GREEN**
  - create App Store Connect record
  - create Apple bundle ID
  - reserve/configure `roadsense.ca`
  - create Supabase project in `us-east-1`
  - create Sentry projects for iOS and backend
- **Acceptance**
  - all credentials/secrets named in [05](05-deployment-and-observability.md) are provisioned
  - privacy policy placeholder URL is resolvable at `roadsense.ca/privacy` before external TestFlight

### B002 — Repo scaffold and CI skeleton

- **Spec refs:** [05](05-deployment-and-observability.md)
- **Depends on:** B001
- **RED**
  - CI jobs stubbed and failing for missing implementation rather than absent workflow
- **GREEN**
  - create `ios/`, `supabase/`, `scripts/` structure if missing
  - add `ios-ci.yml`
  - add `backend-ci.yml`
  - wire basic lint/build/test commands
- **Acceptance**
  - PRs run CI
  - CI fails loudly on broken migrations, Deno tests, or iOS build breaks

## Phase 2 — Backend Foundation

### B010 — Initial Postgres schema migrations

- **Spec refs:** [02](02-backend-implementation.md)
- **Depends on:** B002
- **RED**
  - pgTAP tests for table existence, column types, indexes, enums, RLS policies
- **GREEN**
  - implement migrations for `road_segments`, `readings`, `segment_aggregates`, `processed_batches`, `pothole_reports`, supporting enums, and indexes
  - enable PostGIS and pg_cron
- **Acceptance**
  - `supabase db reset` succeeds from zero
  - schema tests pass
  - RLS matches documented read/write boundaries

### B011 — OSM import and segmentization pipeline

- **Spec refs:** [02](02-backend-implementation.md), [05](05-deployment-and-observability.md)
- **Depends on:** B010
- **RED**
  - fixture import test for a small OSM subset
  - SQL assertions for segment counts, `osm_way_id/segment_index` uniqueness, municipality tagging, feature tagging
- **GREEN**
  - implement `osm-import.sh`, `osm2pgsql-style.lua`, `segmentize.sql`, `tag-municipalities.sql`, `tag-features.sql`
  - implement `road_segments_staging`
  - implement `apply_road_segment_refresh()` (initial import path — merge staging into empty `road_segments`; rematch of existing readings is B100, post-MVP)
- **Acceptance**
  - Halifax fixture import produces stable segment rows
  - production-scale import path is documented and re-runnable

### B013 — Batch ingestion stored procedure

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B010
- **RED**
  - pgTAP tests for:
    - happy path
    - malformed/invalid payload rejection boundaries
    - duplicate batch replay
    - concurrent duplicate retries
    - rejection-reason accounting
    - unpaved/no-match handling
- **GREEN**
  - implement `ingest_reading_batch`
  - implement temp-table validation flow
  - persist replayable `rejected_reasons`
  - add advisory lock/idempotency claim flow
- **Acceptance**
  - duplicate retries are deterministic
  - no PK-race surfaces as 5xx
  - returned payload shape matches [03](03-api-contracts.md)

### B014 — Incremental aggregate updates and pothole folding

- **Spec refs:** [02](02-backend-implementation.md)
- **Depends on:** B013
- **RED**
  - pgTAP tests for weighted average math, category thresholds, confidence thresholds, pothole folding behavior
- **GREEN**
  - implement `update_segment_aggregates_from_batch`
  - implement `fold_pothole_candidates`
- **Acceptance**
  - accepted readings immediately affect publishable aggregates as documented

### B015 — Nightly recompute and pothole expiry

- **Spec refs:** [02](02-backend-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B014
- **RED**
  - pgTAP tests for trend calculation, trimming, recency handling, contributor caps
  - scheduled-job integration test for cron registrations
- **GREEN**
  - implement `nightly_recompute_aggregates`
  - implement `expire_unconfirmed_potholes`
  - add cron schedules
- **Acceptance**
  - recompute can run on a touched-segment subset
  - expiry and recompute jobs are idempotent

## Phase 3 — Read APIs And Public Data Surfaces

### B020 — Quality tile endpoint

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B014
- **RED**
  - Deno/contract tests for 200 vs 204 behavior, headers, and source layers
  - SQL-level verification that low-confidence segments are excluded
- **GREEN**
  - implement `get_tile`
  - implement tiles Edge Function
- **Acceptance**
  - tile endpoint serves MVT with stable attributes and proper cache headers

### B021 — Segment, potholes, stats, and health endpoints

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B014
- **RED**
  - contract tests for `/segments/{id}`, `/potholes`, `/stats`, `/health`
  - pgTAP tests for `public_stats_mv` (including the singleton-column unique index required by `REFRESH ... CONCURRENTLY`), `get_potholes_in_bbox(...)`, and `db_healthcheck()`
  - scheduled-job integration test that the `refresh-public-stats-mv` cron entry is registered in Migration 011
- **GREEN**
  - implement the read wrappers and SQL backing views/functions
  - implement direct cron refresh of `public_stats_mv` using `REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv`
  - schedule the `refresh-public-stats-mv` cron in Migration 011
- **Acceptance**
  - all documented read endpoints exist and match spec
  - `public_stats_mv` refresh runs under the Small Supabase instance without blocking `/stats` reads

### B022 — Rate limiting and abuse checks in Edge Function

- **Spec refs:** [02](02-backend-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** B013
- **RED**
  - Deno tests for per-device and per-IP limits
  - test `Retry-After` behavior
- **GREEN**
  - implement upload Edge Function validation, hashing, and limiter calls
- **Acceptance**
  - service-role boundary is server-side only
  - request IDs appear in logs/responses where documented

## Phase 4 — iOS Foundation

### B030 — Xcode project and dependency setup

- **Spec refs:** [01](01-ios-implementation.md), [05](05-deployment-and-observability.md)
- **Depends on:** B001, B002
- **RED**
  - CI build target created and failing for missing app code rather than missing project
- **GREEN**
  - bootstrap `ios/` with a Foundation-only Swift package for config/runtime seams
  - add committed base `.xcconfig` files for local / staging / production
  - add ignored `.secrets.xcconfig` override convention for developer- or CI-only values
  - add a generator spec for the real Xcode project
  - create the actual Xcode project and verify `xcodegen generate` succeeds from a clean checkout
  - add SPM dependencies: Mapbox, Supabase, Sentry
  - set up configs/schemes
- **Acceptance**
  - bootstrap package tests pass on CI and local machine
  - empty shell Xcode app target generates successfully from repo state alone
  - first simulator build is blocked, if at all, by real app/dependency issues rather than missing project/config files

### B031 — App configuration and environment handling

- **Spec refs:** [01](01-ios-implementation.md)
- **Depends on:** B030
- **RED**
  - unit tests for config parsing and environment selection
- **GREEN**
  - implement `AppConfig`
  - support configurable API base URL
  - keep Supabase function base path configurable
- **Acceptance**
  - no hardcoded production-only domains inside app code

### B032 — Permission flow and app lifecycle shell

- **Spec refs:** [01](01-ios-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** B030
- **RED**
  - unit tests for permission-state mapping
  - UI tests for onboarding states
- **GREEN**
  - implement onboarding shell
  - wire motion/location permission requests in the documented order
  - add required usage strings and background mode config
- **Acceptance**
  - app can request permissions with correct copy and config

### B033 — Sensor service wrappers

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B032
- **RED**
  - unit tests with protocol-backed motion/location mocks
- **GREEN**
  - implement wrappers around `CMMotionManager`, `CMMotionActivityManager`, and `CLLocationManager`
- **Acceptance**
  - services are mockable and isolated from pipeline logic

### B034 — SwiftData local models and queue state

- **Spec refs:** [01](01-ios-implementation.md)
- **Depends on:** B030
- **RED**
  - persistence tests for reading windows, upload queue items, token rotation state, and privacy zones
- **GREEN**
  - implement SwiftData models
  - implement local queue and cleanup policies
- **Acceptance**
  - app can persist pending upload state across relaunch

## Phase 5 — End-To-End Stub Loop

### B040 — Reading window assembly

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B033, B034
- **RED**
  - unit tests for windowing by distance/time
  - simulator harness fixture replay
- **GREEN**
  - implement `ReadingBuilder`
  - produce POINT reading payloads from sensor streams
- **Acceptance**
  - app can generate uploadable reading batches from replayed fixtures

### B041 — Stub uploader path

- **Spec refs:** [01](01-ios-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B040, B022
- **RED**
  - unit tests for batch-id reuse and retry behavior
  - integration test against staging/local upload endpoint
- **GREEN**
  - implement uploader client
  - send hardcoded or stubbed readings first, then real assembled readings
- **Acceptance**
  - iOS can upload a batch and receive a valid response

### B042 — End-to-end smoke from phone to map

- **Spec refs:** [00](00-execution-plan.md), [04](04-testing-and-quality.md)
- **Depends on:** B020, B021, B041
- **RED**
  - staging smoke checklist
- **GREEN**
  - drive or replay data through full path
- **Acceptance**
  - one real or replayed batch appears in `readings`, aggregates update, tile renders, app map can display it

## Phase 6 — Scoring, Privacy, And Publishability

### B050 — Roughness scorer and pothole detector

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B040
- **RED**
  - deterministic scorer tests
  - pothole detection tests against synthetic and real fixtures
- **GREEN**
  - implement `RoughnessScorer`
  - implement `PotholeDetector`
- **Acceptance**
  - scores are stable under fixture replay

### B051 — Client-side privacy zones

- **Spec refs:** [01](01-ios-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** B032, B034
- **RED**
  - unit tests for zone inclusion/exclusion and randomized offsets
  - UI tests for first-run privacy-zone gating
- **GREEN**
  - implement privacy-zone storage, filtering, and onboarding requirement
- **Acceptance**
  - passive collection cannot silently start without privacy-zone decision
  - server never receives filtered-zone readings

### B052 — Quality filters and uploader hardening

- **Spec refs:** [01](01-ios-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B041, B050
- **RED**
  - truth-table tests for GPS accuracy, speed, thermal, and activity gates
  - retry tests for network failure, 429, and permanent 400
- **GREEN**
  - implement `QualityFilter`
  - finish uploader backoff and permanent-failure handling
- **Acceptance**
  - app behaves exactly per documented retry rules

### B053 — Mapbox map and segment detail UI

- **Spec refs:** [01](01-ios-implementation.md)
- **Depends on:** B042
- **RED**
  - UI tests for map shell, selection, and detail drawer
- **GREEN**
  - implement map screen
  - load quality tiles
  - implement segment detail fetch
- **Acceptance**
  - user can tap a segment and see the documented detail sheet

## Phase 7 — Reliability, Observability, And UX Hardening

### B060 — Background execution and relaunch handling

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B040, B051
- **RED**
  - real-device test plan for lock-screen, background drive, and system-termination recovery
- **GREEN**
  - implement SLC bootstrap and safe background behavior
- **Acceptance**
  - app survives documented background scenarios short of user force-quit

### B061 — Sentry, structured logs, and ops metrics

- **Spec refs:** [05](05-deployment-and-observability.md), [06](06-security-and-privacy.md)
- **Depends on:** B022, B030
- **RED**
  - integration test or manual verification checklist for crash/event capture without PII leakage
- **GREEN**
  - wire Sentry Cocoa and Deno SDKs
  - emit structured batch logs
  - increment `ops_metrics`
- **Acceptance**
  - crashes/errors are visible
  - logs do not include forbidden fields

### B062 — Stats, settings, and trust copy

- **Spec refs:** [01](01-ios-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** B053
- **RED**
  - UI tests for settings actions and stats rendering
- **GREEN**
  - implement stats screen
  - implement settings and local data deletion
  - ensure privacy/freshness/confidence copy matches docs
- **Acceptance**
  - a new user can find pause, privacy zones, and delete-local-data controls without assistance

### B063 — Accessibility and Dynamic Type pass

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B062
- **RED**
  - test matrix for large accessibility text sizes
  - VoiceOver/manual checklist
- **GREEN**
  - adjust layouts for onboarding, map chrome, segment drawer, stats, and settings
- **Acceptance**
  - core flows remain usable at large text sizes

## Phase 8 — TestFlight Readiness

### B070 — Internal field-test pack

- **Spec refs:** [00](00-execution-plan.md), [04](04-testing-and-quality.md), [05](05-deployment-and-observability.md)
- **Depends on:** B060, B061, B062
- **RED**
  - explicit field-test checklist
- **GREEN**
  - run multi-device drives
  - validate battery drain, background collection, and aggregate believability
- **Acceptance**
  - internal testers can dogfood daily

### B071 — App Store privacy and metadata lock

- **Spec refs:** [05](05-deployment-and-observability.md), [06](06-security-and-privacy.md)
- **Depends on:** B070
- **RED**
  - pre-submission checklist matching manifest, labels, and actual data flow
- **GREEN**
  - fill App Store privacy labels
  - publish privacy policy
  - complete Test Information and screenshots
- **Acceptance**
  - App Store Connect answers match the implementation docs exactly

### B072 — External TestFlight launch

- **Spec refs:** [00](00-execution-plan.md), [05](05-deployment-and-observability.md)
- **Depends on:** B071
- **RED**
  - release checklist
- **GREEN**
  - upload build
  - distribute to external testers on approval
- **Acceptance**
  - testers can install and submit reproducible bug reports

## Phase 9 — Web Backend Additions

Start only after the iOS/TestFlight MVP is live or intentionally paused.

### B080 — Coverage tile backend

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md), [07](07-web-dashboard-implementation.md)
- **Depends on:** B020, B021
- **RED**
  - Deno contract tests for `/tiles/coverage/{z}/{x}/{y}.mvt`
  - SQL verification of `coverage_level` derivation
- **GREEN**
  - implement `get_coverage_tile`
  - implement `tiles-coverage` Edge Function
- **Acceptance**
  - web Coverage mode has a truthful backend surface

### B081 — Worst-roads backend

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md), [07](07-web-dashboard-implementation.md)
- **Depends on:** B021
- **RED**
  - pgTAP tests for `public_worst_segments_mv`
  - Deno contract tests for `/segments/worst`
- **GREEN**
  - implement `public_worst_segments_mv` (with a unique index on `segment_id` so `REFRESH ... CONCURRENTLY` is usable)
  - implement `refresh_public_worst_segments_mv()` using `REFRESH MATERIALIZED VIEW CONCURRENTLY`
  - schedule the `refresh-public-worst-segments-mv` cron (Phase 9 only — the MVP stats refresh is scheduled separately in Migration 011)
  - implement `segments-worst` Edge Function
- **Acceptance**
  - report page can query ranked rows cheaply and deterministically
  - refreshing `public_worst_segments_mv` does not block reads from `/segments/worst`

## Phase 10 — Web Dashboard Frontend

### B090 — Web app shell and routing

- **Spec refs:** [07](07-web-dashboard-implementation.md), [05](05-deployment-and-observability.md)
- **Depends on:** B080, B081
- **RED**
  - route tests for `/`, `/municipality/[slug]`, `/reports/worst-roads`, `/methodology`, `/privacy`
- **GREEN**
  - scaffold `apps/web/`
  - implement app shell, design tokens, route skeletons, municipality manifest
- **Acceptance**
  - route shells render without client-side waterfalls

### B091 — Quality map and segment drawer

- **Spec refs:** [07](07-web-dashboard-implementation.md)
- **Depends on:** B090
- **RED**
  - component tests for shell and drawer
  - Playwright test for selecting a segment
- **GREEN**
  - implement quality map
  - implement drawer and route-state sync
- **Acceptance**
  - public web map can show quality data and segment detail

### B092 — Search and potholes mode

- **Spec refs:** [07](07-web-dashboard-implementation.md)
- **Depends on:** B091
- **RED**
  - tests for municipality-first search
  - Playwright tests for potholes mode behavior
- **GREEN**
- implement search and potholes mode

### B110 — Pothole follow-up UX

- **Spec refs:** [01](01-ios-implementation.md), [07](07-web-dashboard-implementation.md)
- **Depends on:** B050, B021
- **RED**
  - UX copy/test plan for expiring “pothole still there?” prompts
  - contract tests if this becomes a backend endpoint rather than local notification only
- **GREEN**
  - implement expiring confirmation prompt similar to Waze incident confirmation
  - optionally allow photo attachment on manual pothole reports if privacy/storage tradeoffs are explicitly accepted
- **Acceptance**
  - follow-up prompts expire automatically and never fire while driving
  - photo upload remains optional and is not required for pothole confirmation
- **Acceptance**
  - search resolves municipalities and places correctly

### B093 — Coverage mode and worst-roads page

- **Spec refs:** [07](07-web-dashboard-implementation.md)
- **Depends on:** B092, B080, B081
- **RED**
  - component and Playwright tests for Coverage mode and report page
- **GREEN**
  - implement Coverage mode
  - implement `Worst Roads` page
- **Acceptance**
  - both web-only surfaces run on real backend data

### B094 — Methodology, privacy, accessibility, and deployment hardening

- **Spec refs:** [07](07-web-dashboard-implementation.md), [05](05-deployment-and-observability.md), [06](06-security-and-privacy.md)
- **Depends on:** B093
- **RED**
  - content-page tests
  - accessibility checks
  - preview deploy smoke tests
- **GREEN**
  - implement content pages
  - add `web-ci.yml`
  - wire Vercel preview/production config
- **Acceptance**
  - web app meets the documented accessibility, privacy, and deploy requirements

## Phase 11 — Post-MVP Operational Procedures

These tasks ship **after** MVP TestFlight launch. They exist on a quarterly cadence (OSM changes slowly) and should not block any release. Picking them up mid-MVP just because the import pipeline looks adjacent is a common cause of scope creep — don't.

### B100 — OSM refresh rematch path

- **Spec refs:** [02](02-backend-implementation.md), [05](05-deployment-and-observability.md)
- **Depends on:** B011, B014, B015 (needs real `nightly_recompute_aggregates` to drive targeted recompute after rematch)
- **Why post-MVP:** this only matters on the *second* OSM import (first import is into an empty `road_segments` where there is nothing to rematch). Between MVP launch and the first quarterly refresh, no functionality is lost. Building it before MVP means maintaining and retesting a branch of code that nothing exercises.
- **RED**
  - pgTAP tests for rematching touched readings after a segment refresh (geometry change, segment split, segment deletion)
  - test that aggregate rows for impacted segments are reconciled after running `nightly_recompute_aggregates(rematch_readings_after_segment_refresh())`
  - test that readings whose nearest paved segment disappeared get `segment_id = NULL` rather than a wrong match
- **GREEN**
  - implement `rematch_readings_after_segment_refresh()` body (KNN + heading matcher, bounded by `p_since`)
  - wire the (apply → rematch → recompute) sequence into the operational runbook in [05](05-deployment-and-observability.md) with a session-level `statement_timeout` and an off-peak window
  - add monitoring for the rematch run (duration, touched-segment count, orphaned-reading count)
- **Acceptance**
  - changed segment geometry can be re-imported without orphaning retained readings
  - quarterly refresh completes inside its documented operational budget on production-scale data
  - `/stats` and the quality map reflect the post-refresh world within one nightly cycle

## Suggested PR Slicing

Keep changes narrow. A good slicing strategy:

1. schema and pgTAP only
2. OSM import pipeline only
3. upload procedure + function only
4. read APIs only
5. iOS project shell only
6. sensor pipeline only
7. uploader only
8. map UI only
9. privacy/settings/stats only
10. observability + release polish
11. web backend additions only
12. web frontend vertical slices

## Hard Stop Rules

Stop and reassess if:

- the upload contract changes after iOS implementation starts
- background collection fails repeatedly on real devices despite spec-compliant setup
- nightly recompute exceeds its documented operational budget
- Coverage mode or `Worst Roads` requires raw-reading exposure to feel useful
- App Store privacy answers no longer match actual data flow

These are architecture warnings, not "keep pushing harder" tasks.
