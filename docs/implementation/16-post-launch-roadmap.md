# 16 — Post-Launch Roadmap

*Last updated: 2026-06-11*

> **⚠️ REVISION NOTE (2026-06-12):** This doc was drafted against the stale `codex/testflight-build` branch (~109 commits behind). Two material corrections:
> 1. **Phase 12 (Android) is NOT greenfield** — a full Android app already exists on `gmann14/android-beta-test-fixes` (Kotlin, Room, `android/` tree, `android-ci.yml` + `android-internal.yml` workflows, tip 2026-05-25). [08](08-implementation-backlog.md) already defines B120 as the umbrella "Android collector app" ticket (its "code not started" status predates the android branch); this doc's B120–B127 expand that umbrella into sub-phases. Read Phase 12 as "merge, finish, and ship the existing Android app," using B120–B127 as a completeness checklist rather than a build plan.
> 2. Production backend is a Deno gateway on Railway behind Cloudflare at `api.nsroadsense.ca` (see `supabase/functions/server.ts` on `codex/testflight-signing-secrets`), not Supabase-hosted edge functions — growth-phase items referencing deploy targets should assume that architecture.
> Validated findings against the real code live in `docs/reviews/2026-06-11-ios-prelaunch-review.md` and `docs/reviews/2026-06-11-backend-prelaunch-review.md` (both revised 2026-06-12).

Covers: the prioritized execution plan for everything after the iOS TestFlight launch — the Android client, calibration and trust hardening, the growth/advocacy surfaces that back the public marketing push, and explicit scheduling triggers for items deferred in [08-implementation-backlog.md](08-implementation-backlog.md).

Like [08](08-implementation-backlog.md), this doc is deliberately task-shaped. It assumes the iOS app is code-complete or nearly so, external TestFlight is live or imminent, and the backend loop (upload → aggregate → tile → web) works end to end.

## How To Use This Doc

Rules carried over from [08](08-implementation-backlog.md) unchanged:

1. Work in dependency order unless a task is explicitly marked parallelizable.
2. For every task, do the **RED** step first.
3. Definitions of Ready and Done from [08](08-implementation-backlog.md) apply as written.
4. If a task changes an API or persistence contract, update [03-api-contracts.md](03-api-contracts.md) and the relevant implementation doc in the same PR.

New conventions in this doc:

- **Numbering** continues the backlog's B-series starting at **B120**. B111–B119 are intentionally skipped: [08](08-implementation-backlog.md) tops out at B110 and reuses some B07x identifiers across phases, so the gap keeps the new range unambiguous. Deferred items that already have ticket IDs (B076/B077, B100, B110) keep them — they are scheduled here, not renumbered.
- **Effort** estimates are added per ticket. They are solo-developer estimates that include writing the tests, not just the implementation. Treat them as planning aids, not commitments.

## Priority Order

`[DECISION]` The post-launch order is:

1. **Android client** (Phase 12). This ships regardless of early iOS traction. Two explicit reasons: (a) learning the Play Store pipeline end to end is a goal in itself, and (b) the marketing channel is mixed-platform — Facebook groups of people angry about road conditions do not segment by phone OS, and every Android driver we turn away weakens the network effect on both maps.
2. **Calibration and trust** (Phase 13). Interleaved, not strictly sequential — see the note below.
3. **Growth and advocacy surfaces** (Phase 14). These serve the concrete marketing plan: shareable artifacts for road-condition Facebook groups and local NS media.
4. **Deferred backlog items** (Phase 15). Scheduled by trigger, not by calendar.

**Interleave rule:** B140 and B141 (calibration drives + real `RoughnessScorer`) are iOS/backend work with no Android dependency, and the Android parity fixtures in B121 cannot be frozen until the scorer is final. Run B140/B141 during Android weeks 1–2 rather than after the Android launch. Everything else in Phase 13 can trail.

## Entry Criteria

Before starting Phase 12:

- iOS external TestFlight is live, or internal TestFlight is live and external is intentionally paused
- backend smoke checks (`./scripts/api-smoke.sh`, `./scripts/seeded-e2e-smoke.sh`) are green against whichever hosted environment testers share
- the upload contract in [03-api-contracts.md](03-api-contracts.md) is stable — the Android client consumes it as-is, with no Android-specific endpoints

## Phase 12 — Android Client (B120–B127)

Direction is already locked in [00 §Android Follow-On](00-execution-plan.md): **Kotlin native** (not Flutter, not KMP), Jetpack Compose, Hilt, Room, WorkManager, Retrofit + OkHttp + kotlinx-serialization, Mapbox Maps SDK for Android, `FusedLocationProviderClient` + `Sensor.TYPE_LINEAR_ACCELERATION`. The iOS↔Android delta table in [00](00-execution-plan.md) remains the reference; this phase turns it into tickets.

The backend needs **zero changes**: any client speaking the documented HTTPS JSON contract is a first-class citizen. Same `batch_id` idempotency, same device-token rotation and server-side hashing, same rejection accounting.

### The Portable Core

The bootstrap package rule in [01](01-ios-implementation.md) (Foundation-only, no UIKit/Mapbox/CoreLocation) was always the Android down payment. The following pure-logic modules (~900 LOC total) port mechanically to a JVM-only Kotlin module with no `android.*` imports:

| Swift module | Kotlin target | What ports | Parity fixtures |
|---|---|---|---|
| `ReadingBuilder` (+ `ReadingWindowProcessor`) | `core/pipeline/ReadingBuilder.kt` | 50m/15s windowing, window abort/discard rules, checkpoint state shape | all golden drive fixtures |
| `RoughnessScorer` (+ `HighPassBiquad`, `MotionMath`) | `core/pipeline/RoughnessScorer.kt` | biquad high-pass (~0.5Hz), RMS per window, speed normalization (post-B141) | smooth-cruise, pothole-hit, speed-variant fixtures |
| `PotholeDetector` | `core/pipeline/PotholeDetector.kt` | spike detection, braking false-positive rejection | pothole-hit, speed-bump, braking fixtures |
| `PrivacyZoneFilter` (+ `PrivacyZone` geometry) | `core/privacy/PrivacyZoneFilter.kt` | per-GPS-sample zone test, whole-window drop, randomized offset rules | privacy-zone recovery fixture |
| `QualityFilter` | `core/pipeline/QualityFilter.kt` | speed / GPS-accuracy / thermal / activity truth table | thermal-rejection fixture + truth-table unit tests |
| `UploadQueueCore` (+ `UploadPolicy`, `UploadRequestFactory`, `UploadResponseParser`) | `core/upload/UploadQueueCore.kt` | batch assignment, `nextAttemptAt` backoff, `.inFlight` recovery, idempotent retry | response-parsing and backoff unit fixtures |
| `DeviceTokenManager` | `core/privacy/DeviceTokenManager.kt` | monthly rotation decision, token format | rotation-boundary unit tests (injected clock) |
| `SensorFixtureParser` / `SensorFixtureRunner` | `core/testing/` | CSV fixture replay harness — required to run the parity suite at all | n/a (it is the harness) |

**Parity test definition:** the same checked-in CSV + `.expected.json` fixture pairs run through both the Swift bootstrap suite and the Kotlin `:core` test suite, and both must produce identical window counts, identical pothole flags, and RMS values within ±0.001g. Promote the fixture corpus from the iOS test target to a repo-root `fixtures/sensor/` directory consumed by both platforms, so a new fixture automatically joins both suites. The looser ±10% bar from [00](00-execution-plan.md) applies only to *paired real drives* (different hardware, different sensor fusion); fixture replay is the same math on the same doubles and gets no such slack.

### Android-Specific Deltas (the part that does not port)

Beyond the table in [00](00-execution-plan.md), three deltas deserve explicit design attention because they shape tickets:

1. **Background collection is a foreground service, full stop.** Modern Android has no iOS-style background-without-notification option. Active recording runs inside a `foregroundServiceType="location"` service with a persistent notification (Android 14+ additionally requires the `FOREGROUND_SERVICE_LOCATION` manifest permission).
2. **Passive auto-start is conditionally possible, not free.** Android 12+ restricts starting foreground services from the background, but activity-recognition transition events are on the documented exemption list. The catch: a location-type service started from the background can only access location if the app holds `ACCESS_BACKGROUND_LOCATION`. `[DECISION]` Request `ACCESS_BACKGROUND_LOCATION` to keep passive iOS-style collection parity, accept Play's prominent-disclosure + declaration-form + demo-video requirements, and keep a user-initiated-recording fallback variant ready in case the declaration is rejected (mirrors the iOS foreground-only fallback in [00 §Risks](00-execution-plan.md)).
3. **Sensor rates are advisory.** `SENSOR_DELAY_GAME` is ~50Hz on paper and anything in practice. The motion wrapper must timestamp-resample to the pipeline's expected 50Hz and clamp at 60Hz so the ported math sees the same stream shape as iOS.

### B120 — Play Console enrollment and Android project bootstrap

- **Spec refs:** [00](00-execution-plan.md), [05](05-deployment-and-observability.md)
- **Depends on:** none (parallelizable with late iOS launch work)
- **Effort:** 3–4 days
- **RED**
  - `android-ci.yml` stubbed and failing for missing implementation rather than missing workflow
  - checklist confirming the application ID is used consistently before any store record exists
- **GREEN**
  - enroll in Google Play Console (one-time $25); start the account-verification clock immediately — it can take days
  - `[DECISION]` application ID `ca.roadsense.android`, display name `RoadSense NS` (same as iOS)
  - bootstrap `android/` with Kotlin 2.x, AGP latest, Compose, Hilt, and a Gradle version catalog
  - create the JVM-only `:core` module (the bootstrap-package analogue) and the `:app` module
  - add dependencies: Mapbox Android, Sentry Android, Retrofit/OkHttp/kotlinx-serialization, Room, WorkManager
  - wire `android-ci.yml`: lint, `:core` unit tests, debug assembly
- **Acceptance**
  - clean checkout builds a debug APK from repo state alone
  - CI runs on PRs touching `android/`
  - Play Console account is active and the closed-testing requirement for new accounts is confirmed in writing — `[OPEN]` verify the current tester-count/duration policy at setup time ([00](00-execution-plan.md) recorded "14 test users"; Google has changed this number more than once)

### B121 — Port the portable core with cross-platform parity fixtures

- **Spec refs:** [01](01-ios-implementation.md) bootstrap module list, [04](04-testing-and-quality.md) simulator harness
- **Depends on:** B120; B141 must land before the parity `.expected.json` values are frozen (port against the current scorer if B141 is in flight, then regenerate once)
- **Effort:** 1.5–2 weeks
- **RED**
  - move the fixture corpus to repo-root `fixtures/sensor/` and prove the existing Swift suite still discovers and passes every pair
  - Kotlin parity suite in `:core` that loads the same corpus and fails for missing implementation
  - an architecture test (Konsist or lint rule) failing if `:core` imports `android.*`
- **GREEN**
  - port the eight rows of the Portable Core table above, module by module, keeping names recognizably parallel
  - port the truth-table and clock-injected unit tests alongside each module, not as an afterthought batch
- **Acceptance**
  - every shared fixture produces identical window counts and pothole flags on both platforms, RMS within ±0.001g
  - `:core` is JVM-only; the architecture test enforces it in CI
  - adding a new fixture pair to `fixtures/sensor/` makes both suites pick it up with no code changes

### B122 — Sensor and location services with Android-specific clamping

- **Spec refs:** [00](00-execution-plan.md) delta table, [01](01-ios-implementation.md) sensor-wrapper conventions
- **Depends on:** B121
- **Effort:** 1 week
- **RED**
  - interface-backed fakes for motion, location, activity, thermal, and battery (mirror the iOS protocol-seam rule — never mock `SensorManager` directly)
  - resampler unit tests: uneven `TYPE_LINEAR_ACCELERATION` delivery → stable 50Hz stream, 60Hz clamp enforced
  - thermal mapping tests: `PowerManager` thermal status → the pipeline's nominal/fair/serious/critical states
  - battery guard test: missing/invalid battery level maps to `.unknown`, never to "exhausted" (same trap as the iOS simulator `-1.0`)
- **GREEN**
  - `MotionService` over `SensorManager` (`TYPE_LINEAR_ACCELERATION`, `SENSOR_DELAY_GAME`, timestamp resampling)
  - `LocationService` over `FusedLocationProviderClient` at 1Hz with accuracy/heading/speed passthrough
  - `DrivingDetector` over the ActivityRecognition transition API (automotive enter/exit)
  - `ThermalMonitor` over `PowerManager.addThermalStatusListener` (API 29+), `BatteryMonitor` over the sticky `BatteryManager` broadcast
- **Acceptance**
  - all services are fake-backed and isolated from pipeline logic, parity with the iOS seam design
  - an on-device debug log shows ≥ 45Hz effective accel delivery on two device classes (one Pixel-class, one Samsung-class)

### B123 — Foreground service, notification, and passive-collection lifecycle

- **Spec refs:** [00](00-execution-plan.md) delta table, [06](06-security-and-privacy.md)
- **Depends on:** B122
- **Effort:** 1–1.5 weeks
- **RED**
  - state-machine unit tests for service start/stop across: user start, activity-transition start, drive end, pause from notification, thermal stop
  - permission-state mapping tests covering fine location, `ACCESS_BACKGROUND_LOCATION`, `ACTIVITY_RECOGNITION`, `POST_NOTIFICATIONS`, and `FOREGROUND_SERVICE_LOCATION` on Android 14+
  - test that a background-initiated start without background-location permission degrades to "armed, will record when opened" rather than silently failing
- **GREEN**
  - `RecordingForegroundService` with `foregroundServiceType="location"` and a persistent notification showing recording state plus a pause action
  - activity-transition auto-start path using the documented background-start exemption
  - prominent-disclosure screen shown *before* the background-location system prompt (Play policy requires this ordering)
  - manifest declarations, `android:allowBackup="false"`, and `dataExtractionRules` excluding the Room DB
- **Acceptance**
  - 1-hour locked-screen drive collects with no gap > 5 minutes on Android 14 hardware
  - the notification is dismissible only by stopping collection (in-app or notification action), per the [00](00-execution-plan.md) release criteria
  - revoking background location at the OS level produces the documented degraded state, not a crash or a silent dead app

### B124 — Room persistence, WorkManager drain, and encrypted token storage

- **Spec refs:** [01](01-ios-implementation.md) persistence/upload sections, [03](03-api-contracts.md), [08](08-implementation-backlog.md) B072 semantics
- **Depends on:** B121 (uses `UploadQueueCore` and `DeviceTokenManager` ports), B122
- **Effort:** 1 week
- **RED**
  - Room schema tests mirroring the SwiftData shapes (readings, upload batches, privacy zones, user stats, token record)
  - queue tests proving `nextAttemptAt` persistence, stale-`.inFlight` recovery, and `drainUntilBlocked()` behavior match the B072 contract exactly
  - WorkManager test-harness coverage for network-constrained retry and backoff
  - token tests: monthly rotation via the ported `DeviceTokenManager`, storage in `EncryptedSharedPreferences`, never logged
- **GREEN**
  - Room entities + DAOs, retention/cleanup policies matching iOS
  - uploader using the shared DTO shapes via kotlinx-serialization against the unchanged `/upload-readings` contract
  - drain triggers: drive-end (delayed ~15m), app-foreground, and a periodic WorkManager fallback — all funneled through one drain coordinator, same single-active-drain rule as iOS
- **Acceptance**
  - same `batch_id` reused across retries; a killed in-flight upload recovers on relaunch without stranding the batch
  - airplane-mode → online transition drains automatically without user action
  - the server cannot distinguish a well-behaved Android batch from an iOS one except by the documented `platform` field

### B125 — Compose UI: map, onboarding, settings, privacy zones

- **Spec refs:** [01](01-ios-implementation.md) feature surfaces, [04](04-testing-and-quality.md) UX QA criteria
- **Depends on:** B123, B124
- **Effort:** 1.5–2 weeks
- **RED**
  - Compose UI tests for permissions-first onboarding order, ready shell, settings actions, delete-local-data, and the privacy-zone editor
  - a deterministic non-Mapbox testing surface for UI automation, mirroring the iOS `ROAD_SENSE_TEST_SCENARIO` approach
- **GREEN**
  - port the iOS information architecture, not pixel-for-pixel screens: map shell with recording pill + contribution card + legend, stats, settings, map-backed privacy-zone editor, segment detail sheet from `GET /segments/{id}`
  - Mapbox Android vector-tile rendering with feature-state tap highlighting and the dashed local-drive overlay
  - TalkBack labels and font-scale resilience to parallel the iOS Dynamic Type pass
- **Acceptance**
  - the [04 §UX / Design QA](04-testing-and-quality.md) first-time-user criteria pass on Android with non-implementers
  - a user can tap a segment and see the documented detail sheet backed by the live API
  - core flows survive 2× font scale

### B126 — Android field validation and cross-platform consistency drives

- **Spec refs:** [04](04-testing-and-quality.md) field tests, [09](09-internal-field-test-pack.md)
- **Depends on:** B125; B140/B141 complete (thresholds final)
- **Effort:** 1 week (calendar overlaps with B127)
- **RED**
  - extend [09](09-internal-field-test-pack.md) with an Android device-setup section (battery optimization exemption check, OEM kill-list caveats for Samsung/Xiaomi-class devices, notification visibility)
- **GREEN**
  - run the required drive scenarios from [09](09-internal-field-test-pack.md) on Pixel-class and Samsung-class devices
  - same-drive consistency run: one vehicle, iOS and Android devices mounted together, 3+ routes from the calibration table
  - battery and thermal characterization on both device classes
  - capture Android sensor CSVs into `fixtures/sensor/` (they exercise the resampler in ways synthetic fixtures cannot)
- **Acceptance**
  - paired-drive scoring within ±10% of iOS per [00](00-execution-plan.md) release criteria
  - battery drain < 20%/hr on a Pixel 7-class device
  - no crashes across 5+ internal drives; [09](09-internal-field-test-pack.md)-shaped evidence captured

### B127 — Play listing, data safety, testing tracks, and launch

- **Spec refs:** [10](10-app-store-and-testflight-readiness.md) (structure to mirror), [06](06-security-and-privacy.md) (policy source of truth)
- **Depends on:** B126
- **Effort:** ~1 week of work spread across the closed-testing soak
- **RED**
  - pre-submission checklist mirroring [10](10-app-store-and-testflight-readiness.md): store fields that must not drift (app name, application ID, privacy policy URL `https://roadsense.ca/privacy`, contact email), Data safety answers derived from [06](06-security-and-privacy.md), reviewer-facing background-location justification
- **GREEN**
  - store listing: description, screenshots from a real signed build (same no-fake-states rules as iOS), feature graphic
  - Data safety form: precise location collected, not shared, encrypted in transit, deletable; answers must match [06](06-security-and-privacy.md) exactly — if they cannot, stop and reconcile the docs first
  - background-location declaration + demo video showing the prominent disclosure flow (required by the B123 decision)
  - content rating questionnaire, target-API compliance check
  - track progression: Internal testing (team) → Closed testing (meets the new-account tester/duration requirement) → Production with a staged rollout (10% → 50% → 100%)
- **Acceptance**
  - closed-testing requirement satisfied and production access granted
  - production listing live; Data safety answers verifiably match the implementation
  - a cross-platform release note ships to the existing tester pool and the web map gains Android contributors

### Android Week-By-Week (6–8 weeks)

Weeks are labeled A1–A8 to avoid colliding with the MVP week numbering in [00](00-execution-plan.md). A1 begins when the entry criteria above hold.

```
A1 ──┬─ B120 Play Console enrollment (day 1 — verification can take days)
     ├─ B120 project bootstrap + CI
     ├─ B121 fixture-corpus promotion to fixtures/sensor/
     └─ (parallel, iOS side) B140 calibration drives + B141 scorer — freezes parity targets

A2 ──┬─ B121 portable-core port + parity suite green
     └─ B122 sensor/location wrappers started

A3 ──┬─ B122 complete (resampler validated on hardware)
     └─ B123 foreground service + lifecycle + disclosure flow

A4 ──┬─ B123 device validation on Android 14
     ├─ B124 Room + WorkManager + token storage
     └─ first sideloaded daily-dogfood build on own device

A5 ──┬─ B125 Compose UI: map shell, onboarding, settings
     └─ Internal testing track build #1

A6 ──┬─ B125 complete (privacy zones, segment detail, accessibility pass)
     ├─ B126 field drives: paired iOS/Android consistency runs
     └─ B127 listing drafts + Data safety + declaration video

A7 ──┬─ B126 battery/thermal characterization + fixes
     └─ B127 Closed testing begins (tester-requirement clock starts)

A8 ──┬─ closed-testing soak + bug fixes
     └─ Production submission at soak end
```

Weeks A7–A8 are dominated by Google's clocks (closed-testing duration, review latency), not engineering. If the new-account testing requirement or the background-location review adds friction, production lands in week A9–A10; treat that as buffer, not slip. Total engineering effort is ~7–9 weeks of work compressed into 6–8 calendar weeks because A6–A8 overlap heavily.

### Android Release Criteria

The [00 §Android Follow-On](00-execution-plan.md) criteria apply unchanged: iOS-parity MVP criteria, ±10% paired-drive scoring, < 20%/hr battery on Pixel 7-class, and a foreground-service notification that is honest and only dismissible by stopping. One addition:

4. The shared `fixtures/sensor/` parity suite is green on both platforms in CI, and CI runs as a matrix (iOS + Android) per [00](00-execution-plan.md) week-18 intent.

## Phase 13 — Calibration & Trust (B140–B143)

The credibility of every growth artifact in Phase 14 rests on this phase. The roughness thresholds currently in the docs (< 0.3g smooth, 0.3–0.6 fair, 0.6–1.0 rough, > 1.0 very rough) are labeled "need real-world calibration" in the product spec and have never been driven against real roads. The B050 repo note is explicit that `RoughnessScorer` is still a direct-RMS placeholder. Do not pitch media on numbers we have not calibrated.

### B140 — Known-roads calibration protocol and threshold lock

- **Spec refs:** [04 §Calibration Drive](04-testing-and-quality.md), [02](02-backend-implementation.md) category mapping, product-spec §Roughness Categories
- **Depends on:** dev-mode CSV recorder (exists), simulator harness (exists), a signed on-device build
- **Effort:** 2–3 days driving + 2–3 days analysis
- **RED**
  - write the acceptance bands *before* driving: the six known roads from [04](04-testing-and-quality.md) (Highway 102 smooth, Bayers Rd fair, Robie St rough+potholes, Agricola St very rough, Purcell's Cove unpaved, Chebucto Rd speed-bump suppression) each get an expected category and an expected-failure note
  - a threshold-inventory checklist enumerating every place the category boundaries live (see update path below) so none drifts silently
- **GREEN**
  - drive each road 3× at 40/60/80 km/h where legal; record raw CSVs via the dev-mode recorder
  - import into the simulator harness; compute per-road, per-speed RMS distributions
  - choose thresholds such that known roads land in their expected categories; quantify cross-speed spread per road (this is the input that justifies or kills speed normalization in B141)
  - promote the best clips into `fixtures/sensor/` as golden fixtures with real-world provenance
- **Threshold update path** (the part that must be spec'd, because thresholds live in four places):
  1. server: the category `CASE` expressions in `update_segment_aggregates_from_batch` and `nightly_recompute_aggregates` — changed via one migration that also queues a full-segment `nightly_recompute_aggregates` run so existing aggregates recategorize
  2. iOS: legend copy and `RoadQualityStyle` color breaks
  3. web: legend, methodology page, and worst-roads category labels
  4. docs: product-spec table and [02](02-backend-implementation.md)
  - one PR changes all four, plus deliberately regenerated `.expected.json` fixture values with the justification in the PR body. A threshold change that touches fewer than all four locations is a bug.
- **Acceptance**
  - the three known-good and three known-bad roads are visually distinct on the map (the M3 criterion, now with evidence)
  - the same road at different speeds lands in the same category in ≥ 2 of 3 runs, or B141's speed normalization is explicitly tasked with closing the gap
  - calibration evidence (dates, routes, distributions, chosen thresholds) is appended to this doc and referenced from the methodology page

### B141 — Calibrated `RoughnessScorer` replaces the direct-RMS placeholder

- **Spec refs:** [01](01-ios-implementation.md) scoring section, [08](08-implementation-backlog.md) B050 repo note
- **Depends on:** B140 data
- **Effort:** 3–5 days
- **RED**
  - failing scorer tests with speed-normalized expectations derived from B140's distributions
  - same-road-different-speed fixture pairs asserting category stability
- **GREEN**
  - implement `RoughnessScorer` proper (speed normalization over the high-pass-filtered RMS) and remove the direct-RMS placeholder from `SensorCoordinator`
  - regenerate `.expected.json` values once, deliberately, with the B140 evidence cited
- **Acceptance**
  - full fixture suite green with the new scorer
  - cross-speed category stability meets the B140 bar
  - the B050 repo note in [08](08-implementation-backlog.md) can be marked resolved
  - **blocking note:** B121's parity targets freeze only after this lands — sequence it inside Android weeks A1–A2

### B142 — Battery benchmark execution and documentation

- **Spec refs:** [04 §Battery Benchmark](04-testing-and-quality.md), [00](00-execution-plan.md) risk table, [09](09-internal-field-test-pack.md)
- **Depends on:** signed builds on two device classes
- **Effort:** 2 days
- **RED**
  - the protocol is already written in [04](04-testing-and-quality.md); the RED step is preparing the evidence template (per-15-minute battery table, device/iOS/build columns) before the drive so results cannot be reported impressionistically
- **GREEN**
  - execute the [04](04-testing-and-quality.md) protocol exactly: reference device + older device, full charge, screen off, 1-hour mixed city/highway drive, recorded at start/every 15 min/end, once on Wi-Fi-only and once on active cellular
  - if the < 15%/hr reference bar fails, execute the documented risk response from [00](00-execution-plan.md) (0.5Hz GPS low-battery mode, longer buffer flush) and re-measure — do not ship a marketing push on an app people will blame for battery drain
- **Acceptance**
  - < 15%/hr on the reference device, < 20%/hr on the older device
  - results table captured as [09](09-internal-field-test-pack.md)-style evidence and the number reflected honestly in App Store/Play descriptions and the methodology page

### B143 — NS-scale OSM import dry run and segment-count validation

- **Spec refs:** [02](02-backend-implementation.md) import pipeline, [05 §OSM Re-import](05-deployment-and-observability.md), [00](00-execution-plan.md) risk table
- **Depends on:** B011
- **Effort:** 1–2 days
- **RED**
  - an assertion script (extends the existing import fixtures) that checks: total segment count within the documented 300k–600k band, count within ±5% of the prior import, `osm_way_id/segment_index` uniqueness, municipality-tag coverage ≥ 99% of segments, and known-gravel spot checks (Purcell's Cove section tagged unpaved)
- **GREEN**
  - run the full pinned `nova-scotia-latest.osm.pbf` import against a production-shaped instance (not just the Halifax fixture subset)
  - record snapshot date, wall-clock duration, row counts, and post-import DB size
- **Acceptance**
  - segment count lands inside the band; DB size respects the [00](00-execution-plan.md) trip-wire (> 500k segments or > 1.5GB triggers the documented mitigation: drop minor residential below z14, simplify geometry, `ST_SnapToGrid`)
  - timing and counts give B100 (quarterly refresh rematch) a real operational budget instead of a guess
  - results recorded in the [05](05-deployment-and-observability.md) runbook context

## Phase 14 — Growth & Advocacy Surfaces (B150–B153)

The marketing plan is concrete: post into Nova Scotia road-condition Facebook groups and pitch local media ("worst roads" stories are reliably picked up). That plan needs artifacts that are *shareable, screenshot-friendly, and credible* — a pasted link must unfurl into something legible, a journalist must be able to cite us correctly without a phone call, and every number must carry its confidence caveat so the first skeptical commenter doesn't sink the thread. Phase W1 of [07](07-web-dashboard-implementation.md) deliberately excluded exports and saved reports; this phase adds the thinnest versions that serve the channel strategy, without pulling in the W2 analyst layer.

All four tickets are web-only, read from public endpoints only, and must never require raw-reading exposure (Hard Stop rule from [08](08-implementation-backlog.md) applies).

### B150 — Worst Roads report: share, OG, and CSV-export polish

- **Spec refs:** [07 §/reports/worst-roads](07-web-dashboard-implementation.md), [08](08-implementation-backlog.md) B081/B093
- **Depends on:** B093 (page is live), B081
- **Effort:** 4–6 days
- **RED**
  - metadata tests: `generateMetadata` produces municipality-aware titles/descriptions (`Worst roads in Halifax | RoadSense NS`) for each filter state
  - OG-image route test: rank-aware card renders with legend colors and an as-of date
  - CSV golden-file test: documented column set, stable ordering, caveat row present
  - Playwright: copy-link flow and CSV download from a filtered report
- **GREEN**
  - per-state OG metadata driven by `SITE_URL` per [07](07-web-dashboard-implementation.md) env rules; dynamic OG image (Next `ImageResponse`) showing the top-3 rows, municipality, and date
  - share affordance: `navigator.share` with clipboard fallback — the existing URL-state work already makes links reconstruct the view
  - client-side CSV export of the loaded rows (no new backend surface; W2 export endpoints stay deferred). Columns: `rank, road_name, municipality, category, confidence, trend, avg_roughness_score, pothole_count, data_as_of`, plus a final caveat row quoting the on-page ranking disclaimer
  - visible "data as of" stamp and a print stylesheet so the page screenshots and prints cleanly
- **Acceptance**
  - pasting a filtered report URL into Facebook/Slack unfurls with the correct municipality, ranks, and image
  - the CSV opens cleanly in Excel/Numbers and contains nothing not already public on the page
  - no new privileged endpoints; Lighthouse budgets from B094 still pass

### B151 — Media kit page

- **Spec refs:** [07](07-web-dashboard-implementation.md) content-page conventions, [06](06-security-and-privacy.md)
- **Depends on:** B094 (content-page test conventions), B150
- **Effort:** 3–4 days
- **RED**
  - content-page tests in the B094 style: required sections present, no broken anchors, accessibility budget
- **GREEN**
  - `/media` route containing: a two-paragraph plain-language description of RoadSense NS, the citation format (`Source: RoadSense NS community road-quality data, as of <date>`), live headline stats from `GET /stats`, a downloadable asset pack (logo, app screenshots, one annotated map screenshot — same no-fake-states rules as [10](10-app-store-and-testflight-readiness.md)), links to methodology/privacy/worst-roads, contact email, and explicit usage guidance (confidence caveats must travel with the numbers; do not imply municipal endorsement)
- **Acceptance**
  - a journalist can go from landing on `/media` to having a correct citation, a usable image, and a methodology link in under five minutes without emailing us
  - copy aligns with the privacy policy and store listings; trust-page Lighthouse budgets pass

### B152 — Pothole-season recap report

- **Spec refs:** [07](07-web-dashboard-implementation.md), [02](02-backend-implementation.md) public read surfaces
- **Depends on:** B150, B151, and enough accumulated data to be honest (≥ one full freeze–thaw season of collection)
- **Effort:** 4–5 days for the first edition; 1–2 days per subsequent season
- **RED**
  - recap-template tests against fixture data: every stat slot renders, empty/thin-data states degrade to honest copy instead of fake precision
  - reproducibility test: the build pins an as-of date and the same date reproduces the same numbers
- **GREEN**
  - `/reports/pothole-season-<year>`: statically generated recap covering new potholes reported, confirmed-fixed count, the worst-10 movers (improved vs worsened), contributor and coverage growth, and a municipality comparison — sourced exclusively from public read endpoints (`/stats`, `/segments/worst`, `/potholes`)
  - OG image card designed to double as the Facebook post image
  - publication timing keyed to NS freeze–thaw (March–May); an optional late-fall edition if the data supports it
- **Acceptance**
  - every number in the recap is reproducible from documented queries at the pinned date
  - the page unfurls correctly when shared; the recap reads as a public explainer, not an internal metrics dump
  - thin-coverage municipalities are excluded or caveated, never extrapolated

### B153 — Councillor outreach one-pagers

- **Spec refs:** [07](07-web-dashboard-implementation.md), [00](00-execution-plan.md) post-launch list ("first municipal contact — informal")
- **Depends on:** B081, B093, B150
- **Effort:** 3–4 days
- **RED**
  - print-layout test (Playwright PDF snapshot): one Letter page, no clipped rows
  - content tests: required sections, caveat presence, no raw-reading or per-drive data anywhere
- **GREEN**
  - `/reports/one-pager/[slug]` per manifest municipality: top-10 worst segments with categories and confidence labels, coverage summary, trend highlights, a three-sentence "what RoadSense NS is" footer, methodology link, contact email, and a "prepared <date>" stamp
  - print stylesheet tuned for a single page; the browser print dialog is the PDF export — no server-side PDF pipeline
- **Acceptance**
  - prints to exactly one page; a councillor or constituency assistant can absorb it in under a minute
  - numbers match the live worst-roads report for the same municipality on the same day
  - tone stays civic-data-neutral: the artifact informs an angry-resident conversation without becoming the angry resident

## Phase 15 — Deferred Items: Triggers And Scheduling

These keep their existing ticket IDs and spec locations. They are scheduled by trigger; pulling them forward "because they look adjacent" is the same scope-creep failure mode [08](08-implementation-backlog.md) warns about for B100.

| Item | Ticket / spec home | Trigger / earliest sensible slot |
|---|---|---|
| My Drives list | B076/B077 in [08 Phase 11c](08-implementation-backlog.md), spec'd in [01 §My Drives List](01-ios-implementation.md) | Purely local feature, no backend. Pull when TestFlight feedback repeatedly asks "where are my drives," or as the iOS polish slot after Android week A8. Port to Android only after it proves its keep on iOS. |
| OSM refresh rematch | B100 in [08 Phase 11](08-implementation-backlog.md) | Calendar-driven: first quarterly refresh ≈ 3 months after the pinned MVP snapshot date. B143's dry run supplies the operational budget. Do not pull earlier — the first import has nothing to rematch. |
| Pothole follow-up UX polish | B110 in [08](08-implementation-backlog.md) | After the first wave of external-tester feedback on the existing prompts. |
| DeviceCheck / Play Integrity attestation | [06](06-security-and-privacy.md), README deferred list | Observed abuse, not anticipated abuse. Note Android adds Play Integrity as the sibling mechanism — design the server check once for both. |
| Vehicle-type calibration factors | README deferred list, [00](00-execution-plan.md) risk table | Trip-wire from [00](00-execution-plan.md): cross-user score variance > 30% on 100+ calibration readings. B140 produces the first real measurement of this. |
| Gamification (leaderboards, badges) | README deferred list | Not scheduled. Revisit only with evidence that contribution volume — not awareness — is the growth bottleneck. |
| French localization | [04 §Internationalization](04-testing-and-quality.md) | First francophone-municipality outreach or sustained requests. The `Localizable.strings` discipline keeps this cheap; mirror it in Android string resources from day one (B125). |
| Open-source the repo | [00](00-execution-plan.md) post-launch list | Right after iOS launch stabilizes. Cheap, and it strengthens the B151 media kit ("inspect our methodology and code"). |
| Cape Breton expansion | [00](00-execution-plan.md) post-launch list | Not an engineering ticket — the OSM import is already province-wide. This is a manifest check (CBRM entry present and correct) plus B152/B151-driven outreach into CBRM groups. |

## Hard Stop Rules

Stop and reassess if:

- Android paired-drive scoring cannot reach ±10% of iOS after B140/B141 calibration — do not launch on Play with a map that disagrees with itself
- Google rejects the background-location declaration — ship the user-initiated-recording variant rather than fighting policy review on the critical path
- any Phase 14 artifact starts to require raw-reading exposure to feel compelling — same architecture warning as [08](08-implementation-backlog.md)
- B140 reveals cross-user variance > 30% — pause the media push and pick up vehicle-type calibration before marketing the data's credibility
- the Play Data safety answers and [06](06-security-and-privacy.md) cannot be made to match — reconcile the docs and implementation before any store submission, exactly as the iOS rule reads
