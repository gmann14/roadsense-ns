# 01 — iOS Implementation

*Last updated: 2026-04-18*

Covers: Xcode project layout, sensor pipeline, scoring, persistence, upload queue, map/UI, background execution, and permissions.

Prereqs from [product-spec.md](../product-spec.md) that we don't re-derive here: driving detection via `CMMotionActivityManager`, 50Hz accel, 1Hz GPS, 50m segments server-side, 500m privacy zones.

## Deployment Target & Tooling

- **Minimum iOS:** 17.0 — keeps SwiftData simple, covers 95%+ of active iPhones by TestFlight date. Drop to 16 only if a tester hits this.
- **Language/toolchain:** Swift 5.9+, Xcode 15.3+, SwiftUI primary, UIKit where needed for Mapbox bridging
- **Package management:** Swift Package Manager only (no CocoaPods, no Carthage)
- **Bundle ID:** `ca.roadsense.ios`
- **Architectures:** `arm64` device only; simulator support for development. No `x86_64` — Rosetta-only dev machines must run Xcode 15 natively.

## Xcode Project Layout

```
RoadSenseNS/
├── RoadSenseNS.xcodeproj
├── RoadSenseNS/                       # app target
│   ├── App/
│   │   ├── RoadSenseNSApp.swift       # @main, DI wiring
│   │   ├── AppBootstrap.swift         # loads build settings from Info.plist
│   │   ├── AppContainer.swift         # root dependency graph
│   │   └── AppModel.swift             # launch/onboarding shell state
│   │   ├── BackgroundTaskRegistrar.swift
│   │   ├── RoadSenseLogger.swift
│   │   └── SentryBootstrapper.swift
│   ├── Features/
│   │   ├── Onboarding/                # views + permission/privacy shell
│   │   ├── Map/                       # MapboxMapView wrapper, overlays
│   │   ├── SegmentDetail/
│   │   ├── Settings/                  # collection/privacy/data management
│   │   ├── PrivacyZones/              # map-backed zone editor + saved-zone list
│   │   └── Stats/                     # personal contribution summary
│   ├── Sensors/
│   │   ├── DrivingDetector.swift      # CMMotionActivityManager wrapper
│   │   ├── LocationService.swift      # CLLocationManager wrapper
│   │   ├── MotionService.swift        # CMDeviceMotion wrapper
│   │   ├── ThermalMonitor.swift       # ProcessInfo.thermalState
│   │   └── PermissionManager.swift    # centralizes all permission prompts
│   ├── Pipeline/
│   │   ├── SensorCoordinator.swift    # orchestrates driving lifecycle
│   │   ├── ReadingBuilder.swift       # assembles 50m-of-travel windows
│   │   ├── ReadingWindowProcessor.swift
│   │   ├── RoughnessScorer.swift      # signal processing → rms
│   │   ├── PotholeDetector.swift      # spike detection
│   │   ├── PrivacyZoneFilter.swift    # on-device reading drop
│   │   └── QualityFilter.swift        # speed/accuracy gates
│   ├── Persistence/
│   │   ├── ModelContainerProvider.swift
│   │   ├── ReadingStore.swift
│   │   ├── SensorCheckpointStore.swift
│   │   ├── PrivacyZoneStore.swift
│   │   ├── UploadQueueStore.swift
│   │   └── UserStatsStore.swift
│   │   ├── Models/                    # @Model types
│   │   │   ├── ReadingRecord.swift
│   │   │   ├── UploadBatch.swift
│   │   │   ├── PrivacyZone.swift
│   │   │   ├── UserStats.swift
│   │   │   └── DeviceTokenRecord.swift
│   │   └── Migrations/                # SchemaV1, V2, etc.
│   ├── Network/
│   │   ├── APIClient.swift            # typed wrapper over URLSession
│   │   ├── Endpoints.swift
│   │   ├── DTOs/                      # Codable request/response types
│   │   └── Uploader.swift             # queue drain + retry
│   ├── Map/
│   │   ├── MapboxTileSource.swift     # MVT config
│   │   ├── RoadQualityStyle.swift     # line-layer data-driven styling
│   │   ├── LocalOverlayBuilder.swift  # SwiftData → GeoJSON for "your drives"
│   │   └── OfflinePackManager.swift
│   ├── Privacy/
│   │   ├── DeviceToken.swift          # monthly rotation
│   │   └── PIPEDAConsent.swift
│   └── Utilities/
│       ├── Logger.swift               # os.Logger wrapper w/ subsystem
│       ├── Clock.swift                # injectable time source (testability)
│       └── Geometry.swift             # haversine, bearing helpers
├── RoadSenseNSTests/                  # unit tests
├── RoadSenseNSUITests/                # minimal, smoke-only
└── RoadSenseNSSimHarness/             # separate target — playback of CSV
```

**Rationale for the split:**
- `Sensors/` are dumb wrappers around Apple APIs with injectable delegates — they don't know about scoring
- `Pipeline/` owns the math and the assembly of readings — testable in isolation with replayed CSVs
- `Persistence/`, `Network/`, `Map/` are infrastructure — each has a protocol in front of it so tests can stub

### Bootstrap Phase Note

Before the full Xcode project is generated, keep the environment/config seam buildable as a plain Swift package under `ios/`. That bootstrap package is allowed to implement:

- `AppEnvironment`
- `AppConfig`
- `CollectionReadiness`
- `DeviceTokenManager`
- `DrivingHeuristic`
- `HighPassBiquad`
- `IngestHealthEvaluator`
- `MotionMath`
- `MotionSample`
- `MotionVector3`
- `LocationSample`
- `PotholeDetector`
- `PrivacyZone`
- `PrivacyZoneFilter`
- `ReadingBuilder`
- `ReadingWindowProcessor`
- `PersistedReadingCandidate`
- `SensorCheckpoint`
- `ReadingWindow`
- `RetentionPolicy`
- `QualityFilter`
- `BackgroundCollectionPolicy`
- `UploadEligibilityPolicy`
- `UploadReadingPayload`
- `UploadReadingsRequest`
- `UploadReadingsResponse`
- `UploadPolicy`
- `UploadRequestFactory`
- `UploadResponseParser`
- `UploadQueueCore`
- `PermissionSnapshot`
- `Endpoints`
- `RejectedReason`

Those types must stay Foundation-only so `swift test` can validate them without the full app target. Do not pull SwiftUI, Mapbox, or Core Location into the bootstrap package.

## Dependency Inversion / DI

No DI framework. Plain initializer injection with a top-level `AppContainer` struct constructed in `RoadSenseNSApp`.

```swift
// Sketch — final signatures in the repo
struct AppContainer {
    let locationService: LocationServicing
    let motionService: MotionServicing
    let drivingDetector: DrivingDetecting
    let persistence: Persisting
    let uploader: Uploading
    let api: APIClient
    let permissions: PermissionManaging
}
```

`Sensor*` / `Persist*` / `Uploading` are protocols; production types conform. Test container swaps in fakes. Keep DI boring.

### Launch Shell

The current app shell is intentionally thin but real:

- `AppBootstrap` reads `APP_ENV`, `API_BASE_URL`, `MAPBOX_ACCESS_TOKEN`, `SENTRY_DSN`, and `APP_GROUP_IDENTIFIER` from `Info.plist`
- `AppContainer` now also owns the SwiftData `ModelContainer`, `PrivacyZoneStore`, `UploadQueueStore`, `APIClient`, `Uploader`, sensor wrappers, logger, and background-task registrar seam
- `AppModel` owns the current `PermissionSnapshot`, derives `CollectionReadiness`, and reads actual zone existence from `PrivacyZoneStore` so optional privacy controls can be surfaced consistently from onboarding-ready, map, and settings states
- `ContentView` routes between onboarding and `MapScreen` using `CollectionReadiness.evaluate(...)`
- `PrivacyZonesView` is now a real app-target screen with a map-backed placement flow: the user pans the map to position the center reticle, adjusts the radius with a slider, and saves the resulting zone while reviewing existing saved footprints.

This keeps the permission/privacy gate testable in pure Swift while leaving the Core Location / Core Motion wiring in the app target where it belongs.

### Current Implemented App-Target Infrastructure

- `LocationService`, `MotionService`, `DrivingDetector`, and `ThermalMonitor` now exist as production wrappers around Apple APIs. They are not yet orchestrated into full collection, but the DI seam is now real instead of hypothetical.
- `ModelContainerProvider` creates the persistent SwiftData container for `ReadingRecord`, `UploadBatch`, `PrivacyZoneRecord`, `UserStats`, and `DeviceTokenRecord`.
- `ReadingStore` persists accepted readings, privacy-filtered local-only entries, and updates `UserStats`.
- `UploadQueueStore` persists batch assignment / success / failure state using `UploadQueueCore`.
- `APIClient` + `Uploader` now implement the first real app-side upload drain path against `POST /upload-readings`.
- `Endpoints`, `SegmentAPIModels`, `SegmentDetailResponseParser`, and `APIClient.fetchSegmentDetail(...)` now implement the typed `GET /segments/{id}` read seam, even though live tap-to-sheet wiring is still waiting on the actual map layer.
- `SensorCoordinator` now orchestrates the first real passive-collection loop: it listens to `DrivingDetector`, starts/stops `LocationService` + `MotionService`, applies `PrivacyZoneFilter`, runs `ReadingBuilder` and `ReadingWindowProcessor`, persists accepted readings through `ReadingStore`, and opportunistically drains uploads.
- `SensorCheckpointStore` now writes `SensorCheckpoint.json` in Application Support and restores it if it is newer than 30 minutes. The checkpoint includes the in-progress `ReadingBuilder` state, `PotholeDetector` history, recent pothole candidates, and latest location.
- `BackgroundTaskRegistrar` now registers both documented task identifiers: `ca.roadsense.ios.nightly-cleanup` and `ca.roadsense.ios.upload-drain`. `project.yml` emits `BGTaskSchedulerPermittedIdentifiers` to match them.
- `SentryBootstrapper` exists as a guarded seam: it becomes active when the Sentry package resolves, but remains a no-op while package resolution is still blocked.
- `MapScreen` now exists as a product-facing SwiftUI shell with a recording status pill, floating contribution card, stats/settings overlay buttons, and expandable road-quality legend.
- `RoadQualityMapView` now renders live Mapbox-backed road-quality vector tiles from the backend, shows pothole markers, draws a dashed teal overlay for locally collected unuploaded drives, and supports tap selection using feature-state highlighting.
- `SegmentDetailSheet` now exists as an editorial detail surface that matches the documented response shape and confidence/trend wording, and `MapScreen` now presents it from real segment taps via `GET /segments/{id}`.
- `PrivacyZonesView` now uses Mapbox as well: it renders saved privacy footprints and a live draft radius, lets the user place a zone by panning the map beneath a fixed reticle, and keeps delete/focus actions in the same surface.

### Current Ready-Shell Behavior

- The ready shell now shows:
  - recording / paused / needs-background-collection state
  - a floating contribution card with mapped distance, pending uploads, and one primary next action
  - overlay entrypoints for Stats and Settings
  - a collapsible road-quality legend
  - a dashed teal local-drive overlay whenever unuploaded, non-privacy-filtered readings exist locally
- The user can now:
  - open the map-backed privacy-zone editor from the home shell action or Settings
  - start passive monitoring when it is paused
  - request the Always-location upgrade when background collection is still unavailable
  - open Stats and Settings sheets
  - force an upload drain through the contribution card action when uploads are pending

This is now credible product UI with the first real live map loop in place. The app target also now has deterministic UI-test launch scenarios:

- `ROAD_SENSE_TEST_SCENARIO=default` starts in the permissions-first onboarding path
- `ROAD_SENSE_TEST_SCENARIO=ready-shell` seeds an in-memory ready state with one saved privacy zone, a few local readings, and user stats
- Under XCTest, the home shell uses a lightweight non-Mapbox testing surface so simulator UI tests validate our app flow rather than third-party map startup

Remaining product work is refinement: deeper retry/empty-state handling around the live map, richer selection-state/UI coverage, additional captured-drive fixtures beyond the current simulator corpus, and real-device validation.

### Local Map Truth During Field Tests

For internal field testing, the phone map has to be more truthful than the public aggregate tile layer:

- backend tiles show only successfully ingested, aggregate-backed public data
- the local overlay shows on-device readings that are not privacy-zone dropped, endpoint trimmed, or uploaded yet
- in-progress readings are allowed to appear locally before endpoint trimming has decided upload eligibility, because this is the tester's own device and is the only immediate "yes, it is recording" signal
- once a reading uploads successfully, it disappears from the local overlay and should become visible through backend tiles after aggregate/tile refresh
- if data was manually replayed into the backend, Diagnostics must label the phone queue as stale/pending rather than implying that the backend is missing it

The local overlay should use the same roughness category thresholds as the backend calibration function (`smooth < 0.05`, `fair < 0.09`, `rough < 0.14`, otherwise `very_rough`) so the tester sees the same roughness shape before and after upload.

### Current Stats / Settings Surfaces

- `StatsView` now shows:
  - kilometres driven
  - grouped trips recorded
  - accepted reading count
  - trips waiting to upload
  - privacy-filtered local count
  - potholes flagged
  - last drive timestamp
- `SettingsView` now exposes:
  - passive monitoring on/off
  - the "Enable background collection" action when the app is still in the `.upgradeRequired` state
  - privacy-zone management entrypoint
  - destructive delete-local-data control
  - plain-language privacy/trust copy
  - explicit modal close affordance for simulator/device usability and deterministic UI testing

`delete local data` currently clears locally stored readings, upload queue state, user stats, and device token rotation state. It intentionally does **not** remove privacy zones.

### Sensor Protocol Seam

Unit tests and the simulator harness cannot construct a real `CMDeviceMotion` (it's framework-internal). The protocol therefore publishes a plain value type, not the Apple class, so fakes can emit whatever they need to.

```swift
struct MotionSample {
    let timestamp: TimeInterval           // monotonic, from CMDeviceMotion.timestamp
    let userAcceleration: (x: Double, y: Double, z: Double)  // G
    let gravity: (x: Double, y: Double, z: Double)           // G, |g| = 1
}

protocol MotionService {
    func start(rate: Double) async throws
    func stop()
    var samples: AsyncStream<MotionSample> { get }
}

// Production type wraps CMMotionManager and maps CMDeviceMotion → MotionSample.
// Test/harness types can synthesize MotionSample from CSV replay without touching Core Motion.
```

Same pattern for `LocationService` (publishes a `LocationSample` DTO). The harness never subclasses framework classes.

## Sensor Pipeline

### Lifecycle

```
App launch
   ↓
PermissionManager bootstraps → requests When-In-Use + Motion
   ↓
DrivingDetector.start()  (CMMotionActivityManager, confidence ≥ .medium)
   ↓
On .automotive == true AND stationary == false:
   SensorCoordinator.startCollection()
      ↓
      LocationService.startUpdates(accuracy: .nearestTenMeters, distanceFilter: 5m)
      MotionService.startDeviceMotion(rate: 50Hz, reference: .xArbitraryZVertical)
      ↓
      ReadingBuilder window opens (resets on new segment start)
```

### Gravity-Compensated Vertical Acceleration

Critical detail: the phone could be in any orientation. We project the raw acceleration onto the gravity vector to get true "up-down" regardless of mount.

```swift
// Pseudocode — actual implementation in MotionService.swift
func verticalAcceleration(from motion: CMDeviceMotion) -> Double {
    let g = motion.gravity                    // magnitude normalized to 1 G, direction = down in device frame
    let a = motion.userAcceleration           // gravity already removed by Core Motion; units = G
    // Scalar projection of a onto gravity direction. Because |g| = 1 G,
    // this directly gives the component of user acceleration parallel to gravity (i.e., vertical in world frame).
    return a.x * g.x + a.y * g.y + a.z * g.z
}
```

**Why not raw `userAcceleration.z`?** Because z is the device's z-axis, not the world's vertical. A phone sideways on a car seat has its z-axis pointing horizontally. Projecting onto gravity is orientation-free.

**API detail:** `CMDeviceMotion.userAcceleration` already has gravity subtracted by Core Motion's sensor fusion. `CMDeviceMotion.gravity` has magnitude normalized to 1 G, so the dot product above is the scalar projection (no division by |g| needed). Start updates with `startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue)`; the reference frame only matters for magnetometer-backed attitude, not for this projection.

### High-Pass Filter

Butterworth 2nd-order, ~0.5Hz cutoff, implemented as a biquad IIR filter. Runs on the 50Hz stream before RMS.

```swift
// Pseudocode
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func apply(_ x: Double) -> Double {
        let y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
```

**Coefficients** computed once at init via the bilinear transform for `sample_rate = 50Hz`, `cutoff = 0.5Hz`, `Q = 1/√2` (Butterworth). Reference values (verify against a reference implementation; regenerate if sample rate changes for battery-saver mode):

```
ω = 2π · 0.5 / 50 = 0.0628
α = sin(ω) / (2Q) ≈ 0.0444
b0 = (1 + cos(ω)) / 2 ≈ 0.9990   (normalized by a0 below)
b1 = -(1 + cos(ω))    ≈ -1.9980
b2 = (1 + cos(ω)) / 2 ≈ 0.9990
a0 = 1 + α            ≈ 1.0444
a1 = -2·cos(ω)        ≈ -1.9961
a2 = 1 - α            ≈ 0.9556
```

Normalize by dividing `b0..b2, a1, a2` by `a0` before use. Unit-test the filter against a 0.1Hz sine (should attenuate ~40dB) and a 5Hz sine (should pass unchanged). Battery-saver mode recomputes for 25Hz.

### Reading Window Assembly

We don't upload 50Hz accel. We bucket into ~50m of travel and compute one RMS per bucket.

- Track cumulative haversine distance from the last "window start" location
- When cumulative ≥ 40m (undershoot — server segments are 50m; targeting 40m keeps 95%+ of midpoints unambiguous to one segment): close window
- Window output: `{lat, lng, roughness_rms, speed_kmh, heading, gps_accuracy_m, started_at, duration_s, sample_count, pothole_spike_count, pothole_max_g}`
- Location reported is the **midpoint** of the window (to reduce edge-of-segment ambiguity for the server matcher)
- `heading` averaged across GPS samples in the window, weighted by instantaneous speed

**Window abort conditions** — drop the window (do not emit) if any:
- Duration exceeds 15s (stopped at a light; stale data)
- No GPS update received in 3s while accel is still streaming (GPS dropout; coordinate uncertainty too high)
- `CLLocation.horizontalAccuracy > 20m` on any sample in the window
- Heading variance across samples > 60° (user turned mid-window; spans multiple segments)
- Fewer than 30 accel samples collected in the window (hardware hiccup)

On any abort, reset the window and continue with the next GPS fix as the new start point.

### Quality Gates (per reading, before store/upload)

Drop if any:

- `gps_accuracy_m > 20`
- `speed_kmh < 15` or `speed_kmh > 160`
- `sample_count < 30` (would be < 0.6s of accel — probably a glitch)
- `duration_s > 15`
- Any `ProcessInfo.thermalState` of `.serious` or `.critical` during the window → drop the window, stop collection
- `ProcessInfo.isLowPowerModeEnabled` does NOT drop readings — it switches us to reduced-sampling mode instead (see below)

### Pothole Spike Detection

Runs on the 50Hz filtered stream in parallel with RMS:

```swift
// Pseudocode
var history: RingBuffer<Double>   // last 50 samples (1s)
func ingest(_ sample: Double) {
    history.append(sample)
    if abs(sample) > 2.0 * G {    // raw threshold
        // look back for "dip" in prior 5 samples
        let minRecent = history.suffix(5).min()!
        if minRecent < -0.5 * G && sample > 2.0 * G {
            emit PotholeCandidate(
                location: currentLocation,
                magnitude: sample / G,
                at: clock.now
            )
        }
    }
}
```

`emit` tags the candidate onto the current `ReadingWindow`. The server decides whether enough users saw the same spot to confirm.

### Battery Saver Mode

Triggered by: `UIDevice.current.batteryLevel < 0.2` **or** `ProcessInfo.isLowPowerModeEnabled` == true **or** user manual toggle.

**Gotcha:** `UIDevice.current.batteryLevel` returns -1 unless `UIDevice.current.isBatteryMonitoringEnabled = true` has been set. Enable this at app launch in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` — once on, it's cheap.

- Accelerometer: 25Hz (halved)
- GPS: `distanceFilter = 10m`, effectively ~0.5Hz in city driving
- Skip readings on segments where `segment_aggregates.unique_contributors > 10` (fetched periodically; see "Adaptive Duty Cycling" below)
- Visible indicator in app header

### Adaptive Duty Cycling (post-M3, nice-to-have)

After aggregates exist, the app can periodically fetch a lightweight bitmap of "high-confidence segments covered" for the user's current bounding box and skip re-mapping those. **Deferred past M3** — don't build until we have real coverage to test against.

## Driving Detection

```swift
// DrivingDetector.swift sketch
func start(onChange: @escaping (Bool) -> Void) {
    // Calling startActivityUpdates is what triggers the Motion & Fitness permission prompt
    // on first use. No separate "request authorization" API exists for CMMotionActivityManager.
    CMMotionActivityManager().startActivityUpdates(to: .main) { activity in
        guard let a = activity, a.confidence != .low else { return }
        onChange(a.automotive && !a.stationary)
    }
}
```

**Permission prompt trigger:** `CMMotionActivityManager` has no explicit `requestAuthorization` method. The Motion & Fitness system prompt appears on the first call to `startActivityUpdates` or `queryActivityStarting(from:to:)`. Check status via `CMMotionActivityManager.authorizationStatus()` (iOS 11+) after a short delay; if `.denied`, fall back to the GPS-only heuristic.

**Fallback when Motion permission denied:** GPS-only heuristic — if `speed_kmh > 15` sustained for > 30s, treat as driving.

**Edge case — stopped at a light:** `a.automotive && a.stationary` → keep session alive but pause collection. Resume on next non-stationary automotive event.

## Background Execution

- `UIBackgroundModes: ["location", "processing"]` in `Info.plist`
- `locationManager.allowsBackgroundLocationUpdates = true` **only set this flag AFTER `.authorizedAlways` is granted.** Setting it under `.authorizedWhenInUse` doesn't crash but silently changes nothing — background updates stop the moment the user backgrounds the app, which means no readings on the first drive for anyone still in the pre-Always flow. Guard: `if locationManager.authorizationStatus == .authorizedAlways { locationManager.allowsBackgroundLocationUpdates = true }` and re-apply on `didChangeAuthorization`.
- `locationManager.pausesLocationUpdatesAutomatically = false`
- `locationManager.showsBackgroundLocationIndicator = true` (required for App Store)
- Register for `significantLocationChange` at app launch via `locationManager.startMonitoringSignificantLocationChanges()` — this is the relaunch mechanism after system termination or memory pressure. Do **not** rely on it after a user force-quit; iOS suppresses background relaunch in that state. **Requires `.authorizedAlways`** — with `.authorizedWhenInUse` it silently does nothing.
- **Bootstrap gap:** our permission flow requests `.authorizedWhenInUse` first and only escalates to `.authorizedAlways` after the user has completed a successful drive. During this pre-Always window, SLC-based relaunch does NOT work. Mitigate by keeping the "Recording" UI sticky in-app and showing a one-time banner after the first drive that explains the Always upgrade and what they gain.
- On `locationManager(_:didUpdateLocations:)` after a significant-change-triggered relaunch, check if driving activity is `.automotive` and if so, resume normal collection

*Current build note:* `SensorCoordinator.startMonitoring()` arms significant-location-change monitoring through `LocationService.startPassiveMonitoring()`. A moving GPS sample can also bootstrap active collection when motion activity is late or unavailable, and restoring a fresh "was collecting" checkpoint restarts collection services instead of only restoring UI state.

### Required Info.plist keys (single source of truth)

```xml
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>processing</string>
    <string>fetch</string>
</array>
<!-- `fetch` is required for BGAppRefreshTask (upload-drain); without it BGTaskScheduler.submit throws
     BGTaskSchedulerErrorCodeUnavailable at runtime and uploads never drain in the background.
     `processing` covers BGProcessingTask (nightly-cleanup). `location` covers continuous + SLC updates. -->
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>ca.roadsense.ios.nightly-cleanup</string>
    <string>ca.roadsense.ios.upload-drain</string>
</array>
<key>NSLocationWhenInUseUsageDescription</key>
<string>RoadSense NS records road quality from accelerometer data while you drive so that public road conditions can be mapped. Location is used to tag readings to road segments.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Background location lets RoadSense NS keep collecting while your phone is locked or the app is in the background during your drive. Data is filtered before upload and never shared with third parties.</string>
<key>NSMotionUsageDescription</key>
<string>Motion and accelerometer data are the core signal used to score road roughness. Nothing leaves your device until processed into anonymized segment readings.</string>
```

**CRITICAL:** any identifier submitted via `BGTaskScheduler.shared.submit(BGTaskRequest(...))` that isn't in `BGTaskSchedulerPermittedIdentifiers` throws at runtime. Keep this list and the `register(...)` calls in the AppDelegate in lock-step — add a unit test that asserts every registered identifier exists in the bundled Info.plist.

### Privacy Manifest (PrivacyInfo.xcprivacy) — REQUIRED

Apple enforces Required Reason API declarations via the privacy manifest for all App Store submissions since May 2024. Without a `PrivacyInfo.xcprivacy` file in the app bundle, submission will be rejected. Our app uses several Required Reason APIs transitively:

```xml
<!-- RoadSenseNS/PrivacyInfo.xcprivacy -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <!-- Coarse/precise location: linked to device token (a random UUID we rotate monthly;
             Apple considers rotated random IDs "linked" per their Data Collection guidance) -->
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePreciseLocation</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <true/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <!-- UserDefaults (SwiftData + settings): reason CA92.1 -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
        <!-- File timestamp (SwiftData persistence): reason C617.1 -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>C617.1</string></array>
        </dict>
        <!-- System boot time (thermal/battery correlation logs): reason 35F9.1 -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>35F9.1</string></array>
        </dict>
        <!-- Disk space (buffer-to-disk sanity checks): reason E174.1 -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>E174.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```

**SDK manifests (Apple requires these transitively):**
- Mapbox Maps iOS SDK v11+: ships its own `PrivacyInfo.xcprivacy` in the xcframework — verify present in SDK release notes
- Supabase Swift SDK: verify manifest present (they added one in late 2024)
- Sentry Cocoa SDK ≥ 8.21.0: ships manifest — pin to that or newer in Package.swift

The aggregate privacy report should therefore show:
- Precise Location from the app manifest above
- Diagnostics / performance data from Sentry's SDK manifest

**Before every TestFlight upload:** run `xcrun PrivacyReport` on the archive and confirm the manifest aggregates cleanly — missing reasons fail Beta App Review on external testing.

### Background task registration (required at launch)

`BGTaskScheduler` identifiers must be registered **before** `application(_:didFinishLaunchingWithOptions:)` returns, and must also appear in `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`:

```swift
// In AppDelegate.application(_:didFinishLaunchingWithOptions:) — before UI setup
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "ca.roadsense.ios.nightly-cleanup",
    using: nil
) { task in
    NightlyCleanupTask().run(task as! BGProcessingTask)
}
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "ca.roadsense.ios.upload-drain",
    using: nil
) { task in
    UploadDrainTask().run(task as! BGAppRefreshTask)
}
```

Tasks are **submitted** via `BGTaskScheduler.shared.submit()` from the places that want them (e.g., after a successful drive ends, submit an upload drain for 15 minutes from now). iOS ultimately decides whether/when to actually run them based on power, network, and usage patterns.

### Crash-safe buffering

**Buffer-to-disk every 60s.** `ReadingBuilder` persists its in-progress state to a small `SensorCheckpoint.json` file. On crash, we lose at most 60s of data.

### Task IDs used

- `ca.roadsense.ios.nightly-cleanup` — `BGProcessingTask`, prune readings, battery-history bookkeeping
- `ca.roadsense.ios.upload-drain` — `BGAppRefreshTask`, attempt upload queue drain

## SwiftData Schema (client)

```swift
@Model
final class ReadingRecord {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    var roughnessRMS: Double
    var speedKMH: Double
    var heading: Double
    var gpsAccuracyM: Double
    var isPothole: Bool
    var potholeMagnitude: Double?
    var recordedAt: Date
    var uploadBatchID: UUID?     // nil = pending
    var uploadedAt: Date?
    var droppedByPrivacyZone: Bool  // kept locally for user to see "X readings filtered"
}

@Model
final class UploadBatch {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var status: UploadStatus        // .pending, .inFlight, .succeeded, .failedPermanent
    var readingCount: Int
    var firstErrorMessage: String?
    var lastHTTPStatusCode: Int?
    var lastRequestID: String?
    var completedAt: Date?

    // Last server-returned ingest result. Populated on every 200 response so the
    // user can see why the server is silently discarding readings (e.g. stationary
    // filter, too-old timestamp, mismatched device_token hash).
    var acceptedCount: Int          // rows written server-side this submit
    var rejectedCount: Int          // rows dropped server-side this submit
    var rejectedReasonsJSON: String? // JSON-encoded [ReasonCount] — see API contract
    var wasDuplicateOnResubmit: Bool // server returned duplicate: true
}

@Model
final class PrivacyZoneRecord {
    @Attribute(.unique) var id: UUID
    var label: String               // "Home", "Work"
    var latitude: Double            // already offset at creation
    var longitude: Double
    var radiusM: Double             // 250, 500, 1000, 2000
    var createdAt: Date
    // Original (un-offset) coords NEVER stored — offset applied at creation
}

@Model
final class UserStats {
    @Attribute(.unique) var id: UUID = UUID()
    var totalKmRecorded: Double
    var totalSegmentsContributed: Int
    var lastDriveAt: Date?
    var potholesReported: Int
}

@Model
final class DeviceTokenRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var token: String               // UUID string, rotated monthly
    var issuedAt: Date
    var expiresAt: Date
}
```

`PrivacyZoneRecord` is the app-target SwiftData model. The shared pure-Swift geometry/filtering type keeps the shorter `PrivacyZone` name inside `RoadSenseNSBootstrap`, so the model layer uses the `Record` suffix to avoid a same-module symbol collision.

**Retention:** FIFO-prune `ReadingRecord` where `uploadedAt != nil` and older than 30 days. Separate `BGProcessingTask` enforces 100MB cap.

**Device token rotation:** At app launch, check `DeviceTokenRecord.expiresAt`. If expired, create new one. `APIClient` reads the latest token for the `device_token` field on each request.

Implementation note: the app target can delegate the rotation decision to the pure `DeviceTokenManager` seam and keep the SwiftData-specific fetch/insert logic in a thin `DeviceTokenStore`.

### SwiftData Migration Strategy

Do **not** rely on implicit SwiftData migration once TestFlight users exist. The app uses explicit `VersionedSchema` + `SchemaMigrationPlan` from the first shipping build onward.

- **Schema v1 (MVP launch):** `ReadingRecord`, `UploadBatch`, `PrivacyZoneRecord`, `UserStats`, `DeviceTokenRecord`
- **Schema v2 (post-MVP photos):** add `PotholeReportRecord`
- **Schema v3 (post-MVP drives):** add `DriveSessionRecord` and the optional `ReadingRecord.drive` relationship

Rules:

1. Additive first. New columns / relationships start optional or have safe defaults.
2. Never rename or delete a stored property in the same release that introduces the replacement.
3. Migration tests must open a fixture store created by the prior schema and assert the new schema loads without data loss.
4. If a migration fails, the app must fail closed: pause collection, show a local error explaining that the app's local database needs repair, and offer `Reset local data` rather than silently creating a second store.

## Upload Queue

Readings and photo uploads share the same scheduler (`UploadDrainCoordinator`) but do **not** share the same persistence row type.

- **Readings:** queued via `ReadingRecord` + `UploadBatch`
- **Photos:** queued via `PotholeReportRecord`

The coordinator serializes drain execution; the per-kind uploaders own their own state machines.

### Reading Queue State

`UploadBatch.status` has exactly four meanings:

- `.pending` — eligible now if `nextAttemptAt == nil || nextAttemptAt <= now`
- `.inFlight` — actively being submitted by the current drain task
- `.succeeded` — terminal success
- `.failedPermanent` — terminal failure, user-visible in Diagnostics

Retryable failures do **not** get their own status. They remain `.pending` with a future `nextAttemptAt`.

```
drainUntilBlocked(now):
  while network.status == .satisfied:
    if a photo upload is eligible:
        run one photo upload attempt
        continue

    existing_batch = oldest UploadBatch where status in (.pending, .inFlight)

    if existing_batch.status == .inFlight:
        adopt it only if lastAttemptAt <= now - 5 minutes
        else stop (another drain is active or recently crashed)

    if existing_batch.status == .pending && nextAttemptAt > now:
        stop

    if no existing batch:
        pending_readings = oldest 1000 ReadingRecord where uploadBatchID == nil
        if pending_readings is empty:
            stop
        create UploadBatch(status: .pending, nextAttemptAt: nil)
        associate readings with batch_id

    mark batch .inFlight
    attempt upload
      on 200:
          mark uploadedAt on associated readings
          mark batch .succeeded
          clear nextAttemptAt
          persist request_id, accepted/rejected counts, rejected reasons, duplicate
          continue
      on 400:
          mark batch .failedPermanent
          persist request_id / HTTP status / firstErrorMessage
          stop
      on 429:
          mark batch .pending
          set nextAttemptAt = now + Retry-After (or 60s default) + jitter
          persist request_id / HTTP status
          stop
      on 5xx / network error:
          if attemptCount >= 5:
              mark batch .failedPermanent
          else:
              mark batch .pending
              set nextAttemptAt = now + exponentialBackoff + jitter
          persist request_id / HTTP status
          stop
```

**Idempotency:** `batch_id` is the primary dedup key server-side. Client retries send the same batch_id; the server returns 200 with the original `{accepted, rejected, duplicate: true, rejected_reasons}` result on re-submit. The client stores `wasDuplicateOnResubmit` so Diagnostics can distinguish between "server dropped 47 rows" and "we already uploaded this batch and the retry was a no-op."

**Cross-batch replay protection:** field-test tooling can manually replay phone data, and a killed/reinstalled app can later retry the same physical readings under a different `batch_id`. The backend must suppress those rows too, keyed by `device_token_hash`, exact `recorded_at`, and near-identical coordinate. Suppressed rows return 200 as soft rejects with `duplicate_reading` in `rejected_reasons`; the client still marks its local batch uploaded because the server has accepted responsibility for the readings.

**Crash recovery:** a batch left in `.inFlight` at app relaunch is not assumed lost or succeeded. If `lastAttemptAt` is newer than 5 minutes, leave it alone and wait for the next scheduled drain. If older than 5 minutes, downgrade it to `.pending` and retry using the same `batch_id`.

**Rejected-reason surfacing:** The server's `rejected_reasons` map is a 1:1 copy of the API contract's emitted enum (see [03-api-contracts.md](03-api-contracts.md)). The iOS-side mapping lives in `RejectedReason.displayString`:

```swift
// RejectedReason.swift
enum RejectedReason: String, Codable {
    case outOfBounds      = "out_of_bounds"
    case noSegmentMatch   = "no_segment_match"
    case lowQuality       = "low_quality"
    case futureTimestamp  = "future_timestamp"
    case staleTimestamp   = "stale_timestamp"
    case unpaved          = "unpaved"
    case duplicateReading = "duplicate_reading"

    var displayString: String {
        switch self {
        case .outOfBounds:      "Outside Nova Scotia coverage"
        case .noSegmentMatch:   "No nearby road match"
        case .lowQuality:       "GPS or motion quality too low"
        case .futureTimestamp:  "Timestamp was in the future"
        case .staleTimestamp:   "Recording was too old to accept"
        case .unpaved:          "Matched an unpaved road"
        case .duplicateReading: "Already received by the server"
        }
    }
}
```

This is intentional — the user should see exactly what the server saw, in plain language, so they can tell the difference between "my privacy filter dropped it" (local, visible via `droppedByPrivacyZone`) and "the server dropped it" (remote, visible via `rejected_reasons`).

**Upload eligibility:** `NWPathMonitor` still publishes `path.status`, but MVP does **not** gate uploads on `path.isExpensive`. If the device has a satisfied network path, uploads are eligible. The only reasons to defer are: no network, a drain already in flight, or a persisted retry window (`nextAttemptAt`) after a 429 / 5xx.

**Batch size:** 1000 readings max per request (matches API contract). For ~50m-per-reading, that's ~50km of driving per batch.

### Upload Execution — Triggers, Background, Foreground

*Status: implemented in the current branch for the app-side upload loop. `BackgroundTaskRegistrar` registers the upload-drain task, routes it through `UploadDrainCoordinator`, cancels active drains on expiration, and reschedules the next `BGAppRefreshTaskRequest` from the completion path. Remaining proof is signed-device background-fetch validation.*

The user should never have to think about uploading. There is no "Upload now" button; there is no spinner the user has to wait on. Uploads happen opportunistically and quietly. Every trigger below funnels into a single `UploadDrainCoordinator` actor so foreground activation, queued BG refreshes, and drive-end scheduling cannot start concurrent drains against the same queue.

```
trigger                              | who submits it                 | task type
-------------------------------------|--------------------------------|------------------------
app foreground                       | RoadSenseNSApp scenePhase      | coordinator.requestDrain(.foreground)
drive end (DrivingDetector false)    | SensorCoordinator              | BGAppRefreshTask in ~15m
app backgrounded with pending >= 100 | RoadSenseNSApp scenePhase      | BGAppRefreshTask in ~15m
BGAppRefresh fire                    | BackgroundTaskRegistrar        | coordinator.requestDrain(.backgroundTask)
nightly maintenance                  | AppDelegate on launch + BG     | BGProcessingTask daily
```

**Concrete wiring.** `AppModel` gains an `uploadDrainCoordinator` seam that the `UploadDrainTask` handler on `BackgroundTaskRegistrar` actually calls:

```swift
actor UploadDrainCoordinator {
    private var activeDrain: Task<Bool, Never>?

    func requestDrain(reason: UploadDrainReason) async -> Bool {
        if let activeDrain {
            return await activeDrain.value
        }

        let task = Task { [uploader] in
            do {
                try await uploader.drainUntilBlocked()
                return true
            } catch is CancellationError {
                return false
            } catch {
                return false
            }
        }

        activeDrain = task
        let result = await task.value
        activeDrain = nil
        return result
    }
}
```

Drain order is deliberate: eligible pothole actions run first, then photo uploads, then reading batches. Rationale: explicit user-initiated pothole signals are tiny and latency-sensitive; clear them before the larger passive backlog.

`scheduleNextUploadDrain` wraps `BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(...))`. iOS decides when to actually fire — our job is to keep asking.

**Drive-end submit.** When `DrivingDetector` emits `false`, `SensorCoordinator` calls `scheduleNextUploadDrain(earliestBegin: .now + 15 * 60)`. 15 minutes is a compromise: long enough that iOS considers the device "idle", short enough that a commuter's data is normally on the server by the time they're done parking and walking inside.

**BG handler cancellation.** `expirationHandler` cancels the coordinator's active drain, `setTaskCompleted(success: false)` is still called, and `scheduleNextUploadDrain(...)` is re-submitted from the completion path even on cancellation. The background chain must not die just because iOS reclaimed one slot.

**Foreground drain.** In `RoadSenseNSApp.body`, observe `scenePhase` and call `uploadDrainCoordinator.requestDrain(.foreground)` on `.active` transitions, gated so we do not re-fire on every tiny foreground/background flap. A 30-second cooldown is enough.

**Retry / backoff.** `Uploader.drainUntilBlocked()` loops until one of three stop conditions: no eligible batches remain, network is offline, or the next batch is still inside its persisted retry window. 429 / 5xx do not "poison" later drains; they only block until `nextAttemptAt`.

**No user-triggered manual upload.** The stale "Upload now" button has been removed from the `MapScreen` contribution card. The surfaced affordances are passive only: queue count, last successful upload time, and a plain-language waiting reason (`offline`, `retrying at 3:42 PM`, `waiting for background time`). The only action row is **Diagnostics → Retry failed batches**, used when the queue is in `.failedPermanent` state.

### Data Volume & Upload Policy

The upload question has one answer for MVP: if the device has a network connection, upload. The data volume is too small to justify UI complexity or delayed ingestion.

**Readings (every user, every drive).**

- One reading ≈ 10 numeric fields + one ISO timestamp ≈ **~180–220 bytes of JSON**.
- With gzip (we enable `Content-Encoding: gzip` on `POST /upload-readings`), the batch compresses to **~70–90 bytes per reading** — timestamps and floats compress well because adjacent readings look similar.
- One reading covers ~50m of travel. At a realistic mixed-speed average of 50 km/h, that's **~1000 readings per hour of driving** ≈ **~80 KB/hour uploaded**.
- A median Nova Scotia commuter drives ~45 min/day (Stats Canada 2021). That's **~2 MB/month** uploaded.
- A heavy driver (2 hrs/day, every day) tops out around **~10 MB/month**.

Conclusion: readings are not remotely a concern for cellular data. Delaying them for Wi-Fi would trade off coverage and freshness against a sub-1% monthly data-plan cost.

**Pothole photos (post-MVP, opt-in per report).**

- Target: **≤ 400 KB per photo** after on-device JPEG resize (1600px longest edge, quality 0.8) and EXIF strip.
- 5 reports per week from an engaged user = **~8 MB/month**.
- 1 report per day = **~12 MB/month**.

**Decision:**

| Upload type | MVP behavior | User toggle | Rationale |
|---|---|---|---|
| Readings | **Upload over any available network** | None | ~2 MB/month is negligible; coverage and freshness matter more than a settings switch. |
| Photos | **Upload over any available network** | None | Even engaged usage stays small enough that the extra toggle is not worth the code and UX complexity. |

Settings → Uploads wording:

- `Uploads waiting`
- `Last successful upload`
- `Current waiting reason`
- `Retry failed batches`

`NWPathMonitor.isExpensive` is ignored in MVP. If data-plan complaints become real during beta, revisit with field data rather than speculative gating.

### Retention & Cleanup

Already specified above: prune uploaded `ReadingRecord` after 30 days, enforced by the `nightly-cleanup` `BGProcessingTask`. The task handler is real but the pruning SQL is stubbed — tracked as a separate backlog item.

## Endpoint Trimming And Privacy Zones

### Default Endpoint Trimming

Privacy zones are **optional** extra protection, not the default guardrail. Every sealed drive goes through endpoint trimming before any reading is enqueued for upload.

`DriveEndpointTrimmer` runs after `DriveSessionRecord` seal, using the ordered accepted `ReadingWindow`s plus the session's first and last usable `LocationSample`.

Drop a reading from upload if **any** of the following is true:

1. `reading.recordedAt < session.startedAt + 60s`
2. `reading.recordedAt > session.endedAt - 60s`
3. `haversineDistance(reading.location, session.startCoordinate) < 300m`
4. `haversineDistance(reading.location, session.endCoordinate) < 300m`

This is a union, not an either/or toggle. The point is to suppress both driveway-scale endpoint leakage and the jittery parked period at the beginning/end of a trip.

Implementation notes:

- `DriveSessionRecord` must persist `startCoordinate` and `endCoordinate` separately from uploadable readings so trimming is deterministic after relaunch.
- The trimmer mutates local reading state to `uploadEligibility = .trimmedByEndpoint` rather than deleting the rows. Local drives/stats can still explain why nothing uploaded.
- If trimming removes every reading in a drive, enqueue nothing for that drive and surface a local-only explanation: `This drive was kept private by endpoint trimming.`
- Photos do **not** use endpoint trimming. They rely on explicit user action plus privacy-zone rejection.

Sketch:

```swift
func uploadEligibility(
    for reading: ReadingWindow,
    session: DriveSessionRecord
) -> UploadEligibility {
    if reading.recordedAt < session.startedAt.addingTimeInterval(60) { return .trimmedByEndpoint }
    if reading.recordedAt > session.endedAt.addingTimeInterval(-60) { return .trimmedByEndpoint }
    if haversineDistance(reading.location, session.startCoordinate) < 300 { return .trimmedByEndpoint }
    if haversineDistance(reading.location, session.endCoordinate) < 300 { return .trimmedByEndpoint }
    return .eligible
}
```

### Privacy Zone Implementation

### Zone Creation

When user adds a zone via Settings → map picker:
1. User taps a point on map
2. We snap to nearest 100m grid (prevents finger-precision leak)
3. We apply randomized offset in uniform-random direction, distance 50-100m
4. We store ONLY the offset coordinates + the chosen radius
5. Original tap location is discarded immediately (never persisted, never logged)

### On-Device Filtering

```swift
// PrivacyZoneFilter.swift sketch
func shouldDrop(_ reading: ReadingWindow, zones: [PrivacyZone]) -> Bool {
    for zone in zones {
        if haversineDistance(reading.location, zone.coord) < zone.radiusM {
            return true
        }
    }
    return false
}
```

Run on **every single GPS sample** inside `ReadingBuilder`, not just at window close. If any sample inside the window falls in a zone, drop the entire window. Set `droppedByPrivacyZone = true` locally for user-visible stats ("73 readings filtered by privacy zones this month").

Order of operations for a completed drive:

1. Real-time privacy-zone filtering during collection
2. Persist accepted readings locally
3. Seal `DriveSessionRecord`
4. Apply endpoint trimming to persisted accepted readings
5. Enqueue only readings whose final `uploadEligibility == .eligible`

### Edge Case — Entire Commute Inside Zones

`ReadingBuilder` tracks dropped windows per session. If endpoint trimming and/or privacy-zone filtering leaves a session with `eligible_upload_count == 0`, show a non-blocking banner: "This drive was filtered for privacy — no data was contributed. Tap to review privacy settings."

## Permission Flow (UI Timing)

Matches product-spec progressive flow, concrete state machine:

```
state: onboarding
  screen 1: "what this app does"
  screen 2: "we need When-In-Use location + Motion" → show combined rationale
     tap "Enable" → CLLocationManager.requestWhenInUseAuthorization()
                 → CMMotionActivityManager().startActivityUpdates(to: .main) { _ in }
                   // ^ first call to startActivityUpdates or queryActivityStarting(from:to:to:withHandler:)
                   //   is what triggers the Motion & Fitness prompt. There is no `activityTypes` property.
                   //   Call this AFTER the location prompt resolves so the two dialogs don't collide.
                   //   Immediately call `stopActivityUpdates()` after the authorization status transitions
                   //   to avoid wasting the motion coprocessor outside of a drive.
  screen 3: "drive and check back"
  → state: foreground-collecting

state: post-first-successful-drive
  after first successfully-uploaded batch:
    show value banner: "You just mapped 12 km of Halifax roads!"
    tap "Enable background collection" → CLLocationManager.requestAlwaysAuthorization()
  → state: background-collecting (or foreground-only if denied)

state: degraded-permission (any of: Motion denied, location When-In-Use only, etc.)
  persistent banner in Map view with relevant Settings deep-link
```

See [product-spec.md §Degraded Permission States](../product-spec.md) for the full matrix.

## Experience Principles

The iOS app is **not** a municipal analytics console squeezed onto a phone. Its job is to:

1. make passive collection feel trustworthy and low-effort
2. give the user immediate visual proof that their driving mattered
3. explain community road quality without forcing the user to think like a GIS analyst

Design decisions should bias toward these principles:

- **Map first, controls second.** The map is the home screen and the emotional payoff.
- **One primary question per screen.** Onboarding answers "why should I allow this?", the map answers "what does the road look like right now?", settings answers "what is this app doing on my phone?"
- **Earn trust continuously.** Always show recording state, upload state, confidence, and privacy posture in plain language.
- **Reward contribution without gamifying recklessly.** Use progress, coverage, and "you mapped this" moments, not points/badges spam.
- **Keep civic, not corporate.** The app should feel precise and public-interest-minded, not like ad-tech or an insurance app.

## Visual Direction

### Look and Feel

- **Mood:** "Atlantic civic utility" rather than generic startup SaaS. Quietly premium, grounded, weathered, legible.
- **Base palette:** warm off-white surfaces, charcoal map chrome, desaturated ocean blue accents, and road-quality colors that read instantly outdoors.
- **Avoid:** neon gradients, glossy glassmorphism, heavy shadow stacks, overly dark "hacker" styling, or a purple-white default app-store look.

### Typography

- Use **New York** for large headings and explanatory editorial copy blocks ("How RoadSense works", segment detail title).
- Use **SF Pro** for controls, metrics, compact labels, and dense map UI.
- Large stats should be bold and calm, not gamified: `12.4 km driven`, `3 trips recorded`, `2 potholes confirmed`.

### Color Tokens

Define app-level semantic tokens and reuse them in SwiftUI + map styling:

- `surface.primary`: warm near-white (`#F6F4EF`)
- `surface.secondary`: pale stone (`#E9E4DA`)
- `ink.primary`: dark charcoal (`#1F2328`)
- `ink.secondary`: slate (`#5C6670`)
- `accent.community`: North Atlantic blue (`#2C6E91`)
- `accent.personal`: teal (`#187E74`)
- `status.smooth`: green (`#3FAF72`)
- `status.fair`: amber (`#D9A441`)
- `status.rough`: orange (`#D9752B`)
- `status.veryRough`: brick red (`#B94A3B`)
- `status.unscored`: muted gray-blue (`#8A97A3`)

The map line colors and SwiftUI legend chips must share these exact tokens so screenshots, segment detail, and the live map tell one coherent story.

### Motion

- Use short, purposeful motion only where it communicates state change:
  - recording pill gently pulses when active
  - local-drive overlay fades into community styling after upload completes
  - segment detail sheet springs from the tapped road with a subtle anchor effect
- Do **not** animate constantly on the map. Motion should confirm state, not compete with geography.

## Mapbox Integration

### Setup

- Mapbox Maps SDK v11+ via SPM: `https://github.com/mapbox/mapbox-maps-ios.git`
- API key in `AppConfig`, loaded from a build-time `.xcconfig`
- Commit non-secret base configs in `ios/Config/` so project generation works from a clean checkout
- Put developer- or CI-only overrides in optional ignored `*.secrets.xcconfig` files
- Tile source: custom vector tiles from our backend (not Mapbox hosted) — see [02-backend-implementation.md](02-backend-implementation.md)

### Style Stack

```
┌─ Base style (customized light-first Mapbox Streets derivative)
├─ Road quality overlay layer
│   source: vector, url: AppConfig.apiBaseURL + "/tiles/{z}/{x}/{y}.mvt"
│                   // MVP default: https://<supabase-project-ref>.supabase.co/functions/v1
│                   // Public site domain is roadsense.ca, but the API does not need a
│                   // separate custom domain on day 1. Keep this configurable in AppConfig.
│   source-layer: "segment_aggregates"
│   type: line
│   paint:
│     line-color: interpolate on roughness_score
│       0.3 → status.smooth
│       0.6 → status.fair
│       1.0 → status.rough
│       1.5 → status.veryRough
│     line-width: interpolate on zoom
│       10 → 1.5
│       14 → 3
│       18 → 6
│     line-opacity: case
│       confidence == "low" → 0.4
│       confidence == "medium" → 0.7
│       else → 1.0
├─ Pothole markers layer
│   source: vector (same endpoint, different source-layer)
│   type: circle; data-driven radius based on magnitude, color = deep red with pale stroke
├─ Local "your drives" overlay (GeoJSON from SwiftData)
│   line-color: accent.personal
│   line-dasharray: [2, 2]
│   distinguishes user's unprocessed data pre-aggregation
├─ Coverage haze layer (future toggle)
│   soft heat/coverage texture, OFF by default in MVP
```

Prefer a **light map by default** because users will often check the app outdoors or in bright cars. Dark mode can exist, but do not make it the primary design reference.

### Zoom-Level Filtering

Filter expression on the road-quality layer:
```
filter: ["step", ["zoom"],
    ["in", ["get", "road_type"], ["literal", ["primary", "secondary", "motorway"]]],
    12, ["!=", ["get", "road_type"], "service"],
    14, true
]
```

Backend does the same filter at tile generation time — this filter is a defense-in-depth/client-side render hint.

### Offline Packs

On first launch after permissions granted, download a tile pack covering Halifax Regional Municipality at zoom 10–16. Use `OfflineManager` with progress reported in onboarding screen.

## UI Surfaces (SwiftUI)

### Navigation root

`NavigationStack` with tab-less root — the map IS the app. Settings and Stats reached via overlay buttons.

The home screen should read in this order:

1. recording / paused status
2. contribution proof (`you mapped X km`)
3. road quality on the map
4. deeper details only on demand

### Core Home-Screen Layout

- **Top-left:** recording status pill
  - `Recording`
  - `Paused`
  - `Needs Always Location`
- **Top-right:** icon buttons for stats and settings
- **Bottom floating card:** "Your contribution" card with today's km, pending uploads, and a single most-useful next action
- **Map legend:** collapsed by default into a single "Road quality" chip; expands to show color meanings and confidence note

Do not fill the map with panels. The floating chrome should stay below ~20% of the visible map area on iPhone 13-size screens.

### Screens (condensed list)

- **OnboardingFlow** — 3 screens, no skip
- **MapScreen** — full-bleed Mapbox view, floating contribution card, recording pill, expandable legend
- **SegmentDetailSheet** — `.sheet` presentation, scrollable; loads from `GET /segments/{id}`
- **StatsScreen** — personal contribution summary first, community context second
- **SettingsScreen** — privacy zones, upload status, battery saver, data management, about
- **PrivacyZoneEditor** — map picker + radius slider
- **AboutScreen** — how it works (plain language), privacy policy link, open-source link

### Onboarding UX

Three screens are enough, but they need stronger emotional and informational structure:

1. **Value:** "Help map rough roads in Nova Scotia while you drive."
   - full-bleed map illustration with a few highlighted roads
   - one short paragraph, not a wall of text
2. **Trust:** "What we use, and what we do not store."
   - location + motion explanation
   - explicit endpoint-trimming explanation
   - optional privacy-zone mention
   - one tap to expand "Learn more"
3. **Permission ask:** "Turn on location and motion to start mapping."
   - list the immediate benefit
   - list the user control: pause anytime, delete local data, add privacy zones

Avoid copy that sounds apologetic or legalistic. The tone should be plain, civic, and confident.

### MapScreen Behavior

- Empty state should still feel alive:
  - community-empty: "No road quality data here yet."
  - personal-empty: "Drive with RoadSense on to start mapping this area."
- When the user has local, unuploaded drives, show them immediately with the personal teal overlay and label the state as `Local only`.
- When tapping a segment, the selected line brightens and thickens slightly before the sheet appears.
- Low-confidence roads stay visible only where the spec already allows, but the detail sheet must explain confidence in English: `High confidence: many drivers`, `Medium confidence: enough data`, `Low confidence: early signal`.

### Segment Detail Sheet

The sheet should feel editorial, not raw-database:

- Title: road name, municipality secondary
- Primary stat row: category, confidence, last updated
- Main chart area:
  - current score chip
  - 30-day trend sparkline placeholder area even if MVP history is empty
- Explanation block:
  - `Based on 137 readings from 34 contributors`
  - `2 pothole reports nearby`
- If history is empty in MVP, show a graceful stub: `Trend history is coming as more data accumulates.`

### Stats Screen Information Architecture

Stats should answer "is this app doing anything?" faster than it answers "how many raw records exist?"

Order:

1. `You've driven X km`
2. `Trips recorded`
3. `Uploads pending / last upload`
4. `Potholes flagged`
5. community context (`Halifax coverage`, `active rough segments nearby`) only after personal stats

### Settings Information Architecture

Group settings into four sections only:

1. **Privacy** — zones, delete local data, privacy policy
2. **Uploads** — pending count, last successful upload, current waiting reason, retry, plus a `Diagnostics` row that opens a transparent log: last 20 batches with `{accepted, rejected, top reasons}`. Shows an inline banner when `ingestHealth == .degraded` with the top reason in plain language (e.g. "47% of readings this week were rejected because the app thought you were stationary"). No dark patterns; the row is named `Diagnostics`, not `Advanced`.
3. **Recording** — pause/resume, battery saver explanation
4. **About** — how it works, open source, version

Do not bury privacy controls under generic "Advanced" menus.

### Copy and Trust Details

- Prefer plain labels such as `Recording while driving`, `Uploads waiting`, `Privacy zones active`
- Avoid internal terms in the UI like `segment_aggregates`, `roughness_rms`, `batch_id`
- Every state that could feel creepy should include a user-controlled explanation:
  - why the app is recording
  - when uploads happen
  - how to stop it
  - how privacy zones work

### Delight Without Noise

Use a few deliberate reward moments:

- after first uploaded drive: `You helped map 12 km of roads today`
- after a new municipality or neighborhood gets first coverage: `You started coverage here`
- after a pothole is later confirmed by the community: `A road issue you detected was confirmed`

No confetti. No streaks. No fake social mechanics.

### State Management

`@Observable` (iOS 17) view models per screen. No Redux/TCA — too much ceremony for this size of app.

Cross-screen state (recording status, pending upload count, stats) lives on a single `@Observable final class AppState` injected at the root.

## Error UX

- **Permission denied** → inline banner in Map with "Open Settings" button
- **Upload failed permanently** → Settings shows "X readings couldn't be uploaded. [Retry] [Discard]"
- **No connectivity** → subtle "offline" chip in header, no modal
- **Thermal throttle** → full-screen takeover in Map with "phone too hot — collection paused" + tips
- **Crash recovery** → silent; check `SensorCheckpoint.json` on launch, discard if older than 30 minutes

## Logging

`os.Logger` with subsystem `ca.roadsense.ios`. Categories:
- `sensor.pipeline`
- `upload.queue`
- `persistence`
- `permission`
- `map`

**Never log:** raw lat/lng, device token, user-visible stats (these belong in the app, not Console)

**Always log:** batch IDs, upload statuses, permission state transitions, thermal state transitions, driving state transitions

## iOS Decisions Locked

- **Endpoint trimming is mandatory; privacy zones are optional.** Passive collection can start once the core permissions are granted. Privacy zones remain prominent in Settings and the ready state, but they are an extra user control, not a collection gate.
- **Dynamic Type coverage scope is broad, not selective.** Test onboarding, map chrome, segment drawer, stats, and settings at large accessibility sizes. The question was simply how much of the UI must be exercised at large text sizes; answer: all core user-facing flows, not just one or two screens.
- **No pothole haptics in MVP.** Passive collection should stay quiet in the background; revisit only if a future explicit "active drive mode" exists.

## Manual Pothole Reporting And Follow-up

*Status: implemented in the current iOS build for the first explicit-reporting pass: map CTA, 5-second undo, `ManualPotholeLocator`, `PotholeActionRecord`, queue persistence, optional sensor-backed manual severity, upload through `POST /pothole-actions`, segment-detail `Still there` / `Looks fixed` actions against canonical pothole IDs, and a stopped-only expiring follow-up prompt when the user opens a nearby segment that already has an active pothole. The undo window is now enforced against `undoExpiresAt` rather than toast timing, and promoted actions request an upload drain immediately after the window closes. Broader proactive resurfacing prompts on later drive passes remain polish, not missing plumbing.*

The passive pothole detector remains the default source of road-issue data, but it misses two things users clearly want:

1. a fast "I just hit one" signal while the map is already open during a drive
2. a way to say an existing pothole is still there or appears fixed

All explicit pothole actions feed the same canonical backend entity: one merged `pothole_reports` row per physical pothole spot.

### User Flow

#### Manual mark while driving

1. User has the map open while driving.
2. A large thumb-reachable button reads `Mark pothole`.
3. Tap once.
4. App immediately shows a toast: `Pothole marked` with `Undo` for 5 seconds.
5. After the undo window expires, the action uploads automatically on the next eligible drain.

There is no typing, no modal confirm step, no star rating, and no camera in the happy path.

#### Follow-up on an existing pothole

1. User taps a pothole marker or a pothole row in segment detail.
2. The sheet offers `Still there` and `Looks fixed`.
3. Tap either action.
4. App shows `Thanks for the update.` and queues the follow-up action for upload.

The client never immediately flips the marker to resolved. Resolution is server-owned and only appears after the next tile refresh.

### Safety And Location Capture

The manual `Mark pothole` button is explicitly allowed while driving. Safety comes from keeping it one tap with no text entry or camera, not from blocking motion.

The client must still reject obviously bad location state:

```swift
let hasUsableLocation =
    chosenSample.ageSeconds <= 10 &&
    chosenSample.horizontalAccuracyM <= 25
```

Location selection for the tap is intentionally not just `latestSample`. Driver reaction time means the tap usually happens slightly after the wheel hits the pothole. `ManualPotholeLocator` keeps a rolling 3-second buffer of `LocationSample`s and chooses the sample closest to `tapTimestamp - 0.75s`. If no buffered sample exists, fall back to `latestSample`.

If `hasUsableLocation == false`, tapping the button shows a non-blocking banner: `Waiting for a stronger location signal.` and no row is queued.

If a local sensor pothole candidate was detected shortly before the tap, the manual action may carry measured impact as advisory severity. The current rule attaches the strongest candidate within 20 seconds and 25m of the compensated tap location. Stale or distant candidates are ignored, so passenger taps and late taps still create a valid manual report without measured severity.

### Privacy And Abuse Rules

Manual pothole actions are explicit, but they do **not** override privacy protections in MVP.

1. **Privacy zones still win.** If the chosen pothole coordinate falls inside a privacy zone, reject the action client-side and show `This spot is inside one of your privacy zones, so it was not reported.`
2. **No free text.** Manual pothole reporting has zero comment fields.
3. **No one-tap hard resolve.** `Looks fixed` is a negative confirmation, not an immediate delete.
4. **Duplicate-tap guard.** After a successful tap, disable `Mark pothole` for 5 seconds. If the user taps again within `20m` and `8s`, update the existing pending-undo row instead of creating another one.

### Data Model

```swift
enum PotholeActionType: String, Codable {
    case manualReport
    case confirmPresent
    case confirmFixed
}

enum PotholeActionUploadState: String, Codable {
    case pendingUndo
    case pendingUpload
    case failedPermanent
}

@Model
final class PotholeActionRecord {
    @Attribute(.unique) var id: UUID
    var potholeReportID: UUID?      // required for confirmPresent / confirmFixed
    var actionType: PotholeActionType
    var latitude: Double
    var longitude: Double
    var accuracyM: Double
    var recordedAt: Date
    var createdAt: Date
    var undoExpiresAt: Date?        // only set for manualReport
    var uploadState: PotholeActionUploadState
    var uploadAttemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var lastHTTPStatusCode: Int?
    var lastRequestID: String?
    var sensorBackedMagnitudeG: Double? // manualReport only
    var sensorBackedAt: Date?           // manualReport only
}
```

Rows in `pendingUndo` are local-only and must be skipped by the uploader until `undoExpiresAt <= now`. Once the undo window passes, promote the row to `pendingUpload`.

Successful uploads can be deleted from SwiftData immediately; only retryable or permanent-failure rows need to stay around for diagnostics.

### Upload

Manual pothole actions use a small JSON endpoint, `POST /pothole-actions`.

Request body sketch:

```json
{
  "action_id": "uuid",
  "device_token": "uuid",
  "action_type": "manual_report",
  "pothole_report_id": null,
  "lat": 44.6488,
  "lng": -63.5752,
  "accuracy_m": 6.8,
  "recorded_at": "2026-04-21T18:22:00Z",
  "sensor_backed_magnitude_g": 2.7,
  "sensor_backed_at": "2026-04-21T18:21:58Z"
}
```

Server response includes the canonical `pothole_report_id` that the action folded into (new or existing).

`sensor_backed_magnitude_g` and `sensor_backed_at` are optional and valid only for `manual_report`. Omit them for manual-only reports and all follow-up actions.

### Pothole Action Client State Machine

```swift
for each eligible PotholeActionRecord:
  if uploadState == .failedPermanent:
      skip

  if uploadState == .pendingUndo && undoExpiresAt > now:
      skip

  if uploadState == .pendingUndo && undoExpiresAt <= now:
      set uploadState = .pendingUpload

  if nextAttemptAt > now:
      stop pothole-action pass and yield back to the coordinator

  POST /pothole-actions with action_id == id
    on 200:
        delete local row
    on 409 stale_target:
        set uploadState = .failedPermanent
    on 400:
        set uploadState = .failedPermanent
    on 429 / 5xx / network error:
        keep uploadState = .pendingUpload
        set nextAttemptAt using the same backoff rules as readings
```

Undo behavior is purely local. If the user taps `Undo` before upload, delete the row outright and show `Pothole report cancelled`.

### Follow-up UX Scope

Core follow-up entry points for this feature are:

- pothole marker detail sheet
- segment detail rows for nearby potholes

Expiring Waze-style prompts after a later pass near an active pothole are a separate UX-polish slice. They build on this same action model but are not required for the first implementation.

## Pothole Photo Capture (Post-MVP)

*Status: implemented end-to-end in the current build for the first shipped photo flow: map `Take photo` CTA, segment-detail `Add photo` entry point, stopped-only camera gating, `PotholeCameraFlowView`, `PotholeReportRecord`, `PotholePhotoProcessor`, queue persistence, metadata POST + signed PUT upload, transition to local `pendingModeration` after upload, and backend moderation/publishing support. The current build also includes sheet-safe camera presentation sequencing, segment-scoped `segment_id` wiring, Settings diagnostics plus retry/remove controls for failed photos, and accessibility fixes for camera controls and banner text. Moderator-facing tooling remains intentionally internal-only, not user-facing.*

The passive pipeline already detects pothole events, and the manual tap flow gives a fast explicit confirmation, but neither provides visual context. The photo capture feature adds a low-friction way for a pedestrian or stopped driver to submit a geotagged image that will join the same merged pothole cluster after moderation.

This feature is explicitly designed for the **stopped-or-walking** case (passenger, pedestrian, someone who noticed a pothole while getting out of their car) and gates the capture behind a low-speed check.

### User Flow (target: ≤ 4 taps from app open)

1. User opens the app.
2. On the map, a secondary floating button reads `Take photo`. (Icon: `camera.viewfinder`.) It sits below the primary `Mark pothole` action.
3. Tap → full-screen camera sheet (`AVFoundation`, not `UIImagePickerController` — we need to strip metadata before the user sees a confirm screen).
4. User frames the pothole, taps shutter.
5. Confirm screen shows the photo + a simple coordinate label (`Near 44.6488, -63.5752`) + two buttons: `Submit` / `Retake`.
6. Tap `Submit` → success toast (`Thanks — a moderator will review this report`) → return to map. Photo queues for upload like readings.

No moderation happens client-side. No AI classification client-side. The user does not name the pothole, rate the pothole, or describe the pothole — those are moderation concerns.

### Entry Points

- **Map screen:** secondary floating button as above.
- **Segment detail sheet:** any opened segment detail sheet shows an `Add photo` row that opens the camera pre-scoped to that segment ID.
- **Settings → About:** no entry point. The feature is discoverable from the map, not buried.

### Safety Gates

The button is visible from the map even while the app believes the user is driving. The actual gate happens when the user tries to open the camera and again when they press the shutter:

```swift
let canCapture =
    latestLocation.ageSeconds <= 10 &&
    latestLocation.speedKmh < 5
```

If `canCapture == false`, do not present the camera; show the same non-blocking feedback path used by manual pothole taps. A stale location sample counts as `false`; we do not infer "probably stopped." The current build gates on camera entry and on final submit, which is sufficient for the first pass.

### Privacy

Photos are categorically more sensitive than readings. The photo pipeline MUST:

1. **Strip all source-camera metadata before upload.** Re-encode the captured image into a fresh JPEG before it ever touches the upload queue. The privacy-sensitive fields (GPS, TIFF, original Exif capture metadata) must be absent from the uploaded bytes. ImageIO may still emit minimal derived structural metadata such as pixel dimensions; that is acceptable.
2. **Use `LocationService.latestSample`, not EXIF GPS, for geotagging.** This keeps the geotag in the privacy-zone pipeline. Any photo whose GPS coords fall in a privacy zone gets **rejected at the client** with a sheet: "This spot is inside one of your privacy zones. The report was not sent. (You can adjust your zones in Settings.)" The photo file is deleted immediately.
3. **Upload the precise `latestSample` coordinate; do not randomize it.** Photo moderation and pothole clustering need exact placement. Privacy comes from client-side privacy-zone rejection, rotating device tokens, private storage of raw photo rows, and the fact that the public map shows the merged `pothole_reports` point / matched segment, not the submitter's original photo coordinate.
4. **Resize to ≤ 1600px longest edge, JPEG quality 0.8** before upload. Typical output: 250–400 KB. Raw HEIC off the camera is 3–5 MB and contains too much incidental detail (faces, license plates, house numbers in the background).
5. **Do not store photos permanently on-device.** Photos live in the upload queue until the PUT succeeds, then are deleted from disk. There is no "my reports" photo gallery.

### Data Model

```swift
// Persistence/Models/PotholeReportRecord.swift
enum PhotoUploadState: String, Codable {
    case pendingMetadata
    case pendingModeration
    case failedPermanent
}

@Model
final class PotholeReportRecord {
    @Attribute(.unique) var id: UUID
    var segmentID: UUID?
    var photoFilePath: String       // points into AppSupport/pothole-photos/{id}.jpg
    var latitude: Double            // precise latestSample coordinate
    var longitude: Double           // precise latestSample coordinate
    var accuracyM: Double
    var capturedAt: Date
    var uploadState: PhotoUploadState
    var uploadAttemptCount: Int
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var expectedObjectPath: String?
    var byteSize: Int
    var sha256Hex: String
    var lastHTTPStatusCode: Int?
    var lastRequestID: String?
}
```

`id` is the client-generated `report_id`. There is no separate server-assigned identifier to wait for.

The on-disk photo file is written once, never rewritten. Deletion is the only allowed lifecycle event after creation.

### Upload

Two-step, signed-URL pattern (the readings endpoint is fine for point JSON; photos are too big for an Edge Function body):

1. `POST /pothole-photos` — small JSON metadata request. Body:
   ```json
   {
     "report_id": "uuid",
     "segment_id": "uuid-or-null",
     "device_token": "uuid",
     "lat": 44.6488,
     "lng": -63.5752,
     "captured_at": "2026-04-21T18:22:00Z",
     "content_type": "image/jpeg",
     "byte_size": 312840,
     "sha256": "hex..."
   }
   ```
   `segment_id` is optional and is populated when the photo flow starts from a specific segment detail sheet.
   Server validates, creates a `pothole_photos` row in `pending_upload` status, allocates a Supabase Storage object path, returns a signed PUT URL + expected object path.
2. `PUT <signed-url>` — direct upload of the JPEG bytes to Supabase Storage. The app uploads the exact JPEG bytes it hashed in step 1; the signed URL is treated as an ephemeral, single-attempt credential and is never persisted locally.
3. Server watcher (trigger or cron) on the Storage bucket flips the row to `pending_moderation` once the file lands. The client does **not** poll status; after the PUT returns 200, it sets `uploadState = .pendingModeration`, deletes the local JPEG, and shows the success toast immediately: `"Thanks — a moderator will review this report."`

Supabase signed upload URLs currently behave as two-hour URLs in practice. The client treats them as single-attempt, in-memory credentials regardless and re-POSTs metadata after interruption rather than persisting them.

Pothole photos follow the same network policy as readings: if the device has connectivity and the queue is eligible, they upload.

### Photo Upload Client State Machine

The client does **not** persist signed upload URLs. Treat `POST metadata + PUT bytes` as one in-memory attempt:

```swift
for each eligible PotholeReportRecord:
  if uploadState == .pendingModeration || .failedPermanent:
      skip

  if nextAttemptAt > now:
      stop photo pass and yield back to the main drain coordinator

  POST /pothole-photos with report_id == id
    on 200:
        persist expectedObjectPath, request_id
        immediately PUT bytes to signed URL
           on 200:
               set uploadState = .pendingModeration
               delete local file
               clear nextAttemptAt
           on 400 / 413:
               set uploadState = .failedPermanent
           on 429 / 5xx / network error:
               leave uploadState = .pendingMetadata
               set nextAttemptAt using the same backoff rules as readings
    on 409 already_uploaded:
        treat as success, set uploadState = .pendingModeration, delete local file
    on 400:
        set uploadState = .failedPermanent
    on 429 / 5xx / network error:
        keep uploadState = .pendingMetadata
        set nextAttemptAt
```

Photo backoff does **not** block reading uploads. A photo row with `nextAttemptAt > now` is simply skipped until a later drain.

If the app backgrounds or the task expires after the metadata POST but before the PUT completes, discard the in-memory signed URL and retry from step 1 with the same `report_id` on the next drain. The backend reissues a fresh signed URL while the row is still `pending_upload`; once the object already exists, the prepare endpoint returns `409 already_uploaded`.

### Moderation

Explicitly server-side, out of scope for this doc except for the client contract:

- Photos that pass moderation fold into the canonical pothole cluster and set `pothole_reports.has_photo = true`.
- Photos that fail moderation are deleted server-side; the client never learns why.
- The client does not show pending/rejected state to the submitter — the UX is "you reported it; thanks". Post-MVP we can add a "my reports" screen, but adding visibility into the moderation queue early creates an abuse vector (submitters tuning to bypass filters).

See [02-backend-implementation.md §Pothole Photo Moderation](02-backend-implementation.md) for schema, Storage bucket config, and moderation tooling.

### Accessibility & Failure Modes

- Camera permission denied → inline full-screen state with `Open Settings` button.
- Low-light capture → no flash; we'd rather have no report than a flash-blinded one that crashes the classifier. Show inline hint: "Tap to focus. Daylight works best."
- Out-of-bounds coords (outside Nova Scotia) → client-side rejection with sheet: "Reports are limited to Nova Scotia roads right now."
- Upload 400 / 413 / 429 → same state as readings (`failedPermanent` after 5 attempts). The photo is preserved locally for later diagnostics/retry work, and the current build exposes retry/remove controls in Settings for failed photo rows.

### UI Accessibility

- VoiceOver: camera sheet announces "Pothole camera. Tap center to take photo."; confirm screen announces `"Photo of pothole near Quinpool Road, Halifax. Double-tap Submit to send."`
- Dynamic Type: all text in the confirm screen respects `Text.font(DesignTokens.TypeStyle.body)` and allows wrapping — we do not layout-constrain the address line.

### Not In This Version

- Rating the pothole ("how bad?"). Server-side aggregation from photo + nearby accelerometer hits is a better signal than user rating.
- Editing the geotag location. If the device GPS is off by more than 20m, the report is wrong; better to reject it at `accuracyM > 20` client-side than let a user hand-move a pin.
- Comment field. Zero value, unlimited abuse surface.
- Video. 10× the bandwidth, 1.1× the signal.

## My Drives List (Post-MVP)

*Status: not implemented. Partial infrastructure exists via the teal local-overlay.*

### Is This Feature Necessary?

Right now the app shows an aggregate local overlay (the dashed teal `Local only` styling on yet-to-upload segments) and a single `Kilometres mapped` count on the Stats screen. A per-drive list is a different promise: "here is what you drove on Monday, tap it to see the map, long-press to delete it."

**Worth building?** Yes, but post-MVP. Three reasons:

1. **Trust.** "Prove what you have of mine" is the other half of "give me a delete button." Today the delete-local-data button nukes everything; a per-drive delete lets a user remove, say, a single trip to a therapist's office without losing months of mapped commutes.
2. **Debuggability.** When a tester says "the app didn't seem to record yesterday," a Drives list immediately answers whether the app tried and failed, vs. never noticed the drive.
3. **Delight.** Seeing a personal history of "Tuesday morning, 12.4 km, 4 new segments" rewards contribution in a way that a single aggregated number does not.

The reason it's post-MVP: the aggregate overlay already does the "proof of contribution" job well enough for Halifax beta, and a drives list adds a non-trivial amount of UI surface (list screen + detail screen + delete confirmation + empty state + sync states) that we'd rather not defend against Dynamic Type / VoiceOver / edge cases while chasing a TestFlight ship date.

### Data Model

Introduce `DriveSessionRecord` as a first-class SwiftData model, upstream of `ReadingRecord`:

```swift
@Model
final class DriveSessionRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?                   // nil = in progress
    var totalDistanceM: Double
    var readingCount: Int
    var privacyFilteredCount: Int
    var potholesDetected: Int
    var uploadStatus: DriveUploadStatus  // .local, .partiallyUploaded, .fullyUploaded
    var deletedByUser: Bool              // tombstone for local UI; never uploaded

    @Relationship(deleteRule: .cascade, inverse: \ReadingRecord.drive)
    var readings: [ReadingRecord]
}
```

`ReadingRecord` gains a `var drive: DriveSessionRecord?` back-reference.

### Session Lifecycle

```
DrivingDetector.events -> true:
    create DriveSessionRecord(startedAt: now, endedAt: nil)
    SensorCoordinator tags every emitted ReadingRecord with this drive

DrivingDetector.events -> false:
    seal(drive): set endedAt, finalize counters

stale cleanup (every foreground):
    any drive where endedAt == nil && startedAt < now - 2h is force-sealed
    (handles the "phone crashed mid-drive" case — the seal just writes a truthful endedAt)
```

The seal operation is idempotent. If the device reboots mid-drive and the checkpoint system restores in-progress state, we reuse the existing drive ID; otherwise we start fresh and the last drive gets force-sealed on next launch.

### Server Side

**None.** The drives list is purely local. The server only ever sees reading-level records; grouping into drives is a personal view. There is no `/drives/me` endpoint, no drive-level upload, no drive-level delete. This keeps the feature simple and keeps the server ignorant of "this cluster of readings came from a single user-visible session."

An uploaded reading that belongs to a drive retains its `drive` relationship locally. Pruning uploaded readings after 30 days (existing retention rule) leaves the parent drive row intact — the drive keeps its counters (distance, reading count) so the list can still show "Apr 3 · 8.2 km · 12 segments" after the raw readings are gone.

### UI

Reached from `Stats → Recent drives` (new row, below the existing hero). Separate screen, not a sheet, because the list can get long.

```
[ Drives screen ]
Navigation title: Drives

[Today]
- 9:12 am · Home → Work · 12.4 km · Uploaded
- 5:40 pm · Work → Home · 11.8 km · Uploaded

[Yesterday]
- 2:17 pm · 3.2 km · Local only    <-- has the teal local pill

[Earlier this week]
- Monday · 9:05 am · 12.6 km · Uploaded
```

Tapping a row → `DriveDetailScreen`:

- Hero strip: distance, duration, segments touched, potholes detected.
- Mini-map: the drive's path, zoomed to fit, rendered as a single polyline. **No road-quality styling** — this is your personal path, not the community map. If the drive is fully uploaded, the polyline is a muted dark line; if it's still local, it's the same teal styling used on the main map overlay.
- Footer actions: `Open on main map` (centers the MapScreen on the drive's bounding box), `Delete this drive`.

`Delete this drive` triggers a confirmation dialog: "This removes this drive from your device. Any data that was already uploaded stays on the public map — use Delete all local data in Settings to stop contributing going forward."

The dialog wording is intentional: the user deserves to know that deleting locally does not retroactively scrub what was already aggregated into segment averages. See [06-security-and-privacy.md](06-security-and-privacy.md) for the legal framing.

### Empty State

If the user has never driven with the app on, the `Drives` screen shows:

> Drive with RoadSense on to start mapping.  
> Your trips will show up here once you do — no account needed.

Do not show a fake example drive, do not show a "Try a simulated drive" button, do not auto-open the map.

### Privacy Zones Interaction

Drives that are 100% privacy-filtered (`readingCount == 0 && privacyFilteredCount > 0`) still appear in the list with a distinct row treatment:

> 4:22 pm · ~2 km · Inside a privacy zone — nothing was uploaded

This is important: it proves the zone is working. The counter `~2 km` is itself approximate (rounded to the nearest km and drawn only from odometer-style CLLocation distance updates, never from filtered readings) so the row doesn't leak a precise home-route trace.

### Accessibility

- VoiceOver row label: `"April 3rd, 9:12 AM drive. 12.4 kilometres. Uploaded. Double-tap to view route."`
- Dynamic Type: rows reflow vertically at Accessibility 1+ sizes; timestamp stacks above the metadata.
- Delete is not a swipe-only action — it's a button in the detail screen. Swipe-to-delete on the list view is an additive shortcut, never the only path.

### Not In This Version

- Naming drives ("Mom's house", "Grocery run"). Encourages labeling of sensitive locations. Skip.
- Sharing drives. Out of scope; adds a whole sharing surface and is not in the public-interest story for the app.
- Drive-level stats page. The existing Stats screen is about aggregate contribution. A single drive does not need its own "how you compare to other drivers today" frame.
