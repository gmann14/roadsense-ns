# 08 — Implementation Backlog

*Last updated: 2026-05-25*

Covers: the literal execution backlog for implementing the spec set in [00](00-execution-plan.md) through [07](07-web-dashboard-implementation.md), plus the Android follow-on spec in [11](11-android-implementation.md).

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
12. Android project bootstrap and domain parity
13. Android collection loop and persistence
14. Android map/UI parity
15. Android field testing and Play release

## Cross-Cutting Data-Model Decision

Distance, drive history, and public road quality are separate concepts:

- **Drive distance** is local, odometer-style distance from plausible `CLLocation` deltas during an active automotive drive. Stop-and-go and `<15 km/h` movement count only after the session has passed the driving/automotive gate; walking, cycling, running, and unknown activity must not open a drive just because GPS speed is plausible.
- **Quality readings** are uploadable roughness observations. Low-speed windows can be valid parts of a drive but are not reliable roughness measurements.
- **Public mapped coverage** remains segment-based: it measures road segments with accepted/scored aggregate data, not how far one person drove.

The implementation path below moves core `DriveSessionRecord` lifecycle and distance accounting into the MVP hardening path. The later "My Drives" feature keeps only the user-facing list/detail UI and richer history affordances.

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

### B013a — Path-aware upload metadata and segment matching hardening

- **Spec refs:** [02](02-backend-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B011, B013
- **Why now:** point-only matching is fragile near intersections, ramps, divided roads, and parallel streets. We still aggregate by server-owned road segment, but the matcher should use the shape and ordering of each observation window when clients provide it.
- **Compatibility rule:** all new upload fields are optional. Existing point-only clients must keep working and must produce identical responses for the current contract tests.
- **RED**
  - Deno contract tests proving `/upload-readings` accepts both legacy point-only readings and new readings with `window_start_lat/lng`, `window_end_lat/lng`, `window_distance_m`, `duration_s`, and `sequence_index`
  - pgTAP fixture where two parallel roads are within the distance threshold and heading/continuity selects the correct road
  - pgTAP fixture where a window crosses a segment boundary and is assigned without double-counting the whole distance as one segment
  - pgTAP fixture where low-speed observations are absent from upload but adjacent higher-speed windows still match continuously
  - regression test proving existing `no_segment_match`, `unpaved`, duplicate replay, and aggregate-update behavior is unchanged for legacy batches
- **GREEN**
  - extend Edge Function validation to tolerate optional window metadata without requiring it
  - stage optional start/end geometries and sequence order in `ingest_reading_batch`
  - add a path-aware candidate scorer that considers distance, heading, optional window geometry overlap, and continuity with neighboring readings in the same batch
  - retain the current nearest-point matcher as the fallback path when optional metadata is missing or unusable
- **Acceptance**
  - no existing upload, rejection-reason, idempotency, or aggregate tests regress
  - ambiguous-road fixtures pick the intended segment without weakening the 20m max-distance safety guard
  - matching diagnostics can count point-fallback vs path-aware matches for field-test review

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
  - SQL-level verification that low-confidence scored segments are included in beta quality tiles and still carry `confidence = low`
- **GREEN**
  - implement `get_tile`
  - implement tiles Edge Function
- **Acceptance**
  - tile endpoint serves MVT with stable attributes and proper cache headers
  - beta quality tiles show all scored segments while clients visually de-emphasize `confidence = low`

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

### B039 — Drive session odometer and low-speed accounting

- **Spec refs:** [01](01-ios-implementation.md), [03](03-api-contracts.md), [06](06-security-and-privacy.md)
- **Depends on:** B033, B034
- **Why now:** users expect stop-and-go traffic to count as part of a drive even when it is not reliable enough for roughness scoring. Distance stats should not depend on how many quality readings survive upload eligibility.
- **RED**
  - unit test: `DrivingDetector.events -> true` opens exactly one `DriveSessionRecord`, and `-> false` seals it idempotently
  - unit test: plausible 0-15 km/h GPS deltas in stop-and-go traffic increase `totalDistanceM` only after an automotive session is active, and create no uploadable roughness reading
  - unit test: bicycle-like GPS traces, including sustained 15-35 km/h movement with non-automotive or unknown motion activity, do not open a drive session and do not increase `totalKmRecorded`
  - unit test: if Motion Activity is unavailable, GPS-only fallback requires a higher-confidence automotive signature than ordinary cycling: sustained higher speed and/or an already-open automotive session; 15-35 km/h alone is insufficient
  - unit test: speeds `>160 km/h`, poor GPS accuracy, teleport jumps, and stale samples do not inflate `totalDistanceM`
  - unit test: fully privacy-filtered drives preserve approximate local distance and `privacyFilteredCount`, while enqueuing no uploads
  - unit test: stale in-progress drives (`>2h`) are force-sealed on foreground without losing counters
  - migration test proving existing `ReadingRecord`, upload queue, token, and privacy-zone stores open after adding the drive-session schema
  - simulator fixture replay for a stop-and-go drive: expected drive distance is within tolerance, accepted reading count is lower than movement windows, and pending upload count matches quality-eligible windows only
- **GREEN**
  - add MVP `DriveSessionRecord` SwiftData model with `startedAt`, `endedAt`, `totalDistanceM`, `readingCount`, `privacyFilteredCount`, `potholesDetected`, `uploadStatus`, start/end coordinates, and a deleted/local tombstone flag
  - add optional relationship from `ReadingRecord` to its active drive session
  - move `totalKmRecorded` updates from accepted-reading math to drive-session odometer accounting
  - extend `SensorCoordinator` to maintain active drive state, odometer deltas, privacy-filtered counters, and stale-session cleanup
  - treat `<15 km/h` windows as drive movement but `qualityIneligibleLowSpeed` for upload/roughness scoring only while an automotive drive session is active
- **Acceptance**
  - personal distance stats match plausible driven distance in stop-and-go fixtures
  - a captured bike-ride fixture does not create a drive or contribute kilometres
  - low-speed traffic no longer causes the app to appear as if it stopped tracking the drive
  - upload batching and existing accepted-reading persistence behavior remain backward compatible

## Phase 5 — End-To-End Stub Loop

### B040 — Reading window assembly

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B033, B034, B039
- **RED**
  - unit tests for windowing by distance/time, including start/end coordinates and `window_distance_m`
  - unit tests proving low-speed movement advances an already-active automotive drive but does not emit an uploadable roughness window
  - simulator harness fixture replay
- **GREEN**
  - implement `ReadingBuilder`
  - produce observation windows with midpoint, start/end coordinates, distance, duration, sample counts, and quality eligibility
  - produce backward-compatible POINT reading payloads from eligible windows
- **Acceptance**
  - app can generate uploadable reading batches from replayed fixtures
  - app can account for drive distance from replayed fixtures even when no windows are uploadable
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

### B043 — Production data hygiene gate before public map exposure

- **Spec refs:** [03](03-api-contracts.md), [05](05-deployment-and-observability.md), [09](09-internal-field-test-pack.md)
- **Depends on:** B020, B021, B042
- **Why now:** a live Railway data review on 2026-05-11 found accepted production rows from `0.1.0-seed`, `codex-live-load/2026-04-28`, and `codex-rate-limit/2026-04-28`. The API and tile paths were healthy, but public confidence tiers and stats cannot be treated as launch-clean while synthetic/test batches contribute to aggregates.
- **RED**
  - read-only SQL report that fails if any synthetic/test `client_app_version` contributes rows to `readings`, `segment_aggregates`, `pothole_reports`, or `public_stats_mv`
  - regression test or script guard proving `seeded-e2e-smoke.sh` refuses to run against production/shared publishable backends
  - read-only endpoint smoke for `/functions/v1/stats`, quality tiles, and coverage tiles against production
- **GREEN**
  - add an explicit production data-hygiene script/query bundle under `scripts/`
  - document the cleanup runbook for deleting synthetic batches and rebuilding derived aggregates/potholes/stats from remaining real readings
  - ensure production deploy/release checklist calls only non-mutating smoke checks
- **Acceptance**
  - production contains no accepted synthetic/test readings that influence public stats or tiles
  - `segment_aggregates` and `public_stats_mv` have been recomputed/refreshed after cleanup
  - publishable quality tiles still return non-empty MVT for known populated real-data tiles
  - active pothole counts are explainable from real app builds only

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
- **Current repo note:** `PotholeDetector` is now wired into the live `SensorCoordinator` path, but `RoughnessScorer` still needs to replace the current direct-RMS placeholder once fixture calibration work starts.

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
- **Current repo note:** the optional privacy-zone path is materially implemented: onboarding/settings can open the real `PrivacyZonesView` + `PrivacyZoneStore`, the editor is map-backed, and `SensorCoordinator` already applies zone filtering before persistence/upload. Remaining work is the default endpoint-trimming pass, the updated ready-state/privacy copy, and real-device validation of the combined privacy flow.

### B052 — Quality filters and uploader hardening

- **Spec refs:** [01](01-ios-implementation.md), [03](03-api-contracts.md)
- **Depends on:** B039, B041, B050
- **RED**
  - truth-table tests for GPS accuracy, speed, thermal, activity gates, and the distinction between drive-distance eligibility and upload/roughness eligibility
  - retry tests for network failure, 429, and permanent 400
- **GREEN**
  - implement `QualityFilter`
  - finish uploader backoff and permanent-failure handling
- **Acceptance**
  - app behaves exactly per documented retry rules
  - `<15 km/h` movement is retained in local drive stats only inside an active automotive drive and is never used to score roughness unless a future calibrated low-speed model explicitly enables it

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

### B060 — Background execution and relaunch handling

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **Depends on:** B040, B051
- **RED**
  - real-device test plan for lock-screen, background drive, and system-termination recovery
- **GREEN**
  - implement SLC bootstrap and safe background behavior
- **Acceptance**
  - app survives documented background scenarios short of user force-quit
- **Current repo note:** `BackgroundCollectionPolicy` and `BackgroundTaskRegistrar` now exist, and the project emits `BGTaskSchedulerPermittedIdentifiers`. Significant-location-change orchestration and real-device validation remain.
- **Current repo note:** Background task IDs are now aligned with the spec (`nightly-cleanup`, `upload-drain`). Significant-location-change orchestration and real-device validation still remain.

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

These tasks finish the background-upload loop that today is partially stubbed. They block internal TestFlight but not necessarily the first signed build for team testing.

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
- **Status:** implemented. `POST /pothole-photos`, the `pothole_photos` schema, rate-limit isolation, signed-upload reissue semantics, and upload promotion to `pending_moderation` are live. The current build also persists `segment_id` from iOS, treats already-stored pending objects as `409 already_uploaded`, issues single-write signed upload URLs, and aligns the docs/tests with metadata-consistency checks instead of a nonexistent Storage-side `Content-SHA256` verification step. The Railway production API now serves this route directly instead of returning `404`.
- **RED**
  - preview-project end-to-end smoke for real signed PUT upload, retry after interrupted metadata/PUT split, and cron/webhook promotion to `pending_moderation`
- **GREEN**
  - migration for `pothole_photos` + `pothole_photo_status` enum
  - Edge Function `pothole-photos/index.ts` issuing signed PUT URLs and idempotent reissue before upload completes
  - Storage bucket provisioning with byte-size + content-type restrictions
  - Storage webhook or cron that promotes uploaded objects from `pending/` to `pending_moderation/`
- **Current repo note:** pgTAP, Deno, and targeted iOS tests cover the local contract. A controlled Railway production smoke on 2026-05-13 verified metadata creation plus signed `PUT` to `pending_moderation`; the synthetic row was cleaned up afterward. A disposable preview-project Supabase Storage smoke remains useful before relying on the Supabase Edge deployment shape.
- **Acceptance**
  - E2E contract tests pass against a preview Supabase project
  - a timed-out PUT followed by retry creates one server row and eventually lands in `pending_moderation`

### B078 — Photo moderation queue + publishing

- **Spec refs:** [02](02-backend-implementation.md#pothole-photo-moderation-post-mvp)
- **Depends on:** B077
- **Status:** implemented. The backend now has `approve_pothole_photo()` / `reject_pothole_photo()` procedures, the `moderation_pothole_photo_queue` view, internal signed-image preview, internal moderation actions that move/delete stored photo objects, and pothole fold-in on approval. The current build also adds rollback if a Storage move succeeds but the approval RPC fails, reject-before-delete ordering, `security_invoker` on the moderation queue view, expiring Railway preview URLs for stored blobs, and a geography index for the approval-path nearby lookup.
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

### B076 — My Drives history polish

- **Spec refs:** [01](01-ios-implementation.md#my-drives-list-post-mvp)
- **Depends on:** B039, B070
- **RED**
  - unit tests for retained drive summaries after uploaded readings are pruned
  - unit tests for local delete tombstones and upload-status rollups
  - unit test: a fully-privacy-filtered drive summary stays approximate and never exposes a precise route
- **GREEN**
  - extend the MVP drive-session model with any UI-only summary fields needed by the list/detail screens
  - preserve counters after uploaded `ReadingRecord` rows age out
  - add local-only delete/tombstone behavior for drive history rows
- **Acceptance**
  - drive-history UI can be built without changing the upload contract or server persistence model

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

## Phase 12 - Android Project Bootstrap And Domain Parity

Start only after the iOS/TestFlight MVP is live or intentionally paused. The Android source of truth is [11-android-implementation.md](11-android-implementation.md). Android must reuse [03-api-contracts.md](03-api-contracts.md) as-is.

### B200 - Android Gradle scaffold

- **Spec refs:** [11](11-android-implementation.md)
- **Depends on:** iOS MVP live or intentionally paused
- **RED**
  - CI/manual command fails because `android/` does not exist
  - document expected package ID and build variants in `android/README.md`
- **GREEN**
  - create `android/` Gradle Kotlin DSL project
  - add `:app`, `:core:domain`, and `:core:testfixtures`
  - configure Compose, Kotlin, Android Gradle Plugin, version catalog, and base build variants
  - add empty `RoadSenseApplication`, `MainActivity`, and manual `AppGraph`
- **Acceptance**
  - `./gradlew :app:assembleLocalDebug` succeeds
  - package ID is `ca.roadsense.android`
  - app launches to a placeholder Compose shell

### B201 - Port pure domain pipeline to Kotlin

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md), [11](11-android-implementation.md)
- **Depends on:** B200
- **RED**
  - add shared fixture tests for pothole hit, smooth cruise, privacy-zone recovery, and thermal rejection
  - tests fail against empty Kotlin pipeline
- **GREEN**
  - port `MotionMath`, `HighPassBiquad`, `DrivingHeuristic`, `QualityFilter`, `PrivacyZoneFilter`, `ReadingBuilder`, `ReadingWindowProcessor`, `PotholeDetector`, `UploadPolicy`, request/response parsers, and endpoint trimming
  - keep these components Android-framework-free under `:core:domain`
- **Acceptance**
  - JVM fixture tests pass
  - roughness outputs match iOS fixture expectations within the tolerance in [11](11-android-implementation.md)
  - no Android framework imports appear in `:core:domain`

### B202 - Android permission and readiness state machine

- **Spec refs:** [06](06-security-and-privacy.md), [11](11-android-implementation.md)
- **Depends on:** B200
- **RED**
  - unit tests enumerate fine denied, approximate-only, background denied, activity recognition denied, notifications denied, and ready states
- **GREEN**
  - implement permission repository/checker
  - add onboarding and repair UI copy for each degraded state
  - gate passive monitoring on precise fine location, activity recognition, notifications where required, and background location
- **Acceptance**
  - approximate location cannot enter uploadable collection state
  - foreground-only mode is explicit when background location is denied
  - settings repair actions route to the correct Android settings screens

## Phase 13 - Android Collection Loop And Persistence

### B210 - Room schema and local stores

- **Spec refs:** [11](11-android-implementation.md)
- **Depends on:** B201
- **RED**
  - Room migration/schema tests fail for missing entities
  - DAO tests describe pending upload, successful upload, delete-local-data, and retention cleanup behavior
- **GREEN**
  - implement Room entities for readings, upload batches, privacy zones, user stats, device token, drive sessions, checkpoints, pothole actions, and photos
  - implement DataStore settings/token metadata
  - set `android:allowBackup="false"`
- **Acceptance**
  - Room schema export is checked in
  - local data retention can delete oldest processed readings without deleting privacy zones
  - delete-local-data matches iOS behavior

### B211 - Upload queue and WorkManager drain

- **Spec refs:** [03](03-api-contracts.md), [11](11-android-implementation.md)
- **Depends on:** B210
- **RED**
  - tests for idempotent `batch_id`, retry backoff, 429 `Retry-After`, permanent 400, and max 1000 readings
- **GREEN**
  - implement Retrofit/OkHttp API client
  - implement upload request factory/parser
  - implement `UploadDrainWorker` as unique WorkManager work with network constraint
  - implement retention cleanup worker
- **Acceptance**
  - Android emits the same upload JSON shape as [03](03-api-contracts.md)
  - network/5xx retries reuse the same `batch_id`
  - permanent failures surface in Settings

### B212 - Activity recognition and foreground collection service

- **Spec refs:** [11](11-android-implementation.md)
- **Depends on:** B202, B210
- **RED**
  - service policy tests cover background-location denied, user paused, thermal serious/critical, and notification action states
  - fake activity transition test proves `IN_VEHICLE` enter starts collection only when readiness permits
- **GREEN**
  - register Activity Recognition Transition API for `IN_VEHICLE` enter/exit
  - implement `CollectionForegroundService` with `location` foreground-service type
  - add persistent notification with Pause and Stop actions
  - implement checkpoint persistence every 60 seconds
- **Acceptance**
  - active background collection never runs without a visible notification
  - service stops or pauses on permission revoke, user pause, driving exit, or serious thermal state
  - service does not use WorkManager for active sensor collection

### B213 - Android location and motion sampler integration

- **Spec refs:** [11](11-android-implementation.md)
- **Depends on:** B212, B201
- **RED**
  - fake sampler integration test feeds 50 Hz motion + 1 Hz location into the real pipeline and expects persisted readings
- **GREEN**
  - wrap `FusedLocationProviderClient`
  - wrap `SensorManager` for linear acceleration, rotation vector, and fallback gravity/accelerometer path
  - integrate `SensorCoordinator` with Room stores and upload scheduling
- **Acceptance**
  - foreground drive on a real device persists accepted local readings
  - low-speed movement counts only as local drive distance after an active in-vehicle session starts
  - privacy-zone and endpoint trimming happen before upload

## Phase 14 - Android Map/UI Parity

### B220 - Mapbox Android quality map

- **Spec refs:** [03](03-api-contracts.md), [11](11-android-implementation.md)
- **Depends on:** B211
- **RED**
  - UI tests cover map shell fallback states without requiring Mapbox startup
  - style config test asserts source-layer names match `segment_aggregates` and `potholes`
- **GREEN**
  - integrate Mapbox Maps SDK for Android
  - add vector tile source for `/tiles/{z}/{x}/{y}.mvt`
  - render category/confidence styling and pothole markers
  - render local unuploaded readings as dashed teal overlay
  - support segment tap -> `GET /segments/{id}` -> detail sheet
- **Acceptance**
  - staging map renders community tiles and local overlay on device
  - low-confidence styling is visually distinct
  - segment detail handles empty `history` and null `neighbors`

### B221 - Android product surfaces

- **Spec refs:** [11](11-android-implementation.md), [design tokens](../design-tokens.md)
- **Depends on:** B202, B210, B220
- **RED**
  - Compose tests for onboarding/repair, map shell, stats, settings, privacy zones, delete-local-data
- **GREEN**
  - implement onboarding and permission repair screens
  - implement stats/settings/privacy-zone editor
  - use shared design tokens for roughness colors and UI theme
  - expose passive monitoring toggle, upload drain, and delete-local-data actions
- **Acceptance**
  - user can recover from every degraded permission state
  - privacy-zone editor stores offset centers only
  - UI remains usable at large font scale

### B222 - Android pothole actions and photos

- **Spec refs:** [03](03-api-contracts.md), [11](11-android-implementation.md)
- **Depends on:** B211, B221
- **RED**
  - tests for manual report idempotency, undo window, privacy-zone rejection, photo metadata POST, signed URL reissue, and 409 already-uploaded handling
- **GREEN**
  - implement `POST /pothole-actions` queue/uploader
  - add manual `Mark pothole` action
  - add CameraX photo capture and signed upload only after passive loop is stable
- **Acceptance**
  - actions drain before photos before passive readings
  - photo bytes are deleted locally only after confirmed upload success
  - Android request body matches [03](03-api-contracts.md)

## Phase 15 - Android Field Testing And Play Release

### B230 - Android real-device field pack

- **Spec refs:** [09](09-internal-field-test-pack.md), [11](11-android-implementation.md)
- **Depends on:** B213, B220, B221
- **RED**
  - field-test checklist exists for Pixel, Samsung, and one older Android device if available
- **GREEN**
  - run foreground-only drive, passive background drive, offline-to-online upload, privacy-zone drive-through, battery-saver drive, and long-drive thermal observation
  - capture battery drain, collection continuity, accepted/rejected counts, and map render evidence
- **Acceptance**
  - 1 hour of Android driving uploads successfully on 2+ Android devices
  - battery drain is below the [11](11-android-implementation.md) release threshold
  - no privacy-filtered or endpoint-trimmed readings reach staging/prod

### B231 - Play internal/closed testing readiness

- **Spec refs:** [11](11-android-implementation.md)
- **Depends on:** B230
- **RED**
  - release checklist identifies missing Play Console, data safety, signing, background-location declaration, and developer-verification items
- **GREEN**
  - create Play app record and internal testing track
  - configure Play App Signing
  - complete Data Safety form based on actual implementation
  - prepare background-location demo video and disclosure copy
  - add Android release workflow/manual build command
- **Acceptance**
  - signed `stagingRelease` build is available through Play Internal Testing
  - background location declaration accurately reflects foreground-service behavior
  - Android release notes include known limitations and battery guidance

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
13. Android Gradle/domain scaffold only
14. Android collection/persistence only
15. Android map/UI only
16. Android Play release polish only

## Hard Stop Rules

Stop and reassess if:

- the upload contract changes after iOS implementation starts
- background collection fails repeatedly on real devices despite spec-compliant setup
- nightly recompute exceeds its documented operational budget
- Coverage mode or `Worst Roads` requires raw-reading exposure to feel useful
- App Store privacy answers no longer match actual data flow
- Android requires an API contract change that would break iOS
- Android background collection cannot run with a visible foreground service and documented permissions
- Android fixture roughness output diverges from iOS beyond the tolerance in [11](11-android-implementation.md)

These are architecture warnings, not "keep pushing harder" tasks.
