# 04 — Testing & Quality

*Last updated: 2026-04-17*

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

**What gets unit-tested (non-exhaustive):**

| Module | Coverage |
|---|---|
| `RoughnessScorer` | Deterministic scoring of canned signals (synthetic sine, step, real CSV clip). Asserts RMS within ±0.02g of expected. |
| `PotholeDetector` | Synthetic dip-then-spike, synthetic braking (should NOT trigger), real pothole CSV (should trigger). |
| `PrivacyZoneFilter` | Point in zone, point at boundary, point outside, multiple overlapping zones. |
| `QualityFilter` | Speed, GPS accuracy, thermal state combinations — truth table. |
| `ReadingBuilder` | Window closes at 50m, window aborts at > 15s, window discards at thermal.serious. |
| `Uploader` | Retry backoff scheduling (inject clock), idempotency (same batch_id on retry), 429 respects Retry-After, batch_size cap. |
| `PrivacyZone` | Offset creation is randomized + deterministic-given-seed, never persists un-offset coords. Statistical test: 1000 offsets for the same zone have std. dev. ≥ 60m in both lat and lng (proves the randomization isn't collapsed). |
| `DeviceToken` | Rotation on month boundary, persistence across launches. |
| `PermissionManager` | Each permission state → correct UI directive. |

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
| `ingest_reading_batch` | Happy path, duplicate batch returns same result, batch with no matches, batch with out-of-bounds readings. |
| Map-matching KNN query | Known point on known segment → correct segment_id. Known point between parallel roads → correct disambiguation by heading. |
| `update_segment_aggregates_from_batch` | Weighted average math, confidence tier thresholds, category boundaries. |
| `nightly_recompute_aggregates` | Outlier trimming correctness, recency weighting, trend detection (improving/worsening/stable). |
| `fold_pothole_candidates` | New pothole, confirmation of existing, too-far-away creates new. |
| `expire_unconfirmed_potholes` | 90-day threshold, idempotent. |
| Partition management | Next-month partition auto-created, old partition dropped. |
| Rate limits | Per-device and per-IP counters increment; window slides correctly. |

**Avoid:** Testing via anon-key only — some tests need service-role; mark those clearly.

### Edge Functions

Tests live in `supabase/functions/<fn>/test.ts`. Use Deno's built-in `Deno.test` + `supabase start` for a local stack.

- Contract tests per endpoint: valid payload → 200, each validation error path → 400 with exact field_errors
- Rate limit test: 51st request in 24h → 429 with Retry-After

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

Each fixture has an accompanying `.expected.json` with the assertion targets:

```json
{
    "fixture": "pothole-hit.csv",
    "expected_windows": 1,
    "expected_pothole_flagged": true,
    "expected_rms_range": [0.6, 1.2],
    "expected_max_spike_g_range": [2.5, 4.0]
}
```

CI runs the harness against every fixture on every PR.

## Integration Tests

### iOS → Staging backend

Per-PR on merge to main: a "staging smoke" job runs the simulator harness end-to-end with uploads pointed at staging Supabase.

- Upload → 200
- Query `segment_aggregates` for the segment → new reading_count matches
- Query tile endpoint → MVT contains the segment

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

### Tunnel / GPS Dropout Test

Drive through the MacKay / Macdonald bridges and A. Murray MacKay Bridge tunnel (if any). Verify:
- No crashes
- Readings resume within 5s of GPS signal return
- No bogus readings attributed to wrong segments during dropout

### Cold Restart Test

Force-quit app mid-drive. Wait 2 minutes. Verify `significantLocationChange` triggered relaunch and collection resumed.

## Accessibility Testing

Not an afterthought. Included in week 5's polish pass.

- VoiceOver: every interactive element has a descriptive label; map has a "Roads list" accessibility alternative
- Dynamic Type: tested at largest sizes in `Environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)`
- Color contrast: WCAG AA minimum for all text and map overlays (check against both light and dark base maps)
- Reduce Motion respected: `@Environment(\.accessibilityReduceMotion)` disables the subtle score-update animations

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

## Open Questions

- **[OPEN] Do we need SwiftUI snapshot tests for the one or two critical screens?** Probably not at MVP. Revisit if we're getting visual regressions.
- **[OPEN] Is 80% coverage the right bar for Pipeline/?** It's what we pick. Could go higher; lower feels irresponsible given the math is core.
