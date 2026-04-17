# 01 — iOS Implementation

*Last updated: 2026-04-17*

Covers: Xcode project layout, sensor pipeline, scoring, persistence, upload queue, map/UI, background execution, and permissions.

Prereqs from [product-spec.md](../product-spec.md) that we don't re-derive here: driving detection via `CMMotionActivityManager`, 50Hz accel, 1Hz GPS, 50m segments server-side, 500m privacy zones.

## Deployment Target & Tooling

- **Minimum iOS:** 17.0 — keeps SwiftData simple, covers 95%+ of active iPhones by TestFlight date. Drop to 16 only if a tester hits this.
- **Language/toolchain:** Swift 5.9+, Xcode 15.3+, SwiftUI primary, UIKit where needed for Mapbox bridging
- **Package management:** Swift Package Manager only (no CocoaPods, no Carthage)
- **Bundle ID placeholder:** `ca.roadsense.ios` — update after name decision
- **Architectures:** `arm64` device only; simulator support for development. No `x86_64` — Rosetta-only dev machines must run Xcode 15 natively.

## Xcode Project Layout

```
RoadSenseNS/
├── RoadSenseNS.xcodeproj
├── RoadSenseNS/                       # app target
│   ├── App/
│   │   ├── RoadSenseNSApp.swift       # @main, DI wiring
│   │   ├── AppDelegate.swift          # only for bg launch + silent notif
│   │   └── AppConfig.swift            # env-injected config (API URL, Mapbox key)
│   ├── Features/
│   │   ├── Onboarding/                # views + viewmodel
│   │   ├── Map/                       # MapboxMapView wrapper, overlays
│   │   ├── SegmentDetail/
│   │   ├── Settings/
│   │   ├── PrivacyZones/
│   │   └── Stats/
│   ├── Sensors/
│   │   ├── DrivingDetector.swift      # CMMotionActivityManager wrapper
│   │   ├── LocationService.swift      # CLLocationManager wrapper
│   │   ├── MotionService.swift        # CMDeviceMotion wrapper
│   │   ├── ThermalMonitor.swift       # ProcessInfo.thermalState
│   │   └── PermissionManager.swift    # centralizes all permission prompts
│   ├── Pipeline/
│   │   ├── SensorCoordinator.swift    # orchestrates driving lifecycle
│   │   ├── ReadingBuilder.swift       # assembles 50m-of-travel windows
│   │   ├── RoughnessScorer.swift      # signal processing → rms
│   │   ├── PotholeDetector.swift      # spike detection
│   │   ├── PrivacyZoneFilter.swift    # on-device reading drop
│   │   └── QualityFilter.swift        # speed/accuracy gates
│   ├── Persistence/
│   │   ├── ModelContainerProvider.swift
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
- `locationManager.allowsBackgroundLocationUpdates = true`
- `locationManager.pausesLocationUpdatesAutomatically = false`
- `locationManager.showsBackgroundLocationIndicator = true` (required for App Store)
- Register for `significantLocationChange` at app launch via `locationManager.startMonitoringSignificantLocationChanges()` — this is the relaunch mechanism after force-quit or memory kill. **Requires `.authorizedAlways`** — with `.authorizedWhenInUse` it silently does nothing.
- On `locationManager(_:didUpdateLocations:)` after a significant-change-triggered relaunch, check if driving activity is `.automotive` and if so, resume normal collection

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
    var status: UploadStatus        // .pending, .inFlight, .succeeded, .failedPermanent
    var readingCount: Int
    var firstErrorMessage: String?
}

@Model
final class PrivacyZone {
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

**Retention:** FIFO-prune `ReadingRecord` where `uploadedAt != nil` and older than 30 days. Separate `BGProcessingTask` enforces 100MB cap.

**Device token rotation:** At app launch, check `DeviceTokenRecord.expiresAt`. If expired, create new one. `APIClient` reads the latest token for the `device_token` field on each request.

## Upload Queue

Runs on app foreground + on `BGAppRefreshTask` (registered for frequent invocation — iOS ultimately decides cadence).

```
every queue tick:
  pending_readings = ReadingRecord where uploadBatchID == nil LIMIT 1000
  if count < 100 AND !user.wifiOnlyOverride:
      skip this tick  (don't upload small trickles on cell)
  batch_id = UUID()
  associate readings with batch_id (writes uploadBatchID)
  attempt upload
     on 200: mark uploadedAt, trigger local map overlay refresh
     on 400 (validation error): mark batch failed_permanent, log, stop retrying
     on 429 (rate limited): back off 60s + jitter
     on 5xx / network error: exponential backoff (1s, 2s, 4s, 8s, 16s), max 5 attempts
     after 5 failures: set status = .failedPermanent, surface in Settings screen
```

**Idempotency:** `batch_id` is the dedup key server-side. Client retries send the same batch_id; the server returns 200 with `{already_processed: true}` on re-submit.

**WiFi detection:** `NWPathMonitor` publishes `path.isExpensive` (true on cellular/tethered) and `path.status`. If `isExpensive == true` **and** `user.allowCellularUpload == false`, defer the batch until the next non-expensive path. This also correctly defers when the user is on a personal hotspot, which we treat as cellular.

**Batch size:** 1000 readings max per request (matches API contract). For ~50m-per-reading, that's ~50km of driving per batch.

## Privacy Zone Implementation

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

### Edge Case — Entire Commute Inside Zones

`ReadingBuilder` tracks dropped windows per session. If in a single session `dropped_count > 10 && emitted_count == 0`, show a non-blocking banner: "Privacy zones cover your recent route — no data was contributed. Tap to review zones."

## Permission Flow (UI Timing)

Matches product-spec progressive flow, concrete state machine:

```
state: onboarding
  screen 1: "what this app does"
  screen 2: "we need When-In-Use location + Motion" → show combined rationale
     tap "Enable" → CLLocationManager.requestWhenInUseAuthorization()
                 → CMMotionActivityManager.activityTypes triggers Motion prompt on first query
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

## Mapbox Integration

### Setup

- Mapbox Maps SDK v11+ via SPM: `https://github.com/mapbox/mapbox-maps-ios.git`
- API key in `AppConfig`, loaded from a build-time `.xcconfig` that's `.gitignore`'d
- Tile source: custom vector tiles from our backend (not Mapbox hosted) — see [02-backend-implementation.md](02-backend-implementation.md)

### Style Stack

```
┌─ Base style (Mapbox Streets v12, dark mode variant)
├─ Road quality overlay layer
│   source: vector, url: https://api.roadsense.ca/tiles/{z}/{x}/{y}.mvt
│   source-layer: "segment_aggregates"
│   type: line
│   paint:
│     line-color: interpolate on roughness_score
│       0.3 → #4ade80  (green)
│       0.6 → #fbbf24  (yellow)
│       1.0 → #f97316  (orange)
│       1.5 → #dc2626  (red)
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
│   type: circle; data-driven radius based on magnitude
├─ Local "your drives" overlay (GeoJSON from SwiftData)
│   line-dasharray: [2, 2]
│   distinguishes user's unprocessed data pre-aggregation
```

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

### Screens (condensed list)

- **OnboardingFlow** — 3 screens, no skip
- **MapScreen** — full-bleed Mapbox view, floating "Your contributions" card, overlay for recording indicator
- **SegmentDetailSheet** — `.sheet` presentation, scrollable; loads from `GET /api/segments/{id}`
- **SettingsScreen** — privacy zones, upload controls, battery saver, data management, about
- **PrivacyZoneEditor** — map picker + radius slider
- **AboutScreen** — how it works (plain language), privacy policy link, open-source link

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

## Open Questions for iOS

- **[OPEN] Should first-drive detection block the privacy-zone setup prompt?** Lean: let the user skip zone setup; prompt again after first drive when they see their data on the map.
- **[OPEN] Dynamic Type scaling test coverage scope.** Covered under [04-testing-and-quality.md](04-testing-and-quality.md); revisit UI lock on headers that don't scale gracefully.
- **[OPEN] Do we need haptic feedback for pothole detection?** Tempting but violates "passive collection" ethos. Default: no.
