# 08 — Implementation Backlog

*Last updated: 2026-04-25*

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
12. Android follow-on once iOS collection/scoring is stable

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
- **Current repo note:** The repo-side environment plumbing is now in place: GitHub Environments named `staging` and `production` exist, and deploy workflows target them. A dedicated hosted `roadsense-staging` project is intentionally deferred until Apple approval and signed multi-device testing make a shared backend worthwhile. Until then, local Supabase plus CI is the default.

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
- **Current repo note:** The workflow files now exist and are useful, but automatic triggers are intentionally disabled again until Apple approval and signed/shared testing make the minutes worth spending. For now these remain manual guardrails, not always-on branch protection.

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
- **Current repo note:** this slice is implemented and the import path is now parameterized for any single Canadian province/territory via `REGION_KEY`, `load-municipalities.sh`, and `osm-import.sh`. It also includes local fixes for modern `osm2pgsql` `way_id` output and scalable feature tagging on million-segment imports. A true multi-province / national deployment is still a separate slice because the public municipality surface is name-only today and the app/backend runtime still contains Nova Scotia-specific bounds and copy.

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
- **Current repo note:** Production `LocationService`, `MotionService`, `DrivingDetector`, and `ThermalMonitor` wrappers now exist in the app target, and the main `RoadSenseNS` target now builds for `iphonesimulator` with Mapbox and Sentry linked. A product-style `MapScreen`, live Mapbox tile rendering, tap selection, and typed segment-detail fetch/presentation are now in place. Remaining work is real-device signing/install validation and product polish on top of the now-live map shell.

### B034 — SwiftData local models and queue state

- **Spec refs:** [01](01-ios-implementation.md)
- **Depends on:** B030
- **RED**
  - persistence tests for reading windows, upload queue items, token rotation state, and privacy zones
  - migration test fixture proving schema v1 opens cleanly under the explicit `SchemaMigrationPlan`
- **GREEN**
  - implement SwiftData models
  - implement local queue and cleanup policies
  - wire explicit `VersionedSchema` / `SchemaMigrationPlan` instead of implicit migration
- **Acceptance**
  - app can persist pending upload state across relaunch
  - app-hosted test can open a prior-schema store without data loss
- **Current repo note:** `ModelContainerProvider`, `PrivacyZoneStore`, and `UploadQueueStore` now land this slice beyond just model definitions. Relauch persistence still needs app-target validation.

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
- **Current repo note:** The app target now has a first `SensorCoordinator` that runs `ReadingBuilder` against live streams and persists accepted windows through `ReadingStore`. What remains is fixture replay, checkpoint persistence, and app-target validation.
- **Current repo note:** `SensorCheckpoint` + `SensorCheckpointStore` now exist and the coordinator checkpoints every 60 seconds. What remains is fixture replay and app-target validation.
- **Current repo note:** `SensorFixtureParser` + `SensorFixtureRunner` now exist in the pure Swift layer, the bootstrap suite auto-discovers checked-in `Fixtures/*.csv` + `Fixtures/*.expected.json` resources, and `RoadSenseNSSimHarness` now replays the same fixture pattern in a lightweight developer app. The deterministic fixture corpus now covers pothole, smooth-cruise, privacy-zone recovery, and thermal rejection scenarios. What remains is adding more captured-drive fixtures and keeping the harness target green in CI.

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
- **Current repo note:** `UploadRequestFactory`, `UploadResponseParser`, `APIClient`, and `Uploader` now exist. `RoadSenseNSTests` has upload-path coverage, the host app enters an inert in-memory bootstrap mode under XCTest, and the local simulator path is green. What remains is ongoing real-device/shared-backend validation rather than the absence of a local runtime smoke path.

### B042 — End-to-end smoke from phone to map

- **Spec refs:** [00](00-execution-plan.md), [04](04-testing-and-quality.md)
- **Depends on:** B020, B021, B041
- **RED**
  - staging smoke checklist
  - scripted API smoke (`./scripts/api-smoke.sh`) for `/health`, `/stats`, and duplicate-safe `/upload-readings`
  - seeded backend smoke (`./scripts/seeded-e2e-smoke.sh`) proving upload → aggregate → segment detail → tile on a synthetic paved segment
- **GREEN**
  - drive or replay data through full path
- **Acceptance**
  - one real or replayed batch appears in `readings`, aggregates update, tile renders, app map can display it
- **Current repo note:** The deterministic backend smoke layer is now in place: `./scripts/api-smoke.sh` and `./scripts/seeded-e2e-smoke.sh` run in backend CI, and the repo now includes `deploy-staging.yml` / `deploy-production.yml` for later hosted deploys. What still remains is the human drive/replay pass and, later, provisioning a shared hosted env if signed testers need one.

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
- **Current repo note:** `PotholeDetector` and `RoughnessScorer` are now both wired into the live `SensorCoordinator` path. `ReadingBuilder` scores the high-pass-filtered vertical acceleration stream instead of the earlier direct-RMS placeholder, and the replay fixtures now assert that filtered scale directly. The first single-tester iPhone dump looks directionally believable under the current thresholds, and `scripts/local-ios-quality-report.sh` now captures the repeatable local analysis path. Remaining work is known-road real-device calibration, speed normalization, and future per-vehicle normalization if harsher-riding cars prove to bias the score distribution.

### B051 — Drive endpoint trimming and optional privacy zones

- **Spec refs:** [01](01-ios-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** B032, B034
- **RED**
  - unit tests for endpoint time/radius trimming, fully-trimmed short drives, and relaunch-stable trimming decisions
  - unit tests for zone inclusion/exclusion and randomized offsets
  - UI tests proving passive collection can start without zones and that zones remain reachable from ready/settings states
- **GREEN**
  - implement drive endpoint trimming on sealed sessions
  - implement privacy-zone storage and filtering as optional extra protection
- **Acceptance**
  - passive collection starts after the required permissions alone
  - server never receives endpoint-trimmed or filtered-zone readings
- **Current repo note:** this slice is now materially implemented: onboarding/settings can open the real `PrivacyZonesView` + `PrivacyZoneStore`, the editor is map-backed, `SensorCoordinator` applies zone filtering during collection, and sealed `DriveSessionRecord`s now gate readings until endpoint trimming marks them uploadable. The new unit coverage exercises the time/radius trim rules, fully-private short drives, and the abandoned-session seal path. Remaining work is real-device validation of the combined privacy flow.

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
- **Current repo note:** This slice is now materially implemented: `MapScreen` replaced the debug shell, `RoadQualityMapView` renders live backend vector tiles through Mapbox, potholes render on-map, pending local drives render as a dashed teal overlay, segment taps highlight via feature-state, the existing `SegmentDetailSheet` is presented from real `GET /segments/{id}` fetches, and simulator UI smokes cover shell/settings/privacy-editor navigation through a deterministic non-Mapbox testing surface. Remaining work is deeper drawer-selection UI coverage and real-device field validation.

## Phase 7 — Reliability, Observability, And UX Hardening

### B064 — Field-test hardening gate: crash containment, local truth, and upload reconciliation

- **Spec refs:** [01](01-ios-implementation.md), [03](03-api-contracts.md), [04](04-testing-and-quality.md), [09](09-internal-field-test-pack.md)
- **Depends on:** B053, B060, B072-range upload execution
- **Why now:** the first real-device field test exposed fragility that is more important than new features: a missing camera usage key caused a TCC kill mid-drive, SwiftData schema drift caused launch crashes on rebuild, manually replayed readings stayed pending on-device, and the phone map did not make it obvious what had been captured locally.
- **RED**
  - app-target migration tests prove legacy SwiftData stores open under the current schema and unreadable stores are backed up before reset
  - XCTest for local map overlay data: accepted in-progress / upload-ready readings are visible locally; uploaded, privacy-zone-dropped, and endpoint-trimmed readings are hidden from the local overlay
  - pgTAP test for cross-batch replay: the same device/coordinate/timestamp readings uploaded under a different `batch_id` do not create new `readings` rows or double-fold `segment_aggregates`
  - plist/build verification asserts the final built app contains `NSCameraUsageDescription` and all `BGTaskSchedulerPermittedIdentifiers`
  - manual real-device checklist: camera denied/allowed, foreground drive, lock-screen drive, app relaunch after crash, and upload retry after network loss
- **GREEN**
  - keep explicit SwiftData schema versions for every shipped local model version and recover unreadable stores by backup-and-reset instead of crashing on launch
  - show a local roughness-colored route overlay from on-device readings before upload so a tester can confirm capture without waiting for the backend tile loop
  - harden backend ingestion with cross-batch duplicate suppression keyed by device hash, recorded timestamp, and near-identical coordinate
  - preflight camera authorization and make camera setup failures user-visible, not a black-screen dead end
  - add diagnostics copy that distinguishes "recorded locally", "ready to upload", "uploaded", "server rejected", and "manually replayed / stale pending"
- **Acceptance**
  - rebuild/install/open cycles do not crash even when a device already has prior local data
  - a tester can see the route being captured on the phone map during or immediately after a drive
  - retrying or manually replaying a captured batch cannot double-count public roughness data
  - tapping camera without prior permission prompts or shows a recoverable Settings state; it never kills collection
  - pending-upload counts are no longer treated as the source of truth without corresponding diagnostics

### B065 — Recording-state UX and drive/session language cleanup

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B064
- **Why now:** users think in trips/drives, not backend segments. The active-drive state must answer "is it working?" in under five seconds.
- **RED**
  - UI/view-model tests for state copy: idle, waiting for movement, recording, GPS stale, paused by user, background permission missing, upload retrying, and upload complete
  - XCTest for grouped-trip stats: short detector fragments separated by small gaps count as one user-visible trip
  - manual Dynamic Type/VoiceOver check for the active-drive banner and mark/photo CTAs
- **GREEN**
  - rename user-facing "segments" and "uploads waiting" copy to trips/drives/readings where appropriate
  - make the in-progress recording state persistent and prominent while the app is open
  - show last GPS fix age and last recorded reading age in diagnostics, not in the primary UI
  - keep `Mark pothole` prominent only while actively driving/open; keep `Take photo` lower-priority and available when a fresh location exists
- **Acceptance**
  - a first-time tester can tell whether RoadSense is recording, waiting, blocked, or uploading without opening Settings
  - stats describe drives/trips and km, not implementation-only segment counts

### B066 — Camera and manual-report fault isolation

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md), [06](06-security-and-privacy.md)
- **Depends on:** B064
- **RED**
  - XCTest or reducer tests for photo preflight states: authorized, not determined, denied, restricted, unavailable camera hardware, and setup failure
  - app-target test that photo submission uses the same fresh-location validator as manual pothole marking but does not require the device to be stopped
  - manual real-device test: camera open/cancel/submit does not break subsequent `Mark pothole`
- **GREEN**
  - separate camera authorization from capture-session setup and surface setup failure as a closeable error state
  - keep photo capture optional and passenger-friendly: warn while moving but do not block solely on speed
  - preserve the latest usable GPS sample for mark/photo flows even if Mapbox still has an older puck location
  - ensure dismissing a failed camera flow returns to the map with pothole marking still enabled
- **Acceptance**
  - no black camera screen without explanatory copy
  - no camera path can poison GPS state or disable manual pothole marking for the rest of a drive

### B067 — Internal diagnostics and data offload tooling

- **Spec refs:** [04](04-testing-and-quality.md), [05](05-deployment-and-observability.md), [09](09-internal-field-test-pack.md)
- **Depends on:** B064
- **RED**
  - script test against a copied `default.store` fixture covering reading counts, last reading time, upload-ready counts, endpoint-trimmed counts, pothole action states, and drive-session ranges
  - docs checklist that every field-test issue records build, backend target, route window, pending queue counts, and whether a manual replay was used
- **GREEN**
  - add a local script that summarizes a pulled iOS SwiftData store without requiring ad hoc SQL
  - write offload/replay notes into `.context/` for each manual field-test import
  - expose the same key counts in Settings diagnostics for tester self-reporting
- **Acceptance**
  - after a test drive, we can answer "what exists on phone?", "what landed in backend?", and "what is stale/pending?" from one repeatable workflow

### B060 — Background execution and relaunch handling

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B040, B051
- **RED**
  - real-device test plan for lock-screen, background drive, and system-termination recovery
- **GREEN**
  - implement SLC bootstrap and safe background behavior
- **Acceptance**
  - app survives documented background scenarios short of user force-quit
- **Current repo note:** `BackgroundCollectionPolicy`, `BackgroundTaskRegistrar`, aligned background task IDs (`nightly-cleanup`, `upload-drain`), significant-location-change passive monitoring, moving-GPS collection bootstrap, and fresh-checkpoint service resume are now implemented. Settings also exposes drive diagnostics for the last GPS sample, driving signal, collection start/stop, and bump candidate. Remaining work is signed real-device validation for lock-screen, background, and system-termination scenarios.

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
- **Current repo note:** `RoadSenseLogger` and a guarded `SentryBootstrapper` now exist. Sentry remains linked; manual verification still needs to confirm that no forbidden fields are logged.

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
- **Current repo note:** `StatsView` and `SettingsView` now exist, including Always-upgrade, privacy-zone management entrypoint, delete-local-data controls, and explicit modal close affordances. Simulator UI smokes now exercise the Settings -> Privacy Zones path, seeded stats rendering, and delete-local-data behavior from a seeded ready shell. What remains is product polish around the live map plus broader app-target validation.

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
- **Current repo note:** this slice is now materially implemented in the simulator path: `OnboardingFlowView` is scroll-safe at large sizes, the app accepts a deterministic `ROAD_SENSE_DYNAMIC_TYPE_SIZE` override for UI automation, and UI smokes now verify the permissions-first onboarding plus stats/settings usability at `accessibility5`. Remaining work is VoiceOver and real-device validation, not the absence of a large-text test path.

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
- **Current repo note:** the repo now includes an explicit execution checklist in [09-internal-field-test-pack.md](09-internal-field-test-pack.md), and the CI/deploy side now covers the full simulator suite plus backend smoke before a build is handed to humans. The remaining work here is signed-device execution and evidence capture, not missing repo automation.

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
- **Current repo note:** The repo now has a dedicated source-of-truth checklist in [10-app-store-and-testflight-readiness.md](10-app-store-and-testflight-readiness.md) covering App Store Connect fields, privacy labels, reviewer notes, archive checks, and internal/external TestFlight prep. The public web `/privacy` route also now carries fuller policy content instead of only trust-marketing copy. The remaining work is Apple-account execution, not deciding the answers from scratch.

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
- **Current repo note:** This remains blocked on Apple Developer approval and the first signed internal build cycle. The repo-side release checklist and privacy-label/source-of-truth work can be completed before that approval lands.

### B072a — Feedback and issue submission across app and web

- **Spec refs:** [00](00-execution-plan.md), [05](05-deployment-and-observability.md), [06](06-security-and-privacy.md)
- **Depends on:** B071, B072
- **Why public-readiness:** once testers/users are outside the immediate team, screenshots and chat notes are not enough. The iOS app and public web map both need a low-friction way to send feature ideas, bug reports, confusing-map feedback, and local road-quality corrections into one triage queue.
- **RED**
  - iOS view-model tests for required text, category selection, optional email/reply consent, offline queueing, retry, and submission success/failure states
  - web component/route tests for opening feedback from the public map/report pages, submitting validation errors, and showing a non-blocking success state
  - Deno/SQL tests for `POST /feedback`: payload validation, rate limiting, spam-sized body rejection, request-id capture, and no public read access
  - privacy test/checklist proving feedback does not automatically attach precise location, raw sensor data, screenshots, or device logs unless the user explicitly opts in
- **GREEN**
  - add iOS Settings/help entry point: `Submit feedback`
  - add web entry points from the footer/top nav and map/report surfaces, using the same categories and backend contract
  - categories: bug, feature suggestion, map/road data issue, pothole issue, privacy/safety concern, other
  - collect typed message plus optional reply email; include app/web version, platform, coarse locale/municipality, and current route/screen for debugging
  - add a private backend table/Edge Function for feedback, protected by rate limits and service-role-only reads
  - define the triage sink for MVP, e.g. private GitHub issue creation, email digest, or internal admin export; do not expose feedback publicly
- **Acceptance**
  - a public tester can submit useful feedback from iOS or the web map without leaving the product or emailing manually
  - feedback is visible to maintainers with enough context to reproduce or prioritize
  - the user-facing copy clearly says what metadata is included and whether they can be contacted

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
- **Current repo note:** this slice is now implemented: `get_coverage_tile` exists in SQL, `tiles-coverage` serves the public MVT contract through a service-role RPC wrapper, and both pgTAP plus Deno contract tests cover the path.

### B081 — Worst-roads backend

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md), [07](07-web-dashboard-implementation.md)
- **Depends on:** B021
- **RED**
  - pgTAP tests for `public_worst_segments_mv`
  - Deno contract tests for `/segments/worst`
- **GREEN**
  - implement `public_worst_segments_mv` (with a unique index on `segment_id` so `REFRESH ... CONCURRENTLY` is usable)
  - schedule the `refresh-public-worst-segments-mv` cron (Phase 9 only — the MVP stats refresh is scheduled separately in Migration 011)
  - implement `segments-worst` Edge Function
- **Acceptance**
  - report page can query ranked rows cheaply and deterministically
  - refreshing `public_worst_segments_mv` does not block reads from `/segments/worst`
- **Current repo note:** this slice is now implemented: `public_worst_segments_mv` exists with the required unique/indexed shape, the cron refresh runs `REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv` directly, and `segments-worst` now exposes the ranked public report contract through a service-role Edge Function with pgTAP + Deno coverage.

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
- **Current repo note:** this slice is now implemented under `apps/web/`: Next.js App Router route shells exist for `/`, `/municipality/[slug]`, `/reports/worst-roads`, `/methodology`, and `/privacy`; the static municipality manifest and URL-state helpers are in place; and unit tests plus `next build` validate the shell without a client-side waterfall.

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
- **Current repo note:** this slice is now materially implemented under `apps/web/`: the public explorer uses a client-side route-state shell, the quality mode renders through Mapbox GL JS and the backend vector-tile endpoint when `NEXT_PUBLIC_MAPBOX_TOKEN` is configured, the drawer fetches live `GET /segments/{id}` detail, and component tests plus `next build` validate the mode-switcher, drawer states, and route integration. `Potholes` and `Coverage` route-state affordances are present but their dedicated map sources remain queued for `B092`/`B093`.

### B092 — Search and potholes mode

- **Spec refs:** [07](07-web-dashboard-implementation.md)
- **Depends on:** B091
- **RED**
  - tests for municipality-first search
  - Playwright tests for potholes mode behavior
- **GREEN**
  - implement search and potholes mode
- **Current repo note:** this slice is now materially implemented under `apps/web/`: municipality-first search is live against the static manifest, including alias matching and ranked suggestions, an optional Nova Scotia-scoped Mapbox place-search fallback is available when there is no municipality match, recoverable no-results and clear-search behavior are in place, and `Potholes` mode isolates the pothole layer plus a viewport-bounded pothole drawer feed with explicit trust/empty-state copy. Browser-level end-to-end verification is already in place; the remaining work is hosted-environment validation rather than missing core behavior.

### B110 — Pothole follow-up UX

- **Spec refs:** [01](01-ios-implementation.md), [07](07-web-dashboard-implementation.md)
- **Depends on:** B075, B021
- **RED**
  - UX copy/test plan for when to suppress, defer, or re-show expiring follow-up prompts
  - web trust-copy tests explaining `active` vs `resolved` pothole semantics
- **GREEN**
  - tune expiring confirmation prompts similar to Waze incident confirmation
  - optionally allow photo attachment from the follow-up flow if privacy/storage tradeoffs are explicitly accepted
  - add clear public-copy treatment for resolved potholes on the web/dashboard surfaces
- **Acceptance**
  - follow-up prompts expire automatically and never fire while driving
  - photo upload remains optional and is not required for pothole confirmation
  - web/public copy does not imply that one user can instantly delete a pothole marker

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
- **Current repo note:** this slice is now materially implemented under `apps/web/`: Coverage mode swaps the map to the dedicated `GET /tiles/coverage/{z}/{x}/{y}.mvt` source, and `/reports/worst-roads` fetches live `GET /segments/worst` data with municipality and row-limit filtering. The remaining gap is hosted deployment/performance validation, not the underlying coverage/report data path.

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
- **Current repo note:** this slice is materially implemented under `apps/web/`: methodology/privacy pages have explicit content tests, the app now has skip-link and focus-visible affordances plus a text legend, manual `web-ci.yml` runs unit/build/Lighthouse/browser-smoke checks, Playwright smoke coverage exists for the core public routes, recoverable search and drawer states are covered in automated tests, `apps/web/vercel.json` sets baseline response headers, keyboard-only navigation is covered by browser smoke, phone-sized viewport coverage is now explicit, and repo-side Lighthouse checks enforce the trust-page accessibility/CLS budget. Remaining work is Vercel account/project linking plus hosted-environment perf validation for the live map surface, not the absence of a repo-side web verify/deploy scaffold.

## Phase 11a — Upload execution (ship-blocking for internal TestFlight)

These tasks track the background-upload loop and its remaining device-validation evidence. The app-side implementation is now in place; signed-device background behavior still blocks internal TestFlight confidence.

### B070 — Wire real `upload-drain` background task handler

- **Spec refs:** [01](01-ios-implementation.md#upload-execution--triggers-background-foreground)
- **Depends on:** B060-range iOS foundation tasks
- **RED**
  - XCTest-level test that the registered handler calls into a fake `UploadDrainCoordinator` when given pending batches
  - assertion that the handler still re-submits the next `BGAppRefreshTaskRequest` when the drain is cancelled or throws
  - assertion that the handler calls `setTaskCompleted(success: false)` on cancellation and `true` on a clean drain
- **GREEN**
  - replace `BackgroundTaskRegistrar.upload-drain` stub with real call to `AppContainer.uploadDrainCoordinator.requestDrain(...)`
  - wire `expirationHandler` to cancel the active drain and still complete the `BGAppRefreshTask`
  - chain `BGTaskScheduler.shared.submit(...)` for the next drain from the completion path, not only the success path
- **Acceptance**
  - Xcode → Debug → Simulate Background Fetch triggers the real drain path on a signed build
  - drains surface progress in Settings → Uploads → Diagnostics on a device where they previously stalled
- **Current repo note:** the handler is now wired through `BackgroundUploadDrainRunner` to `UploadDrainCoordinator.requestDrain(.backgroundTask)`, cancellation calls `cancelActiveDrain()`, and both success and cancellation reschedule the next `BGAppRefreshTaskRequest`. `UploadRuntimeTests` covers clean completion, cancellation completion, rescheduling, and coalescing concurrent drains. Remaining proof is signed-device background-fetch simulation.

### B071 — Drive-end + foreground drain triggers

- **Spec refs:** [01](01-ios-implementation.md#upload-execution--triggers-background-foreground)
- **Depends on:** B070
- **RED**
  - unit test: on `DrivingDetector.events -> false`, `SensorCoordinator` calls `scheduleNextUploadDrain(earliestBegin: now + 15m)`
  - scene-phase test asserting foreground transition calls `UploadDrainCoordinator.requestDrain(.foreground)` exactly once per activation window
  - concurrency test asserting a foreground activation and BG refresh firing at the same time result in one queue drain, not two
- **GREEN**
  - add `scheduleNextUploadDrain` helper on `BackgroundTaskRegistrar`
  - observe `scenePhase` in `RoadSenseNSApp` with a debounce/cooldown so quick foreground/background toggles do not stack drain calls
  - route every trigger path through the same `UploadDrainCoordinator`
- **Acceptance**
  - a simulated drive on device results in a queued `BGAppRefreshTaskRequest` in Xcode → Debug → Background Tasks
  - a cold open with queued data does not produce concurrent drain attempts
- **Current repo note:** drive-end scheduling is implemented and now covered by a deterministic `SensorCoordinator` test that asserts `DrivingDetector.events -> false` schedules `now + 15m`. Foreground activation routes through `AppModel.handleAppDidBecomeActive()` and now has a counting-drainer test proving it requests a foreground upload drain. Concurrent foreground/background drains still funnel through the same coordinator and are covered by the coalescing test.

### B072 — Persist retry/backoff eligibility and passive upload status

- **Spec refs:** [01](01-ios-implementation.md#data-volume--upload-policy)
- **Depends on:** B071
- **RED**
  - `UploadPolicy` / queue tests asserting 429 and 5xx persist `nextAttemptAt`
  - unit test: `drainUntilBlocked()` uploads multiple eligible batches, then stops when the next batch is still backing off
  - settings view-model test covering `offline`, `retrying at <time>`, and `waiting for background time` copy
- **GREEN**
  - add persisted `nextAttemptAt` / last-success metadata to the upload queue models
  - replace expensive-network gating and cellular toggles with a simpler eligibility policy: network satisfied + retry window elapsed
  - define stale-`.inFlight` recovery (`lastAttemptAt > 5m` => retryable `.pending`)
  - Settings → Uploads renders passive status only: pending count, last success, waiting reason, retry failed batches
- **Acceptance**
  - one 5xx on a drive-end trigger does not block the next eligible cycle after backoff expires
  - an app relaunch after a killed in-flight upload does not strand the batch forever in `.inFlight`
  - on both cellular and Wi-Fi, eligible batches upload automatically without user intervention
- **Current repo note:** persisted `nextAttemptAt`, stale `.inFlight` recovery, retry summaries, and Settings upload status are implemented for readings, pothole actions, and photo reports. The uploader now drains user-initiated pothole actions and photos before larger reading batches, with an XCTest covering request order when both a manual pothole and reading batch are queued. Remaining validation is real-device cellular/Wi-Fi behavior.

## Phase 11b — Manual pothole reporting and follow-up

### B073 — Manual pothole client surface

- **Spec refs:** [01](01-ios-implementation.md#manual-pothole-reporting-and-follow-up)
- **Depends on:** B070, B072
- **Status:** implemented for the first explicit-reporting pass. `Mark pothole`, undo, `ManualPotholeLocator`, `PotholeActionRecord`, upload-drain integration, and segment-detail `Still there` / `Looks fixed` actions are in the app. The undo window is now enforced against `undoExpiresAt`, stale Undo taps no longer delete already-expired rows, and promoted actions request an upload drain immediately after the 5-second window closes. Remaining polish is B075 prompt UX rather than core action plumbing.
- **RED**
  - UI test that tapping `Mark pothole` with a stale (`> 10s`) or poor-accuracy (`> 25m`) location sample shows the non-blocking GPS warning instead of queueing an action
- **GREEN**
  - add the large `Mark pothole` map action plus marker-detail `Still there` / `Looks fixed` actions
  - add `PotholeActionRecord` SwiftData model with `pendingUndo` / `pendingUpload` states
  - integrate pothole actions with `UploadDrainCoordinator` ahead of photos/readings
- **Current repo note:** `ManualPotholeLocator` reaction-time selection, repeated-tap dedupe, privacy-zone rejection, and expired-undo handling all have XCTest coverage in the current branch.
- **Acceptance**
  - tapping `Mark pothole` produces one queued `PotholeActionRecord` with compensated precise lat/lng and a 5-second undo window
  - tapping `Still there` / `Looks fixed` produces one queued follow-up action tied to the selected `pothole_report_id`

### B074 — Manual pothole backend + contract

- **Spec refs:** [02](02-backend-implementation.md#explicit-pothole-actions-apply_pothole_action), [03](03-api-contracts.md)
- **Depends on:** B010-range backend foundation
- **Status:** implemented. Migration, Edge Function, stored procedure, and both pgTAP + Deno coverage exist in the repo.
- **RED**
  - none for the current scoped contract
- **GREEN**
  - migration for `pothole_action_type` + `pothole_actions`
  - Edge Function `pothole-actions/index.ts`
  - stored procedure `apply_pothole_action(...)` folding manual/follow-up actions into canonical `pothole_reports`
- **Acceptance**
  - one pothole location reported manually multiple times resolves to one canonical `pothole_report_id`
  - two independent `confirm_fixed` actions resolve a pothole; one alone does not

### B075 — Follow-up UX polish on top of the core action model

- **Spec refs:** [01](01-ios-implementation.md#manual-pothole-reporting-and-follow-up)
- **Depends on:** B073, B074
- **Status:** implemented for the current scoped UX. The app now shows a stopped-only expiring follow-up prompt when a user opens a nearby active pothole segment, prompt actions reuse the same `PotholeActionRecord` upload path as the segment sheet, and prompt presentation is deferred until the segment sheet dismisses so the banner is actually visible. Broader proactive resurfacing prompts on later passive passes remain optional polish.
- **RED**
  - UI test that the deferred prompt appears only after segment-sheet dismissal and expires cleanly if ignored
  - UX copy/test plan for broader passive resurfacing prompts on later passes
- **GREEN**
  - optional expiring follow-up prompt after a later pass near an active pothole
  - hook the prompt buttons into the existing `PotholeActionRecord` flow rather than inventing a second resolution path
- **Current repo note:** the stopped/fresh-location gate is already unit-tested; the remaining gap is view-level automation around prompt presentation timing.
- **Acceptance**
  - follow-up prompts expire automatically and never fire while driving
  - prompt actions and marker-sheet actions produce the same server-side result

### B075a — Sensor-backed manual pothole severity

- **Spec refs:** [01](01-ios-implementation.md#pothole-detection), [02](02-backend-implementation.md#explicit-pothole-actions-apply_pothole_action), [03](03-api-contracts.md)
- **Depends on:** B050, B073, B074
- **Status:** implemented for the first sensor-backed pass. Manual `Mark pothole` now attaches the strongest local `PotholeCandidate` within the short time/distance window, uploads optional `sensor_backed_magnitude_g` + `sensor_backed_at`, and the backend preserves that audit data while raising canonical `pothole_reports.magnitude` for valid manual sensor-backed reports. Manual-only reports still default to `1.00`; public/web copy that distinguishes default vs measured severity remains polish.
- **RED**
  - unit test that tapping `Mark pothole` within a short time/distance window of a local `PotholeCandidate` includes the strongest candidate magnitude in the queued action
  - unit test that stale or distant sensor candidates do not attach to a manual report
  - backend pgTAP/Deno test that `apply_pothole_action(...)` preserves manual default `1.00` when no sensor magnitude is provided, but raises report magnitude when a valid manual sensor magnitude is present
- **GREEN**
  - extend `PotholeActionRecord` / upload payload with optional `sensor_backed_magnitude_g` and `sensor_backed_at`
  - on `Mark pothole`, look back over recent local pothole candidates, e.g. last 10-20s and within roughly 25m of the compensated manual location, and attach the highest magnitude candidate
  - extend `pothole_actions` and `apply_pothole_action(...)` so manual reports can update `pothole_reports.magnitude = GREATEST(existing, sensor_backed_magnitude_g)` without changing confirmation semantics
  - update public/web copy so manual-only `1.0` is not presented as measured impact; distinguish `manual`, `sensor`, and `manual + sensor-backed`
- **Acceptance**
  - a manual tap immediately after driving over a detected pothole creates or updates one canonical pothole with measured magnitude rather than the default `1.00`
  - manual-only reports remain valid but are clearly labelled as unmeasured/default severity in public surfaces
  - late taps, passenger taps far from the detected bump, and repeated taps do not inflate magnitude or confirmations incorrectly

## Phase 11c — Pothole photo capture (post-MVP feature)

### B076 — Photo capture client surface

- **Spec refs:** [01](01-ios-implementation.md#pothole-photo-capture-post-mvp)
- **Depends on:** B070, B072, B074
- **Status:** implemented. `Take photo` is available from the map, `Add photo` is available from segment detail for any opened segment, camera access runs through `PotholeCameraFlowView`, and confirmed captures queue `PotholeReportRecord` rows with processed JPEGs and precise coordinates. The current build also fixes sheet/camera presentation sequencing, re-checks camera authorization on return from Settings, exposes failed-photo retry/remove controls in Settings, and adds VoiceOver + Dynamic Type coverage to the camera flow and map banners.
- **RED**
  - UI test that tapping `Take photo` while `latestSpeedKmh >= 5` or the latest speed sample is older than 10s shows the safety interstitial, while a fresh `< 5` sample presents the camera
  - UI test that segment-detail photo capture dismisses the sheet before presenting the full-screen camera
  - manual accessibility QA pass for VoiceOver copy and large Dynamic Type in the map banners and camera flow
- **GREEN**
  - add `PotholeCameraView` (AVFoundation) with confirm + retake flow
  - add `PotholeReportRecord` SwiftData model
  - integrate with upload scheduling while keeping a photo-specific local state machine (`pendingMetadata`, `pendingModeration`, `failedPermanent`)
- **Current repo note:** privacy-zone rejection, precise coordinate persistence, EXIF stripping, upload-success file deletion order, failed-photo retry/reset, and signed-upload request wiring all have automated coverage in the current branch.
- **Acceptance**
  - tap shutter → confirm produces one queued `PotholeReportRecord` with precise lat/lng, a stripped JPEG on disk, and `uploadState == .pendingMetadata`

### B077 — Photo upload backend

- **Spec refs:** [02](02-backend-implementation.md#pothole-photo-moderation-post-mvp), [03](03-api-contracts.md)
- **Depends on:** B010-range backend foundation, B074
- **Status:** implemented. `POST /pothole-photos`, the `pothole_photos` schema, rate-limit isolation, signed-upload reissue semantics, and cron-based promotion to `pending_moderation` are live. The current build also persists `segment_id` from iOS, treats already-stored pending objects as `409 already_uploaded`, issues single-write signed upload URLs with `upsert: false`, and aligns the docs/tests with metadata-consistency checks instead of a nonexistent Storage-side `Content-SHA256` verification step.
- **RED**
  - preview-project end-to-end smoke for real signed PUT upload, retry after interrupted metadata/PUT split, and cron/webhook promotion to `pending_moderation`
- **GREEN**
  - migration for `pothole_photos` + `pothole_photo_status` enum
  - Edge Function `pothole-photos/index.ts` issuing signed PUT URLs and idempotent reissue before upload completes
  - Storage bucket provisioning with byte-size + content-type restrictions
  - Storage webhook or cron that promotes uploaded objects from `pending/` to `pending_moderation/`
- **Current repo note:** pgTAP, Deno, and targeted iOS tests now cover the local contract; the remaining gap is a live preview-environment Storage smoke.
- **Acceptance**
  - E2E contract tests pass against a preview Supabase project
  - a timed-out PUT followed by retry creates one server row and eventually lands in `pending_moderation`

### B078 — Photo moderation queue + publishing

- **Spec refs:** [02](02-backend-implementation.md#pothole-photo-moderation-post-mvp)
- **Depends on:** B077
- **Status:** implemented. The backend now has `approve_pothole_photo()` / `reject_pothole_photo()` procedures, the `moderation_pothole_photo_queue` view, internal signed-image preview, internal moderation actions that move/delete Storage objects, and pothole fold-in on approval. The current build also adds rollback if a Storage move succeeds but the approval RPC fails, reject-before-delete ordering, `security_invoker` on the moderation queue view, and a geography index for the approval-path nearby lookup.
- **RED**
  - preview-project moderation smoke verifying real Storage move/delete behavior plus published-map visibility after approval
- **GREEN**
  - approve/reject stored procedures; Storage move on approve; Storage delete on reject
  - Supabase Studio view with approve/reject actions bound to those procedures
  - pothole-folding logic extension so approved photos participate in the same 15m cluster merge used by accelerometer pothole folding and manual pothole actions, with the public marker coming from the merged `pothole_reports` row
- **Current repo note:** SQL procedures, Deno moderation contracts, and pgTAP moderation suites all pass locally; the remaining work is live-environment smoke rather than missing backend logic.
- **Acceptance**
  - an approved photo appears on the public pothole layer within one tile-cache TTL

## Phase 11c — My Drives list (post-MVP feature)

### B076 — DriveSession persistence and lifecycle

- **Spec refs:** [01](01-ios-implementation.md#my-drives-list-post-mvp)
- **Depends on:** B070
- **RED**
  - unit test: `DrivingDetector.events -> true` creates a `DriveSessionRecord`, `-> false` seals it
  - unit test: stale in-progress drives (> 2h open) are force-sealed on foreground
  - unit test: a fully-privacy-filtered drive has `readingCount == 0 && privacyFilteredCount > 0`
- **GREEN**
  - add `DriveSessionRecord` SwiftData model, relationship on `ReadingRecord`
  - extend `SensorCoordinator` to stamp readings with the active drive
  - add foreground-cleanup pass for stale drives
- **Acceptance**
  - a simulated drive produces exactly one `DriveSessionRecord` with accurate distance and counters

### B077 — Drives list and detail UI

- **Spec refs:** [01](01-ios-implementation.md#my-drives-list-post-mvp)
- **Depends on:** B076
- **RED**
  - UI test that the Drives list renders grouped sections (Today, Yesterday, Earlier this week)
  - UI test that a 100%-privacy-filtered drive shows the `Inside a privacy zone` treatment
  - UI test that `Delete this drive` shows the "already uploaded data stays public" confirmation copy verbatim
- **GREEN**
  - `DrivesListView` accessible from Stats → Recent drives
  - `DriveDetailView` with mini-map polyline, counters, and delete action
  - `Open on main map` action that centers the map to the drive's bounding box
- **Acceptance**
  - VoiceOver labels match the documented script; Dynamic Type Accessibility 1+ reflows rows vertically

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

## Phase 12 — Android Follow-On

Android is explicitly post-iOS MVP. Do not start this until the iOS app has proven background collection, upload reliability, and roughness calibration on real drives; otherwise we duplicate unsettled platform decisions.

### B120 — Android collector app

- **Spec refs:** [00](00-execution-plan.md#android-follow-on-weeks-13-18), [01](01-ios-implementation.md), [03](03-api-contracts.md), [06](06-security-and-privacy.md)
- **Depends on:** B050, B060, Phase 11a B070-B072 upload execution, Phase 8 App Store/TestFlight readiness outcome, and at least one stable iOS calibration dataset
- **Status:** backlog. Android is valuable for tester reach and cross-vehicle/sensor diversity, but it should consume the same backend contracts rather than force new ingestion semantics.
- **RED**
  - JVM/Kotlin tests for the ported roughness scorer and pothole detector using shared CSV fixtures also used by the iOS harness
  - Android instrumentation tests for permission onboarding, foreground-service recording state, local queue persistence, and retry/backoff behavior
  - backend compatibility smoke proving Android uploads use the same `upload-readings`, `pothole-actions`, and photo/feedback contracts without Android-only branches
  - privacy checklist proving Android backups exclude Room queues and no precise location is uploaded before the same trimming/privacy-zone gates pass
- **GREEN**
  - Kotlin native project with Jetpack Compose, Room, WorkManager, Retrofit/OkHttp, and Mapbox Maps SDK for Android
  - foreground-service collection model with clear persistent notification and Android 14+ `FOREGROUND_SERVICE_LOCATION` handling
  - port sensor pipeline using `Sensor.TYPE_LINEAR_ACCELERATION` or accelerometer+gravity fallback plus fused location updates
  - port upload queue, privacy zones, device-token rotation, manual pothole actions, and map rendering against existing backend endpoints
  - add CI lane for unit tests and a minimal Android build once the project exists
- **Acceptance**
  - Android and iOS produce roughness scores within the agreed tolerance on the same fixture/drive replay
  - a real Android test drive uploads readings that appear on the same public map without backend changes
  - battery drain and foreground-service UX are documented on at least one Pixel-class and one Samsung-class device
  - Google Play internal/closed testing path is documented, including any current new-developer testing requirements

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
13. Android scaffold and shared-fixture scorer parity

## Hard Stop Rules

Stop and reassess if:

- the upload contract changes after iOS implementation starts
- background collection fails repeatedly on real devices despite spec-compliant setup
- nightly recompute exceeds its documented operational budget
- Coverage mode or `Worst Roads` requires raw-reading exposure to feel useful
- App Store privacy answers no longer match actual data flow

These are architecture warnings, not "keep pushing harder" tasks.
