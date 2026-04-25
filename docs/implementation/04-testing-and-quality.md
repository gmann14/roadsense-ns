# 04 — Testing & Quality

*Last updated: 2026-04-23*

How we verify each part of the system works, stays working, and that the roughness data we publish is trustworthy. Sensor apps fail in subtle ways (small drift, bad in edge cases, fine in simulator); this doc is biased toward catching those failures.

## Testing Pyramid

```
          ┌──────────────────────────────┐
          │  Field tests (real driving)  │  ← highest truth, lowest frequency
          ├──────────────────────────────┤
          │  End-to-end smoke (staging)  │
          ├──────────────────────────────┤
          │ Integration (API + DB)       │
          ├──────────────────────────────┤
          │ Simulator harness (CSV play) │
          ├──────────────────────────────┤
          │ Unit tests                   │  ← cheapest, fastest, most
          └──────────────────────────────┘
```

## Unit Tests

### iOS

Tests live in `RoadSenseNSTests/`. Use `XCTest` + `Quick/Nimble` only if we hit readability limits — prefer plain XCTest. Run every PR in CI via `xcodebuild test`.

Generated-project note:

- `ios/project.yml` is the source of truth for the app and both test bundles.
- `RoadSenseNSTests` and `RoadSenseNSUITests` now pin dedicated `Info.plist` files so `xcodegen generate` does not regress `.xctest` packaging into app-style bundles.

**What gets unit-tested (non-exhaustive):**

| Module | Coverage |
|---|---|
| `RoughnessScorer` | Deterministic scoring of canned signals (synthetic sine, step, real CSV clip). Asserts filtered vertical-acceleration RMS against checked-in fixture envelopes. |
| `PotholeDetector` | Synthetic dip-then-spike, synthetic braking (should NOT trigger), real pothole CSV (should trigger). |
| `PrivacyZoneFilter` | Point in zone, point at boundary, point outside, multiple overlapping zones. |
| `DriveEndpointTrimmer` | Prefix/suffix time trimming, start/end radius trimming, overlap of both rules, short-drive fully-trimmed behavior, and deterministic recovery after relaunch from persisted session endpoints. |
| `ManualPotholeLocator` | chooses the buffered location nearest `tapTimestamp - 0.75s`, falls back to `latestSample`, rejects stale/poor-accuracy state, and preserves deterministic behavior around sparse GPS samples. |
| `QualityFilter` | Speed, GPS accuracy, thermal state combinations — truth table. |
| `ReadingBuilder` | Window closes at 50m, window aborts at > 15s, window discards at thermal.serious. |
| `Uploader` | Retry backoff scheduling (inject clock), idempotency (same batch_id on retry), 429 respects Retry-After, batch_size cap, `.inFlight` crash recovery, and `drainUntilBlocked()` stopping on `nextAttemptAt`. |
| `UploadDrainCoordinator` | Foreground + BG triggers collapse to one active drain; cancellation clears active task; drain order runs pothole actions before photos before readings. |
| `PotholeActionUploader` | 5-second undo window, dedupe of repeated taps within 20m / 8s, idempotent retry on `action_id`, `409 stale_target` handling for follow-up, privacy-zone rejection before enqueue, and refusal to discard expired pending-undo rows after the window has closed. |
| `PhotoUploader` | low-speed freshness gate, Nova Scotia bounds gate, precise `latestSample` coordinate persistence, metadata POST + PUT happy path, signed-URL reissue after expiry/background, `segment_id` propagation, 409 treated as success, and local-file deletion on success only. |
| `PrivacyZone` | Offset creation is randomized + deterministic-given-seed, never persists un-offset coords. Statistical test: 1000 offsets for the same zone have std. dev. ≥ 60m in both lat and lng (proves the randomization isn't collapsed). |
| `DeviceToken` | Rotation on month boundary, persistence across launches. |
| `PermissionManager` | Each permission state → correct UI directive. |
| `SchemaMigrationPlan` | v1 store opens under v2 and v3 without data loss; migration failure surfaces repair UI instead of silently resetting the store. |

**Coverage targets:** 80% line coverage on `Pipeline/`, `Sensors/`, `Privacy/`, `Network/`. No minimum for `Features/` (UI) — SwiftUI view coverage is noise.

**Avoid:**
- Snapshot tests for SwiftUI views (brittle under Xcode version changes)
- Mocking `CMMotionManager` directly — wrap it in a protocol and mock the protocol
- Async tests without explicit `async`/`await` + `fulfillment(of:)`

**Simulator gotchas:**
- `UIDevice.current.batteryLevel` always returns `-1.0` in the iOS Simulator regardless of `isBatteryMonitoringEnabled`. Any battery-aware code path (e.g., pause-below-15%) must be exercised via a `BatteryService` protocol seam and mocked in CI. Never let `-1.0` reach the pause logic — it would either be interpreted as "battery exhausted" or short-circuit pause checks. Guard with `batteryLevel < 0 ? .unknown : .level(batteryLevel)`.
- `CLLocationManager` in the simulator doesn't generate `significantLocationChange` without the Freeway/City-Bicycle-Ride route recipe — document which recipe each field test uses.
- `CMMotionActivityManager.isActivityAvailable()` returns `false` in the simulator; integration tests that assert on `.automotive` must run on a real device.

### Backend

Tests live in `supabase/tests/`. Use `pgTAP` (Postgres test framework). Run in CI against the locally-booted Supabase via `supabase test db`.

**What gets tested:**

| Module | Coverage |
|---|---|
| `ingest_reading_batch` | Happy path, duplicate batch returns the same result, concurrent duplicate retry on the same `batch_id` returns a clean duplicate response rather than a PK-violation 502, and batches with no matches / out-of-bounds readings are counted correctly. |
| Map-matching KNN query | Known point on known segment → correct segment_id. Known point between parallel roads → correct disambiguation by heading. |
| `update_segment_aggregates_from_batch` | Weighted average math, confidence tier thresholds, category boundaries. |
| `nightly_recompute_aggregates` | Outlier trimming correctness, recency weighting, trend detection (improving/worsening/stable). |
| `fold_pothole_candidates` | New pothole, confirmation of existing, too-far-away creates new. |
| `apply_pothole_action` | manual report folds into nearest cluster, same-device 24h duplicates do not inflate counts, stale-target rejection for follow-up, 2-reporter fixed quorum resolves, and later positive confirmation re-activates resolved potholes. |
| `approve_pothole_photo` / `reject_pothole_photo` | moderation state transitions, approved-photo fold-in to `pothole_reports`, rejection handling, and invalid-state rejection. |
| moderation queue hardening | `moderation_pothole_photo_queue` uses `security_invoker`, and the approve-path nearby lookup stays index-backed via `idx_potholes_geog`. |
| `expire_unconfirmed_potholes` | 90-day threshold, idempotent. |
| Read-side models | `public_stats_mv` refreshes cleanly, `GET /segments/{id}` joins the right aggregate row, pothole bbox query respects the max area cap. |
| Partition management | Next-month partition auto-created, old partition dropped. |
| Rate limits | Per-device and per-IP counters increment; window slides correctly. |

**Avoid:** Testing via anon-key only — some tests need service-role; mark those clearly.

### Edge Functions

Tests live in `supabase/functions/<fn>/test.ts`. Use Deno's built-in `Deno.test` + `supabase start` for a local stack.

- Contract tests per endpoint: valid payload → 200, malformed payload → 400 with exact field_errors, all-soft-rejected payload → 200 with populated `rejected_reasons`
- Rate limit test: 51st request in 24h → 429 with Retry-After
- `POST /pothole-actions`: duplicate `action_id` is idempotent, same-device repeats within 24h do not inflate counters, `confirm_fixed` does not resolve on one vote, second distinct fixed vote resolves, and a later positive confirmation re-activates the same pothole
- `POST /pothole-photos`: repeat POST while `pending_upload` returns a fresh signed URL, 409 after completed upload, and mismatched metadata (`sha256` / size / content type) on the same `report_id` is rejected
- `POST /pothole-photo-moderation`: internal auth required, approve path rolls Storage back if the RPC fails after a move, and reject path does not delete Storage before the DB state changes
- Tile test: empty tile → 204 with cache headers, non-empty tile → 200 with MVT content-type
- Read-endpoint tests: `/segments/{id}`, `/potholes`, `/stats`, `/health`
- Phase-2 web contract tests: `/tiles/coverage/{z}/{x}/{y}.mvt` returns `segment_coverage` layer with only `coverage_level` semantics (no raw low-sample counts), and `/segments/worst` enforces ranking/order/filter rules exactly

### Web Dashboard (Phase 2)

Tests live in `apps/web/tests/`. Use:

- `Vitest` for unit tests
- `React Testing Library` for component/integration tests
- `MSW` for mocked API contracts in browser tests
- `Playwright` for end-to-end and visual-regression coverage

#### What gets unit-tested

| Module | Coverage |
|---|---|
| `url-state` | parse/serialize of `mode`, `segment`, `lat/lng/z`, invalid param fallback |
| `municipality-manifest` | unique slugs, exact display-name mapping, finite bbox coordinates |
| display formatters | confidence labels, freshness labels, score rounding, trend labels |
| search normalization | municipality-first matching before geocoder fallback |

#### What gets integration-tested

| Surface | Coverage |
|---|---|
| Home map shell | legend, trust strip, and mode switcher render before client-side data settles |
| Segment drawer | skeleton → resolved content, bad `segment` query param fails gracefully |
| Search | municipality route transition, place search pans map without mutating mode, keyboard-only search and mode navigation, recoverable no-results state |
| Potholes mode | bbox requests debounced and skipped outside potholes mode |
| Coverage mode | legend explicitly explains that coverage is not road condition |
| Worst Roads page | caveat header, municipality filtering, stable rank ordering |
| Trust pages | Lighthouse accessibility and CLS budgets on methodology/privacy |

#### What gets end-to-end tested

Required Playwright journeys:

1. `/` loads with visible map, legend, and trust strip
2. `/municipality/halifax` initializes to Halifax context
3. selecting a segment opens detail drawer with real content
4. switching between quality, potholes, and coverage preserves route state correctly
5. search routes to municipality pages when the selected result is a municipality
6. `/reports/worst-roads` renders ranked rows and updates on municipality change
7. `/methodology` and `/privacy` expose trust-critical copy without broken anchors

#### Visual regression coverage

Capture stable screenshots for:

- desktop home
- desktop municipality route
- mobile home
- mobile segment drawer
- worst-roads page

Do not treat screenshots as a substitute for interaction tests. They are a drift alarm only.

## Simulator Harness (iOS)

The trickiest part of this app is sensor processing. We need a deterministic way to replay real sensor data into the pipeline without driving a car.

### Concept

A separate target `RoadSenseNSSimHarness` that boots the app-less equivalent of:

```
CSV file of raw sensor data (recorded from real drive)
    ↓
Replay at 50Hz into MotionService (in-process fake)
    ↓
Replay at 1Hz into LocationService (in-process fake)
    ↓
Full production Pipeline runs
    ↓
Output: list of emitted ReadingWindows
    ↓
Assert: matches expected scoring for that drive
```

### CSV format

```
timestamp,type,value1,value2,value3,value4,value5
2026-04-10T10:00:00.000Z,gps,44.6488,-63.5752,62.3,184.5,6.5
2026-04-10T10:00:00.020Z,accel,0.12,-0.04,0.98,,
2026-04-10T10:00:00.040Z,accel,0.11,-0.05,1.01,,
```

`type=gps`: `value1=lat, value2=lng, value3=speed_kmh, value4=heading, value5=gps_accuracy_m`
`type=accel`: `value1=x, value2=y, value3=z` (raw `userAcceleration` in G's; value4/value5 empty)
`type=gravity`: `value1=x, value2=y, value3=z` (gravity vector in G's; value4/value5 empty)
`type=thermal`: `value1=state` (0=nominal, 1=fair, 2=serious, 3=critical; value2..5 empty) — synthesize these in tests to exercise thermal throttling
`type=activity`: `value1=automotive|stationary|walking|unknown` (value2..5 empty) — drives the Motion-activity gate

Timestamps must be strictly monotonic. Fixture files are UTF-8, LF line endings, no BOM, no trailing comma. The harness rejects files that violate any of these.

Record real drives via a hidden dev-mode "start recording" toggle that writes this format to a file. Check fixtures into `RoadSenseNSSimHarness/Fixtures/`.

### Golden fixtures

Commit these to the repo (small — ~1MB each):

- `smooth-highway.csv` — 5 minutes on Highway 102 (recorded 2026-04-XX)
- `pothole-hit.csv` — 30s clip around a known pothole on Robie St
- `speed-bump.csv` — 30s approach+cross of a known speed bump
- `rail-crossing.csv` — 30s approach+cross of a known rail crossing
- `stopped-at-light.csv` — 5 min with multiple stops
- `pocket-orientation.csv` — recorded with phone in pocket (orientation test)
- `mount-orientation.csv` — recorded with phone dash-mounted
- `low-gps-urban.csv` — downtown Halifax with known GPS dropouts
- `home-endpoints.csv` — drive fixture where the first/last minute and first/last 300m should be trimmed from upload eligibility

Each fixture has an accompanying `.expected.json` with the assertion targets:

```json
{
    "fixture": "pothole-hit.csv",
    "expected_windows": 1,
    "expected_pothole_flagged": true,
    "expected_rms_range": [0.63, 0.68],
    "expected_max_spike_g_range": [2.5, 4.0]
}
```

CI runs the harness against every fixture on every PR.

For `home-endpoints.csv`, `.expected.json` must also assert `trimmed_prefix_count`, `trimmed_suffix_count`, and `eligible_upload_count` so endpoint privacy is regression-tested, not just documented.

Current repo note:

- The pure Swift layer now includes `SensorFixtureParser` and `SensorFixtureRunner`.
- A first golden-style replay test now exists in the bootstrap test suite and validates:
  - CSV parsing
  - monotonic timestamp rejection
  - full replay into `ReadingBuilder` / `PotholeDetector` / `ReadingWindowProcessor`
  - expected window count / pothole flag / RMS range / spike range assertions
- Reusable CSV + `.expected.json` fixture pairs are now checked into the bootstrap test target, covering:
  - pothole hit
  - smooth-cruise baseline
  - privacy-zone recovery
  - thermal rejection
- The dedicated `RoadSenseNSSimHarness` app target now loads and replays the same fixture pattern in a simple developer UI.
- The bootstrap harness test now auto-discovers every checked-in `.expected.json` resource and replays the matching CSV fixture, so new fixtures join the deterministic suite automatically.
- App-hosted UI smoke tests now launch against explicit in-memory scenarios (`default`, `ready-shell`) and use a non-Mapbox testing surface so simulator automation stays deterministic.
- UI smoke coverage now exercises:
  - first-run privacy gating
  - ready-shell Settings -> Privacy Zones navigation
  - seeded stats rendering
  - delete-local-data behavior from Settings
- The full `RoadSenseNS` scheme now runs green locally under `xcodebuild test`, including the current app-hosted UI suite rather than only `build-for-testing`.
- What still remains is expanding that corpus with real captured drives and keeping the harness/UI-test targets green in CI.

## Integration Tests

### iOS → Shared backend

When a hosted shared backend exists, `deploy-staging.yml` can push migrations/functions and run remote smoke checks. Until Apple approval and signed multi-device testing make that worthwhile, local Supabase plus backend CI is the default verification path.

Before a real drive or simulator-harness replay is required, keep one deterministic backend smoke in the loop:

- `./scripts/api-smoke.sh` validates the public contract surface (`/health`, `/stats`, duplicate-safe `/upload-readings`)
- `./scripts/seeded-e2e-smoke.sh` validates a seeded synthetic segment all the way through upload, aggregate update, segment detail, stats refresh, and non-empty tile emission

- Upload → 200
- Query `segment_aggregates` for the segment → new reading_count matches
- Query tile endpoint → MVT contains the segment
- Photo moderation smoke: metadata POST → signed PUT → `pothole_photos.status = 'pending_moderation'` → approve/reject path updates Storage + folds approved photos into `pothole_reports`

### Backend internal

`pgTAP` tests exercising the full DB stack — no mocks, run against a fresh Supabase stack spun up in CI via `supabase start`.

## Field Tests (THE critical test tier)

Unit and simulator tests can't catch real-world issues. Schedule these explicitly:

### Calibration Drive (week 3)

Before writing any scoring thresholds, drive known roads:

| Road | Known condition | Expected category |
|---|---|---|
| Highway 102, Bedford → Halifax | Smooth highway | smooth |
| Bayers Rd | Fair | fair |
| Robie St between Quinpool and North | Rough w/ potholes | rough + potholes |
| Agricola St | Very rough | very_rough |
| Purcell's Cove Rd (selected unpaved section) | Unpaved | n/a (filter out) |
| Chebucto Rd speed bump zone | Smooth + bumps | smooth, bumps suppressed |

Drive each road 3× at different speeds (40, 60, 80 where possible). Record raw data. Import into simulator harness. Tune thresholds.

Current early-device snapshot (2026-04-25, single tester, `.context/device-live-latest/default.store`) is directionally believable but not enough to lock calibration:

- 602 accepted readings, 27.9 km, 7 grouped trips after merging short detector fragments
- roughness RMS: p50 `0.057`, p75 `0.081`, p90 `0.104`, p95 `0.119`, max `0.194`
- current backend category thresholds produce: 43.7% smooth, 37.2% fair, 15.6% rough, 3.5% very rough

Use `./scripts/local-ios-quality-report.sh [path/to/default.store]` after each copied device dump to compare future drives against this baseline. Do not retune thresholds from this one dataset alone; wait for the known-road loop above plus repeated passes over at least one intentionally rough road.

### Battery Benchmark (week 6)

Two phone models, both fully charged:
- Reference device: iPhone 12 Pro, iOS 17.4
- Older device: iPhone XR or SE (2nd gen), iOS 17.4

Protocol:
1. Full charge, close all other apps, airplane mode off, screen OFF
2. Start app, begin drive
3. 1-hour drive, mix of city + highway
4. Record battery % at start, every 15min, and end
5. Do it twice: once on WiFi-home-base with no cellular data, once with active cellular

Acceptance: < 15%/hr on reference device; < 20%/hr on older device.

### Thermal Test (week 6)

iPhone mounted on dashboard on a sunny day, 60+ minute drive. Watch for:
- `ProcessInfo.thermalState` transitions (`.fair` is fine, `.serious` should pause collection, `.critical` should stop entirely)
- No crashes
- User-visible banner appears at `.serious`

### Background Longevity Test (week 5)

- Start app, begin drive
- Press home, lock phone
- Drive for 1 hour uninterrupted
- Check: collected readings cover the full hour, no > 5 minute gaps

### Upload Execution Stress Test (week 5)

Exercise the exact trigger collisions that usually break iOS background work:

1. build up 3+ pending reading batches offline
2. bring the app foreground online and immediately background it
3. manually trigger Background Fetch in Xcode while the foreground drain is still active
4. inject one 429 and one 5xx in successive attempts

Acceptance:

- exactly one active drain at a time
- no duplicate batch submissions with different `batch_id`s for the same readings
- `nextAttemptAt` advances correctly after 429 / 5xx
- once the retry window expires, the next drain resumes automatically without user action

### Manual Pothole Tap Accuracy Test (post-MVP)

1. run the app with the map open on a real drive over a known pothole
2. tap `Mark pothole` at the moment the wheel hits
3. repeat 10+ times across the same physical pothole

Acceptance:

- resulting points cluster within the backend merge radius instead of creating multiple nearby phantom potholes
- the buffered `tapTimestamp - 0.75s` locator outperforms naive `latestSample` in replay analysis
- accidental double-taps inside the cooldown window do not create duplicate uploaded actions

### Pothole Resolution Workflow Test (post-MVP)

1. create or locate an active pothole marker
2. submit one `Looks fixed` update
3. verify the marker stays active
4. submit a second `Looks fixed` update from a second device
5. verify the marker becomes `resolved`
6. later submit `Still there` or a new manual pothole report at the same location

Acceptance:

- one negative confirmation is insufficient to resolve the pothole
- two independent negative confirmations resolve it
- a later positive confirmation re-activates the same pothole cluster instead of creating a new one nearby

### Photo Upload Resume Test (post-MVP)

1. capture a photo with a fresh `< 5 km/h` speed sample
2. allow metadata POST to succeed
3. background the app before PUT finishes or force the PUT to time out
4. relaunch with connectivity

Acceptance:

- the same `report_id` is reused
- the client re-POSTs metadata instead of reusing an expired signed URL
- local JPEG is retained until PUT succeeds, then deleted immediately
- no duplicate `pothole_photos` rows are created

### Tunnel / GPS Dropout Test

Drive through the MacKay / Macdonald bridges and A. Murray MacKay Bridge tunnel (if any). Verify:
- No crashes
- Readings resume within 5s of GPS signal return
- No bogus readings attributed to wrong segments during dropout

### System-Termination Restart Test

Simulate system termination / memory pressure mid-drive without user swipe-killing the app. Wait for movement to resume. Verify `significantLocationChange` relaunches collection. Do **not** use user force-quit as the acceptance test; iOS suppresses background relaunch after that gesture.

## Accessibility Testing

Not an afterthought. Included in week 5's polish pass.

- VoiceOver: every interactive element has a descriptive label; map has a "Roads list" accessibility alternative
- Dynamic Type: tested at largest sizes via deterministic simulator/UI-test override (`ROAD_SENSE_DYNAMIC_TYPE_SIZE=accessibility5`) across onboarding, stats, and settings flows
- Color contrast: WCAG AA minimum for all text and map overlays (check against both light and dark base maps)
- Reduce Motion respected: `@Environment(\.accessibilityReduceMotion)` disables the subtle score-update animations

## UX / Design QA

Functional correctness is not enough. Before external TestFlight, run one explicit UX pass with 3-5 people who were not involved in implementation.

Success criteria:

- A first-time user can explain what the app does within 30 seconds of opening it
- A first-time user can tell whether the app is currently recording within 5 seconds of seeing the map
- A tester can identify what green/yellow/orange/red mean without guessing
- A tester can find pause collection immediately and optional privacy controls without assistance
- A tester understands the difference between their local drives and community data
- A tester can tap a road and explain confidence / last updated in plain English after reading the sheet

Watch for these design failures specifically:

- too much chrome obscuring the map
- stats that feel like internal metrics instead of user value
- error states that sound like logs instead of guidance
- privacy explanations that read like legal disclaimers instead of user help
- dashboard-style clutter creeping into the phone UI

## Internationalization

MVP ships English only. But:

- All user-facing strings in `Localizable.strings`, not inline
- Date/time formatted via locale-aware formatters
- Number formatting (km, kph, %) locale-aware

Saves pain when French Canadian localization comes in Phase 2.

## Performance Benchmarks

Automated benchmarks that gate PRs:

### iOS

- Cold launch → map visible: < 1.5s on iPhone 12 Pro (simulator or real device CI)
- SwiftData query: "last 1000 ReadingRecords" < 50ms
- Map pan/zoom: 60fps sustained (XCTest `measure` with `XCTClockMetric`)

### Backend

- `ingest_reading_batch` with 1000 readings, warm Edge Function: p95 < 4s measured against staging. With a pre-warmed function the realistic target is 2–3s; cold starts on Deno Deploy add 200–500ms. Don't set a tighter gate without empirical data.
- `get_tile` at zoom 14: p95 < 200ms
- `GET /segments/{id}`: p95 < 50ms

Anything exceeding these by > 20% blocks merge.

## Load Testing (pre-launch, week 7)

k6 script simulating:

- 50 concurrent users uploading 10 batches/hour
- 500 concurrent users fetching tiles (varied z/x/y)
- Sustained for 30 minutes

**Run against staging.** Watch Supabase CPU, DB connection pool saturation, Edge Function latency. Confirm we can handle 10× MVP scale comfortably.

### Nightly Recompute Load Test

`nightly_recompute_aggregates` is the riskiest scheduled job — it scans up to 6 months of `readings` for every active segment and does per-segment percentile math. If it doesn't finish in the 03:15–04:15 UTC window, it will collide with the next run.

Protocol (run in week 7, rerun any month that row counts grow > 2×):

1. Populate staging with synthetic data at **MVP-realistic scale**: 400k segments, ~2.6M readings over 6 months (10 drivers × 500 km/week × ~20 readings/km × ~26 weeks = 2.6M). This matches spec 02's "~5M / year" steady-state figure. Load-test with 2× headroom (5M rows) to cover organic growth through Month 9.
2. Run the function cold (no cache) on Supabase Small: target < 10 min
3. Run again warm: target < 5 min
4. Check peak DB CPU < 80%, peak memory < 70% of instance
5. Budget breaker: if cold time > 15 min on Small OR the MVP grows past 25 active drivers, escalate to Medium and switch to incremental recompute. Do not run the nightly recompute on Small past 10M rows — work_mem spills will compound.

## Bug Triage & Severity

Per product-spec, we open GitHub issues for TestFlight bugs. Apply these severity labels:

- **P0 (crash / data loss)** — hotfix within 24h
- **P1 (major feature broken)** — fix in next TestFlight build (weekly)
- **P2 (minor / polish)** — fix within a sprint
- **P3 (nice-to-have)** — backlog

Every bug gets a repro condition. If a bug can't be reproduced in the simulator harness, capture a sensor CSV from the reporting device.

**Sensor-CSV upload flow (do not email):** sensor logs can contain unmasked GPS traces — emailing them to a personal Gmail address would route raw location data through an inbox with no retention controls, which is a PIPEDA exposure. Instead:

1. Dev toggle shows an explicit consent dialog: *"This will upload a 60s sensor trace including GPS coordinates for debugging. Only team members can access it. Retained 14 days."*
2. On consent, upload to a private Supabase Storage bucket `support-captures/` keyed by `device_hash/timestamp.csv`. RLS: `service_role` only.
3. Retention policy on the bucket: delete after 14 days via scheduled job.
4. Never enable this toggle in non-debug builds. Guard with `#if DEBUG`.

## Definition of Done for a PR

Every PR must pass:

- [ ] `xcodebuild test` clean (iOS)
- [ ] `supabase test db` clean (backend)
- [ ] Simulator harness passes all golden fixtures (iOS)
- [ ] No new warnings (`-warnings-as-errors` in CI)
- [ ] Coverage not decreased > 2%
- [ ] Migration (if any) is idempotent and has a rollback plan documented in PR body
- [ ] New user-facing strings are localized
- [ ] If touching sensor code: a field-test checklist item is called out in PR body

## Testing Policy Decisions

- **No SwiftUI snapshot tests in MVP.** They are brittle relative to the value they add here. Prefer functional UI coverage, accessibility checks, and targeted manual visual review.
- **Keep the 80% line-coverage bar for `Pipeline/`, `Sensors/`, `Privacy/`, and `Network/`.** The exact number is imperfect, but lowering it would undercut confidence in the core math and lifecycle logic.
