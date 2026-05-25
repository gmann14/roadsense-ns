# 15 — Reading-rejection Diagnostics Plan

*Last updated: 2026-05-07 (Phase A landed)*

Plan for making it visible — to us and to the tester — *why* a drive produced fewer accepted reading windows than the user expected. Triggered by 2026-05-07 field report: tester drove three trips totalling well above 0.6 km, Stats showed `Trips recorded: 3`, `Road readings saved: 13`, `Privacy-filtered: 0`, `Trips waiting to upload: 0`. Permissions and Low Power were correct. We currently have no way to tell which gate dropped the missing windows.

Lives alongside [01-ios-implementation.md](01-ios-implementation.md) (sensor pipeline) and [04-testing-and-quality.md](04-testing-and-quality.md) (testing). When this ships, the relevant backlog rows ([08-implementation-backlog.md](08-implementation-backlog.md) B099 and the field-test pack [09-internal-field-test-pack.md](09-internal-field-test-pack.md)) should reference it.

## The visibility gap, exactly

The pipeline rejects, resets, or ignores samples/windows in five places. Today, only **two** of them produce log lines, and **none** persist a diagnostic counter for non-privacy reading loss:

| # | Stage | File / line | Rejection reasons | Currently logged? | Currently counted? |
|---|---|---|---|---|---|
| 1 | `SensorCoordinator.handleLocationSample` `isCollecting` gate | `ios/RoadSenseNS/Pipeline/SensorCoordinator.swift` | `DrivingDetector` says not driving, monitoring paused, app not yet primed | no | no (only `lastDrivingEventAt` exists) |
| 2 | `PrivacyZoneFilter.shouldDrop` | `SensorCoordinator.swift` | location sample inside a configured zone | no OS log; persisted as `droppedByPrivacyZone = true` | yes — `privacyFilteredCount` in Stats |
| 3 | `ReadingBuilder.addLocationSample` early-out (silent reset) | `ios/Sources/RoadSenseNSBootstrap/Pipeline/ReadingBuilder.swift` | GPS accuracy > 20 m, duration > 15 s, heading variance > 60°, < 30 motion samples after 40 m | **no** (returns `nil`) | no |
| 4 | `QualityFilter.evaluate` via `SensorCoordinator` | `ios/Sources/RoadSenseNSBootstrap/Pipeline/QualityFilter.swift` / `SensorCoordinator.swift` | gpsAccuracy / speed / sampleCount / duration / thermal | yes (one `logger.info` line, OS-level only) | no |
| 5 | `ReadingStore.saveAccepted` failure | `ios/RoadSenseNS/Persistence/ReadingStore.swift:373` | SwiftData error | yes (one `logger.error`) | no |

Stage 3 is the structurally invisible one and is the prime suspect for Malcolm's drive: `ReadingBuilder` resets silently every time motion delivery is too sparse to hit 30 samples per ~40 m window. There is no way today to tell that apart from "the road was smooth and uninteresting."

## Stress-test findings baked into this plan

- **Do not mix units without naming them.** Privacy filtering is counted per location sample; `ReadingBuilder` and `QualityFilter` failures are counted per candidate reading window. The UI can group them, but the storage shape must preserve the raw reason counts so we do not add "34 privacy samples" to "6 reading windows" and call the total precise.
- **Do not count every `isCollecting == false` GPS sample as a rejected reading.** Before `ensureCurrentDriveSession(for:)` runs, there is no drive session to attach to, and idle monitoring could generate noisy lifetime counts. Track pre-collection samples separately as collection diagnostics, not as reading rejections.
- **`builderTravelDistance` cannot increment from normal `.inProgress`.** Short travel is only diagnosable when a collection/session is sealed with a non-empty partial window below 40 m, or when a reset happens before the target. Add an explicit partial-window finalization path instead of counting every in-progress sample.
- **Keep OS logs while adding counters.** The `logger.info("reading window rejected...")` line is still useful when attached to Xcode; the recorder supplements it.
- **Batch persistence.** Writing SwiftData on every rejected location sample would move work onto the hot path. Increment in memory and flush on existing checkpoint/session-seal/app-lifecycle boundaries.
- **Schema migration is real work.** Adding blobs to `UserStats` and `DriveSessionRecord` means a new `RoadSenseSchemaV6`, lightweight migration coverage, and script updates for the SQLite column names SwiftData generates.
- **"Last drive" must follow existing trip grouping.** `UserStatsStore` merges drive sessions separated by <= 60 seconds. The diagnostics card and Stats breakdown should aggregate the same grouped trip, or testers will see mismatched "3 trips" and "last drive" numbers.

## Goals

1. **For us:** be able to look at a tester's device after a confusing drive and say, with numbers, *which* gate dropped the missing windows.
2. **For the tester:** see something more useful than "13 readings saved" so they don't have to message us to find out whether their phone is broken or this is normal.
3. **No new automatic privacy surface.** Counters and reasons only — no extra raw GPS, accelerometer, or per-sample log lines leaving the device by default. Phase B adds an explicit user-initiated diagnostics export.

## Non-goals

- Real-time HUD during driving. The screen is off / the phone is mounted. This is a post-drive diagnostic.
- Any change to `QualityFilter` thresholds. We're instrumenting the existing thresholds, not relaxing them.
- Server-side ingestion of rejection counters. Stays on-device for now; we can promote later if it proves useful.
- Replacing the existing `Drive diagnostics` card. This extends it.

## Design

### Layer 1 — Typed rejection counters (where the work actually goes)

Introduce a single `ReadingRejectionRecorder` owned by `SensorCoordinator`. It records **diagnostic events**, not all events with the same unit. Each event has a reason and a unit:

- `.readingWindow` — a candidate reading window was reset, rejected, or failed to persist.
- `.locationSample` — a location sample was intentionally not used because it was inside a privacy zone.
- `.collectionSample` — a pre-collection GPS sample explained why collection was not yet active; this is not shown as a skipped reading.

Every silent reset path in `ReadingBuilder` and every `QualityFilter` rejection reports through it:

```swift
enum ReadingDiagnosticReason: String, Codable {
    case collectionNotActive     // collection diagnostic only; not a skipped reading
    case privacyZone             // locationSample unit; already counted by ReadingRecord rows
    case builderGpsAccuracy      // readingWindow unit
    case builderDuration         // readingWindow unit
    case builderHeadingVariance  // readingWindow unit
    case builderSampleCount      // readingWindow unit
    case builderPartialAtSeal    // readingWindow unit; non-empty window abandoned when collection stops
    case qualityGpsAccuracy
    case qualitySpeed
    case qualitySampleCount
    case qualityDuration
    case qualityThermal
    case persistFailure
}

enum ReadingDiagnosticUnit: String, Codable {
    case readingWindow
    case locationSample
    case collectionSample
}
```

Required behaviour:

- `ReadingBuilder.addLocationSample` becomes non-silent: instead of `return nil` after a reset, it returns a small `ReadingBuilderOutcome` enum (`.window(ReadingWindow)`, `.inProgress`, `.reset(reason)`). `SensorCoordinator` records the reset reason. `.inProgress` is uncounted because it is normal accumulation.
- `ReadingBuilder` exposes a cheap `partialWindowDiagnostic()` or equivalent snapshot helper used when `SensorCoordinator` seals/stops collection. If the builder has a non-empty partial window below 40 m, record `builderPartialAtSeal` once with current `travelMeters`, `durationSeconds`, and `motionSamplesAvailable`.
- `QualityFilterDecision.rejected(reason)` already exists. `SensorCoordinator` records it and keeps the current `logger.info` line.
- The recorder maintains:
  - **Lifetime totals** per reason/unit (Codable JSON `String` or `Data` blob on `UserStats`; additive, never reset).
  - **Per-session totals** on `DriveSessionRecord` as the same Codable blob.
  - **Last grouped-trip totals** derived from the same <= 60 s grouping that `UserStatsStore.totalTripsRecorded` uses, so Stats and Drive diagnostics agree.
- Counter increments must be cheap: mutate in-memory dictionaries/arrays only. Flush to SwiftData on existing checkpoints, session seal, app background, and explicit export. Same `@MainActor` confinement as `SensorCoordinator`.
- Persist privacy-zone samples in the recorder only as a mirror of the existing `ReadingRecord.droppedByPrivacyZone` count. Do not make this a second source of truth for privacy-filtered totals.

### Layer 2 — Bounded ring buffer of recent rejections (opt-in, privacy-aware)

Add an in-memory ring buffer of the last 200 diagnostic events. Each entry: timestamp, reason, unit, drive/session ID when one already exists, and only the **already-derived** numeric context the stage was looking at (e.g. `gpsAccuracyMeters`, `speedKmh`, `motionSamplesAvailable`, `headingVarianceDegrees`, `travelMeters`). **No raw lat/lng, no raw accelerometer values.**

The ring buffer is a runtime aid for export. It is reset on app launch and never persisted to SwiftData. Phase B may write a user-initiated export JSON file under app `Caches/Diagnostics/` so `ShareLink` and `pull-device-store.sh` have a real file to handle; that file is not automatic telemetry and should be overwritten or cleaned up on the next export.

### Layer 3 — Surface

Three places. In order of value:

1. **Stats → "Why readings were skipped"** (one new section, last grouped-trip scope only).

   Replace the current single `Privacy-filtered` row with a small breakdown that is honest about the structural undercount and explicit about units:

   ```
   Last drive · May 7, 2026 at 07:51
     Road readings saved                13
     Reading windows skipped            60
     Location samples privacy-filtered   0
     Slow / stop-and-go                 34
     GPS accuracy lost                  11
     Sensor data sparse                  6
     Heading changed                     9
     Too hot to record                   0
   ```

   Copy is friendly. No "rejected", no "QualityFilter". Each row maps to one or more `ReadingDiagnosticReason` values, grouped: `slow / stop-and-go` = `qualitySpeed`; `GPS accuracy lost` = `builderGpsAccuracy + qualityGpsAccuracy`; `sensor data sparse` = `builderSampleCount + qualitySampleCount`; `heading changed` = `builderHeadingVariance`; `too hot` = `qualityThermal`; `incomplete at stop` = `builderPartialAtSeal`.

   Order matters. Show non-zero rows first; collapse zero rows under a `Show all` disclosure to keep the success case quiet. Do not show `collectionNotActive` in this section; it belongs in Settings diagnostics because it explains why collection did not start, not why an active drive produced fewer windows.

2. **Settings → Drive diagnostics → existing card** (gains two rows + an action).

   - `Last drive readings skipped` (sum of `readingWindow` events, last grouped trip only)
   - `Lifetime readings skipped` (sum of `readingWindow` events, install-lifetime)
   - `Pre-collection GPS samples ignored` (collection diagnostics, last app run; useful when bootstrap never starts)
   - **`Share diagnostics`** action: produces a structured JSON file containing
     - lifetime totals
     - last grouped-trip totals
     - the in-memory ring buffer
     - the device's current permission snapshot, thermal state, low-power status
     - app version, OS version, model identifier (no IDFA, no device-token-hash, no advertising ID)
     - explicitly *not*: any GPS coordinates, any motion sample values, anything from `ReadingRecord`.
     The action writes the JSON to `Caches/Diagnostics/roadsense-diagnostics-<yyyy-MM-dd-HHmmss>.json` and uses standard `ShareLink` so the tester can AirDrop or message it back to us.

3. **`DrivesListView` per-trip detail (optional polish, ship after 1+2).**

   Each trip row in `Recent drives` already shows distance + privacy-zone count. Add a single trailing summary `12 saved · 47 skipped` where `skipped` means reading-window skips only, with a tap-through to the same breakdown structure. Useful when a tester says "this *one* trip was weird" rather than "the whole morning."

### Layer 4 — Tooling

- Update `scripts/pull-device-store.sh` to also include `Caches/Diagnostics/*.json` if present. (Right now it grabs `Library/Application Support`; this needs an additional app-container copy path.)
- Update `scripts/local-ios-quality-report.sh` to print the rejection-totals breakdown alongside the existing report so a `pull-device-store.sh` → `local-ios-quality-report.sh` loop now answers the rejection question end-to-end. The script must tolerate old stores that do not have the new SwiftData columns yet.
- No backend changes. No new endpoint.

## Phasing

Each phase ships independently and is useful on its own.

### Phase A — Counters and last grouped-trip Stats row (highest leverage, smallest blast radius)

- **Spec refs:** [01](01-ios-implementation.md), [04](04-testing-and-quality.md)
- **RED**
  - `ReadingBuilderTests`: every silent reset path (`gpsAccuracy`, `duration`, `headingVariance`, `sampleCount`) now produces a typed `.reset(reason)` outcome. Existing acceptance fixtures still produce `.window(...)`; ordinary short travel still produces `.inProgress`.
  - `ReadingBuilderTests`: a non-empty partial builder snapshot below 40 m reports `builderPartialAtSeal` only when finalised/sealed, not on every location sample.
  - `QualityFilterTests`: unchanged for threshold truth table, plus one mapping test from `QualityRejectionReason` to `ReadingDiagnosticReason`.
  - `SensorCoordinatorTests` / existing coordinator coverage in `NetworkAndUploaderTests`: feeding a fixture that should reject for `qualitySpeed` increments only `qualitySpeed`; for `builderSampleCount` increments only `builderSampleCount`; ten mixed inputs sum correctly across lifetime and per-session counters without a SwiftData save per event.
  - `UserStatsStoreTests`: `summary()` now includes last grouped-trip diagnostic totals; lifetime persistence round-trips through SwiftData.
  - `ModelMigrationTests`: v5 stores migrate to the new schema with empty diagnostic blobs and existing readings/sessions intact.
  - `SensorFixtureRunner` tests: harness output still reports accepted/rejected counts after `ReadingBuilderOutcome` replaces the optional return.
- **GREEN**
  - introduce `ReadingBuilderOutcome` enum (drop the `nil` return)
  - introduce `ReadingRejectionRecorder` and route `SensorCoordinator` through it while preserving current OS logs
  - add `ReadingBuilder` partial-window finalization helper for session seal/stop
  - persist lifetime totals on `UserStats` as a single Codable blob (no schema explosion)
  - persist per-session totals on `DriveSessionRecord` as a Codable blob
  - add `RoadSenseSchemaV6` and a lightweight migration from v5
  - extend `UserStatsSummary` with grouped-trip diagnostic totals
  - extend Stats hero/card area with the breakdown section described above; copy is friendly, not technical
- **Acceptance**
  - on a deliberately bad drive (phone in pocket, lots of < 15 km/h driving, intentional GPS-poor parking-garage start), the breakdown explains where the readings went
  - on a clean highway drive the breakdown is mostly zeros and collapsed under `Show all`
  - a drive that stops before 40 m shows one incomplete-window diagnostic, not dozens of skipped readings

### Phase B — Ring buffer + share diagnostics action

- **Spec refs:** [01](01-ios-implementation.md), [06](06-security-and-privacy.md)
- **Depends on:** Phase A
- **RED**
  - unit test asserts the ring buffer is bounded at 200 and never retains raw GPS coords or accelerometer values
  - export-format snapshot test pins the JSON shape so `local-ios-quality-report.sh` can rely on it
  - export test asserts no data is copied from `ReadingRecord` and no device-token hash or advertising identifier is present
  - privacy review checklist (in PR description, not a doc): each field in the export is justified or removed
- **GREEN**
  - in-memory ring buffer in `ReadingRejectionRecorder`
  - `DiagnosticsExportBuilder` produces the JSON file under `Caches/Diagnostics/`
  - `Share diagnostics` `ShareLink` in the existing diagnostics card
  - update `pull-device-store.sh` to grab the file if present
  - update `local-ios-quality-report.sh` to parse either the SwiftData blobs or the exported JSON, while still working on older stores
- **Acceptance**
  - tester can AirDrop a diagnostics file in two taps from Settings
  - the file contains zero values from `ReadingRecord` and zero raw motion/location data
  - file name and contents are stable enough that `local-ios-quality-report.sh` can parse them deterministically

### Phase C — Per-trip breakdown in Drives list

- **Spec refs:** [01](01-ios-implementation.md)
- **Depends on:** Phase A (per-session counters already on `DriveSessionRecord`)
- **RED**
  - `DriveSummary` / view-model test exposes the trailing `saved / skipped` summary using reading-window skips only
  - tap-through view/model test renders the same breakdown rows used in Stats
- **GREEN**
  - add the trailing summary and tap-through breakdown
- **Acceptance**
  - tester can pinpoint *which* of three morning trips was the bad one without having to recreate the drive

## What the next field-test report should look like

After Phase A, when a tester says "I drove 20 km and it shows 0.6 km", the answer process collapses to:

1. Ask them to open Stats and read the breakdown, or share a diagnostics file (after Phase B).
2. We can immediately distinguish between
   - **structural undercount** (mostly `slow / stop-and-go` rows non-zero — known limitation, not a bug)
   - **GPS issue** (`GPS accuracy lost` dominant — phone, weather, or location-mode issue)
   - **sensor-data starvation** (`sensor data sparse` dominant — Core Motion delivery throttled, app suspension, or a bug in how we hold the motion stream open)
   - **heading-variance churn** (`heading changed` dominant — unusual; suggests city blocks shorter than the 40 m window target on Malcolm's specific route geometry)
   - **partial-drive churn** (`incomplete at stop` dominant — collection stopped before enough distance accumulated for one or more windows)
   - **bootstrap issue** (Settings shows many pre-collection GPS samples ignored, but reading-window skips are low — collection did not start or resume reliably)
   - **real bug** (counters all near zero but `Road readings saved` is also tiny — that's when we panic and look at SwiftData state directly)

Without this work, every report of the same shape requires a full investigation cycle. With it, we can answer most cases from the screenshot alone.

## Out of scope (and why)

- **Server-side rejection telemetry.** Until the on-device picture is clear, sending counters to the backend just moves the same blindness to a different surface. Promote later if Phase A reveals a class of rejection that needs backend correlation.
- **Raw per-sample logs leaving the device.** Counters are sufficient signal at the pipeline-stage granularity; raw streams would require new privacy review.
- **Treating pre-collection samples as skipped readings.** They are useful bootstrap diagnostics, but they do not represent windows that would have been saved.
- **Adjusting `minimumSampleCount`, the 40 m target, or the 15 km/h floor.** Those are scoring/quality decisions tied to roughness validity. Diagnose first; tune (if at all) under a separate task that owns the calibration question.
- **A first-class "explain my drive" tutorial UX.** The breakdown rows are the explanation; we'll iterate on copy if Phase A surfaces confusion. Don't over-design before we have one round of real feedback.

## Backlog reference

When this plan ships its phases, mirror them in [08-implementation-backlog.md](08-implementation-backlog.md) as `B100x` field-discovery tasks (not numbered yet — pick on commit). The plan itself stays here and gets a `Last updated` bump per phase.
