# 11 - Android Implementation

*Last updated: 2026-05-25*

Covers: native Android project layout, permissions, activity recognition, foreground collection service, sensor pipeline, local persistence, upload queue, Mapbox UI, testing, and Play release readiness.

This is the Android handoff spec. It assumes the existing Supabase/PostGIS backend and API contract in [03-api-contracts.md](03-api-contracts.md). Android must not require backend schema changes for parity with the passive-collection MVP.

## Status And Scope

Android is a post-iOS follow-on client. The purpose is to double the beta device pool while preserving one public data model:

- Client uploads processed point/window readings; server owns road segment matching.
- Privacy zones, endpoint trimming, and drive-distance accounting happen on-device.
- Public map rendering consumes the same vector tiles and segment-detail endpoints.
- Device tokens follow the same monthly rotation and server-side hash contract.

Android launch is not blocked by feature-for-feature polish with iOS, but it is blocked by a reliable passive collection loop, upload parity, privacy parity, and a real-device battery/thermal pass.

## Platform Decision

**Native Kotlin Android.** Do not use Flutter, React Native, or Kotlin Multiplatform for the MVP Android client.

Rationale:

- Background location, activity recognition, foreground-service behavior, and sensor sampling are the hard parts. Native APIs expose the necessary controls directly.
- Cross-platform UI code would not share the critical sensor/background path.
- The backend/API contract is already platform-neutral JSON + MVT.
- The roughness pipeline is small enough to port and test directly in Kotlin.

## Current Android Platform Notes

The Android rules that matter most for this app:

- Background location must be core functionality, visible to the user, and separately justified. Android 8+ limits passive background location frequency when the app is merely backgrounded; RoadSense therefore uses a visible foreground service during active collection.
- Android 12+ restricts foreground-service starts from the background. A background-started location foreground service requires `ACCESS_BACKGROUND_LOCATION` and must still obey foreground-service type rules.
- Android 14+ requires declaring an appropriate foreground-service type. Active collection uses `location`.
- Android 13+ uses `POST_NOTIFICATIONS` for normal notification-drawer visibility. A foreground service can still be launched without that permission, but the user may only see the foreground-service notice in system task-manager surfaces. RoadSense treats this as degraded because passive collection should be obvious.
- Android activity recognition requires `android.permission.ACTIVITY_RECOGNITION` on Android 10+ and Google Play services. If minSdk is ever lowered below 29, re-check the legacy Google Play services permission path.
- Android 12+ rate-limits motion sensors to 200 Hz unless `HIGH_SAMPLING_RATE_SENSORS` is declared. RoadSense samples at 50 Hz, so the permission is not required for MVP.

Official references to re-check at implementation time:

- Background location: https://developer.android.com/develop/sensors-and-location/location/background
- Activity Recognition Transition API: https://developer.android.com/develop/sensors-and-location/location/transitions
- ActivityRecognitionClient permissions: https://developers.google.com/android/reference/com/google/android/gms/location/ActivityRecognitionClient
- Foreground service types: https://developer.android.com/develop/background-work/services/fgs/service-types
- Foreground-service start restrictions: https://developer.android.com/about/versions/12/foreground-services
- WorkManager/background task selection: https://developer.android.com/develop/background-work/background-tasks
- Notification runtime permission: https://developer.android.com/develop/ui/views/notifications/notification-permission
- Sensors overview and rate limiting: https://developer.android.com/guide/topics/sensors

## Google Tooling Guidance

Google's current AI tooling is relevant for scaffolding and verification, not for product architecture.

Use:

- Android Studio Gemini Agent Mode for bounded implementation tasks: Gradle fixes, Compose screens, Room DAO tests, WorkManager retry tests, and device/logcat iteration.
- Android Studio "Create with AI" only if bootstrapping a throwaway prototype. The production project should follow the module layout below.
- Android Studio device interaction and screenshot tools during UI verification.

References:

- Agent Mode: https://developer.android.com/studio/gemini/agent-mode
- Create a project with AI: https://developer.android.com/studio/gemini/create-a-new-project-with-ai

Do not use:

- Prompt-only app generation as the source of truth for background service, location, or sensor behavior.
- Generated code that changes the API contract, privacy model, or foreground-service policy without an explicit doc update.
- Firebase/App Check as an MVP dependency. Supabase anon key + server rate limits remain the backend contract; Play Integrity can be evaluated post-launch if abuse appears.

## Target And Toolchain

- **Minimum SDK:** Android 10 / API 29. This keeps the background-location permission model consistent and gives access to `PowerManager.getCurrentThermalStatus()`.
- **Target SDK:** current Play-required target at implementation time. As of this spec, assume API 36 if the stable SDK is installed; otherwise start at API 35 and upgrade before closed testing.
- **Language:** Kotlin 2.x.
- **UI:** Jetpack Compose + Material 3.
- **Build:** Gradle Kotlin DSL, Android Gradle Plugin current stable.
- **Package ID:** `ca.roadsense.android`.
- **App name:** `RoadSense NS`.
- **Distribution:** Google Play Internal Testing first, then Closed Testing.

## Dependencies

Use version catalogs in `android/gradle/libs.versions.toml`.

Core dependencies:

- Jetpack Compose BOM, Material 3, Navigation Compose
- AndroidX Lifecycle, ViewModel, Activity Compose
- Kotlin coroutines + Flow
- Kotlinx serialization
- Retrofit + OkHttp, with a small typed API layer
- Room for readings, upload batches, stats, privacy zones, and pending pothole actions/photos
- DataStore Preferences for lightweight settings and token metadata
- WorkManager for upload drains and cleanup work
- Google Play services Location and Activity Recognition
- Mapbox Maps SDK for Android
- Sentry Android, behind the same environment-gated bootstrapping policy as iOS
- CameraX only when implementing pothole-photo capture

Avoid adding a Supabase Android SDK for MVP. The app only needs HTTPS JSON endpoints, MVT tile URLs, and signed upload URLs.

## Project Layout

Create `android/` as an independent Gradle project:

```text
android/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle/libs.versions.toml
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/ca/roadsense/android/
│       │   ├── RoadSenseApplication.kt
│       │   ├── AppGraph.kt
│       │   ├── MainActivity.kt
│       │   ├── app/
│       │   ├── collection/
│       │   ├── data/
│       │   ├── location/
│       │   ├── map/
│       │   ├── network/
│       │   ├── permissions/
│       │   ├── photos/
│       │   ├── privacy/
│       │   ├── sensors/
│       │   ├── ui/
│       │   └── work/
│       └── res/
├── core/
│   ├── domain/
│   │   └── src/main/java/ca/roadsense/domain/
│   └── testfixtures/
│       └── src/main/resources/fixtures/
└── README.md
```

Start with `:app`, `:core:domain`, and `:core:testfixtures`. Add more modules only if compile times or ownership boundaries justify it.

### Dependency Injection

Use a small manual `AppGraph` for MVP. Hilt is acceptable later, but it should not be introduced before the collection and upload seams are clear.

`AppGraph` owns:

- Room database and DAOs
- DataStore
- API client
- repositories/stores
- permission checker
- activity recognition client wrapper
- fused location wrapper
- sensor sampler
- upload scheduler
- Sentry bootstrapper

Constructor injection remains the pattern inside classes. Tests can instantiate fakes directly.

## Configuration

Build variants:

| Variant | Purpose |
|---|---|
| `localDebug` | local Supabase / local Railway-compatible API |
| `stagingDebug` | staging backend, debug signing |
| `stagingRelease` | Play Internal Testing |
| `productionRelease` | closed/open testing and public release |

Config values:

- `API_BASE_URL`
- `SUPABASE_ANON_KEY`
- `MAPBOX_ACCESS_TOKEN`
- `MAPBOX_STYLE_URL`
- `SENTRY_DSN`
- `APP_ENV`

Use Gradle `buildConfigField` for non-secret public config. Do not commit secret tokens. The Supabase anon key and Mapbox public token are shippable client config, but still keep environment-specific values out of source when possible.

## Manifest

Required permissions:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
```

Application/service requirements:

```xml
<application
    android:allowBackup="false"
    android:usesCleartextTraffic="false">

    <service
        android:name=".collection.CollectionForegroundService"
        android:exported="false"
        android:foregroundServiceType="location" />

    <receiver
        android:name=".collection.ActivityTransitionReceiver"
        android:exported="false" />
</application>
```

Do not declare `HIGH_SAMPLING_RATE_SENSORS` for MVP unless the sampling target changes above 200 Hz.

## Permission Strategy

### First Launch

Request only the permissions needed for foreground collection and browsing:

1. Fine location, with explicit copy that precise location is required for road matching.
2. Activity recognition.
3. Notifications, because active collection should be visible in the notification drawer on Android 13+.

If the user grants approximate location only, map browsing remains available but uploadable collection is disabled. Show a settings action to enable precise location.

### First Successful Foreground Drive

After a successful foreground collection session, ask for background collection:

- Explain that passive mapping only works when RoadSense can start recording while the app is not open.
- Send the user to the Android location settings screen for "Allow all the time" on versions where background location cannot be requested inline.
- If the user declines, the app remains foreground-only and the collection notification is only started from an in-app action.

### Degraded Permission States

| State | Behavior |
|---|---|
| Fine location denied | No collection. Map browsing works. Show permission repair screen. |
| Approximate only | No uploadable readings. Segment matching is not trustworthy. |
| Background location denied | Foreground-only collection. Activity transition events can update state but must not attempt background collection. |
| Activity recognition denied | Use conservative foreground-only GPS heuristic. Do not open background drive sessions from speed alone. |
| Notifications denied | Foreground user-started collection may still run where the OS permits it, but passive background collection stays disabled for MVP because the persistent notification is not visible enough. Show a notification repair CTA. |
| Battery optimization restricted by OEM | Show a settings hint only after a real collection interruption is observed. Do not ask on first launch. |

## Background Collection Architecture

### High-Level Flow

```text
App launch
  -> PermissionRepository evaluates collection readiness
  -> ActivityRecognitionClient registers IN_VEHICLE enter/exit transitions
  -> IN_VEHICLE enter received
  -> CollectionStartPolicy checks permissions, user pause state, thermal/battery state
  -> CollectionForegroundService starts with location foreground-service type
  -> FusedLocationProviderClient emits 1 Hz location
  -> SensorManager emits 50 Hz motion samples
  -> SensorCoordinator builds reading windows, filters privacy/quality, persists locally
  -> UploadScheduler enqueues WorkManager drain opportunistically
```

### Activity Recognition

Use `ActivityRecognitionClient.requestActivityTransitionUpdates(...)` with:

- `DetectedActivity.IN_VEHICLE` enter
- `DetectedActivity.IN_VEHICLE` exit

Receiver behavior:

- On enter, try to start `CollectionForegroundService` only if background location is granted and the user has enabled passive monitoring.
- On exit, signal the active service to seal the drive session after a grace period.
- If permissions are missing, record a local "blocked reason" and surface it next time the app opens.

Activity recognition is a trigger, not proof. The service still requires plausible GPS movement before it emits uploadable readings.

### Foreground Service

`CollectionForegroundService` owns active sensor and location subscriptions. It must:

- Call `startForeground(...)` immediately with a clear persistent notification.
- Use notification actions for Pause and Stop.
- Stop itself when driving ends, thermal state is serious/critical, permissions are revoked, or the user pauses collection.
- Persist checkpoint state at least every 60 seconds while collecting.
- Avoid long blocking work on the main thread.

Notification copy:

- Title: `RoadSense is mapping roads`
- Body while active: `Collecting road roughness while you drive`
- Body while paused: `Collection paused`

Do not use WorkManager for active sensor collection. WorkManager is for upload drains, cleanup, and retry.

### Location Sampling

Use `FusedLocationProviderClient.requestLocationUpdates(...)`.

Default active-drive request:

- interval: 1000 ms
- minimum update interval: 500 ms
- priority: high accuracy while collection is active
- wait for accurate location: true when available
- max update delay: 2000 ms

Low power mode:

- interval: 3000 ms
- minimum update interval: 1500 ms
- continue local drive distance accounting
- emit fewer uploadable windows only if quality gates still pass

Location quality gates:

- discard uploadable reading if `accuracy > 20m`
- discard uploadable reading if speed `< 15 km/h` or `> 160 km/h`
- ignore impossible local-distance jumps
- keep stop-and-go distance only after an active in-vehicle drive has started

### Motion Sampling

Use `SensorManager` at 50 Hz:

- primary acceleration source: `TYPE_LINEAR_ACCELERATION`
- orientation source: `TYPE_ROTATION_VECTOR`
- fallback: `TYPE_ACCELEROMETER` + `TYPE_GRAVITY`

The pipeline must produce a normalized vertical acceleration value independent of phone orientation:

1. Convert Android sensor timestamps from nanoseconds to monotonic seconds.
2. Use rotation vector to transform linear acceleration into Earth/device-world coordinates.
3. Take vertical acceleration in g units.
4. Apply the same high-pass/filtering and RMS window rules as iOS.
5. Build observation windows with midpoint, start/end coordinates, distance, duration, sequence index, roughness RMS, speed, heading, GPS accuracy, pothole flag, and recorded timestamp.

If rotation vector is unavailable, use gravity-vector projection and mark the sample path as `orientation_fallback` in local diagnostics. Do not send diagnostics to the backend in MVP.

## Sensor Pipeline Components

Keep the domain pipeline pure Kotlin where possible:

| Component | Module | Responsibility |
|---|---|---|
| `MotionSample` | `:core:domain` | monotonic timestamp, acceleration vector, orientation/gravity metadata |
| `LocationSample` | `:core:domain` | lat/lng, speed, heading, accuracy, wall-clock timestamp |
| `MotionMath` | `:core:domain` | projection, unit conversion, vector helpers |
| `HighPassBiquad` | `:core:domain` | same coefficients/behavior as iOS |
| `DrivingHeuristic` | `:core:domain` | GPS-only degraded foreground heuristic |
| `QualityFilter` | `:core:domain` | speed, accuracy, thermal gates |
| `PrivacyZoneFilter` | `:core:domain` | local-only privacy filtering |
| `ReadingBuilder` | `:core:domain` | 50m windows, midpoint/start/end metadata |
| `ReadingWindowProcessor` | `:core:domain` | roughness score + pothole detection |
| `SensorCoordinator` | `:app` | orchestrates Android services, stores, and upload triggers |

Port iOS tests before or alongside implementation. The expected output for shared fixtures should match within documented tolerance.

## Privacy And Local Data

Android must implement the same privacy defaults as iOS:

- Trim the first/last 60 seconds of every drive.
- Trim readings within 300m of drive start/end coordinates.
- Drop readings inside user privacy zones.
- Store privacy-zone centers with randomized 50-100m offset.
- Never upload privacy-zone centers.
- If a full drive is filtered, keep a local notice and do not upload readings.

Local persistence:

- Use Room for structured local data.
- Use DataStore for user settings and token rotation metadata.
- Set `android:allowBackup="false"`.
- Do not store raw continuous tracks beyond the current drive/checkpoint path needed to trim and recover.
- Retain processed local readings for 30 days or 100 MB, whichever comes first.

Room entities:

- `ReadingEntity`
- `UploadBatchEntity`
- `PrivacyZoneEntity`
- `UserStatsEntity`
- `DeviceTokenEntity`
- `DriveSessionEntity`
- `SensorCheckpointEntity`
- `PotholeActionEntity`
- `PotholePhotoEntity`

## Upload Queue

Use the same API contract as iOS:

- `POST /upload-readings`
- `GET /tiles/{z}/{x}/{y}.mvt`
- `GET /segments/{id}`
- `GET /stats`
- `POST /pothole-actions`
- `POST /pothole-photos` when photo capture is implemented

Upload behavior:

- Client generates UUIDv4 `batch_id`.
- Retries must reuse the same `batch_id`.
- Batch size max is 1000 readings.
- Network error/5xx uses exponential backoff: 1s, 2s, 4s, 8s, 16s, max 5 attempts.
- 429 respects `Retry-After`.
- 400 validation errors are permanent failures and surface in Settings.
- Successful upload marks batch succeeded and schedules retention cleanup.

WorkManager:

- `UploadDrainWorker`: one-time unique work, network connected constraint.
- `RetentionCleanupWorker`: periodic daily work.
- `HealthPingWorker`: optional staging-only smoke, not production telemetry.

Do not require Wi-Fi for MVP uploads.

## API Client Details

Headers:

- `Content-Type: application/json` for JSON requests.
- `Authorization: Bearer <anon>`.
- `apikey: <anon>` for Supabase compatibility.

Upload body platform fields:

- `client_app_version`: `${versionName} (${versionCode})`
- `client_os_version`: `Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})`

The DTO layer must ignore unknown response fields.

## Mapbox Android Implementation

Map view:

- Use Mapbox Maps SDK for Android.
- Use the same backend MVT endpoint and source-layer names:
  - `segment_aggregates`
  - `potholes`
- Use data-driven line styling from `category` and `confidence`.
- Render low-confidence segments less prominently.
- Render local unuploaded readings from Room as a dashed teal overlay.
- On segment tap, call `GET /segments/{id}` and show the Compose bottom sheet.

Offline tiles:

- Defer automatic offline packs until the live map and upload loop are stable.
- If implemented before Android beta, match iOS: zoom 10-16 for the user's municipality.

## UI Surfaces

Use Compose + Material 3. Mirror the iOS information architecture while using Android interaction norms.

Required MVP screens:

- Onboarding and permission repair
- Map shell with recording status, contribution card, legend, stats/settings entry points
- Segment detail bottom sheet
- Stats
- Settings
- Privacy zones editor

Parity features:

- Passive monitoring toggle
- Pending uploads count
- Force upload drain action
- Delete local data
- Background-location repair CTA
- Low-confidence map styling
- Local-drive overlay

Pothole actions:

- Implement `Mark pothole` after passive collection is stable.
- Implement `Still there` / `Looks fixed` from segment/pothole detail if the iOS flow is already active.
- Photo capture can follow with CameraX and the existing `POST /pothole-photos` signed-upload contract.

## Design System

Use [design-tokens.md](../design-tokens.md) as the canonical token map.

Create:

- `ui/theme/Color.kt`
- `ui/theme/Type.kt`
- `ui/theme/Spacing.kt`
- `ui/theme/Shape.kt`

Android should share the semantic roughness ramp and confidence styling with iOS/web. Do not invent a separate Android color scale.

## Thermal, Battery, And OEM Behavior

Thermal:

- Use `PowerManager.getCurrentThermalStatus()` on API 29+.
- Pause active collection at serious/critical thermal states.
- Record a local notice; do not upload thermal diagnostics.

Battery:

- Use `BatteryManager`/sticky battery intent.
- At low power/battery-saver state, reduce GPS to 3s and keep accelerometer at 25 Hz if needed.
- Pause only if real-device testing proves collection harms the device or OS kills the service repeatedly.

OEM restrictions:

- Do not ask users to disable battery optimization on first launch.
- If collection repeatedly stops on a specific OEM while permissions are correct, show a targeted help surface.

## Testing Strategy

### JVM Unit Tests

Run in CI for every PR:

- `MotionMath`
- `HighPassBiquad`
- `QualityFilter`
- `PrivacyZoneFilter`
- `ReadingBuilder`
- `ReadingWindowProcessor`
- `PotholeDetector`
- `UploadPolicy`
- `UploadRequestFactory`
- `UploadResponseParser`
- `DeviceTokenManager`
- `DriveEndpointTrimmer`
- `DrivingHeuristic`

Use the same CSV fixture corpus as iOS. Expected outputs must live beside fixtures and be reviewed when thresholds change.

### Android Integration Tests

Use instrumented tests for:

- Room migrations and DAO queries
- DataStore settings/token persistence
- Permission readiness state machine
- WorkManager unique upload work
- Foreground-service notification actions
- Mapbox-free UI shell smoke tests using fake map content

Avoid making Mapbox startup a prerequisite for deterministic UI tests.

### Sensor Harness

Create an Android harness equivalent to `RoadSenseNSSimHarness`:

```text
CSV fixture
  -> fake MotionSampler at 50 Hz
  -> fake LocationSampler at 1 Hz
  -> real pure Kotlin pipeline
  -> emitted reading windows
  -> JSON assertion
```

The Android harness must support:

- pothole hit
- smooth cruise
- privacy-zone recovery
- thermal rejection
- at least one real Android-captured drive before closed testing

### Real-Device Field Tests

Minimum device matrix before Play closed testing:

- Pixel 7-class or newer
- Samsung Galaxy S-series or A-series
- One older Android 10/11 device if available

Required field runs:

1. Foreground-only drive, 20+ minutes.
2. Passive background start from activity recognition, 20+ minutes.
3. Offline drive -> online upload drain.
4. Privacy-zone drive-through.
5. Battery-saver drive.
6. Thermal/long-drive observation on dashboard mount.

Acceptance evidence:

- accepted readings visible in staging DB
- map tile reflects uploaded aggregate
- local pending queue drains
- battery drain measured
- foreground notification actions work
- no raw privacy-zone center or trimmed endpoint readings uploaded

## CI

Add manual workflow first:

- Gradle build
- JVM unit tests
- Android lint
- Detekt or ktlint
- Room schema export check

Do not add always-on emulator CI until the first Android app shell is stable. Emulator jobs are slower and should cover only deterministic smoke tests.

## Play Release Readiness

Play setup:

- Create app with package `ca.roadsense.android`.
- Configure Play App Signing.
- Create Internal Testing track.
- Complete Data Safety form to match actual data flow.
- Prepare background location declaration with a short demo video showing passive road mapping and the persistent notification.
- Verify developer identity/account requirements before closed/open testing.

Release criteria:

1. App collects, processes, and uploads at least 1 hour of driving on 2+ Android devices.
2. Accepted Android readings match backend validation and assign to road segments at the same >= 95% valid-reading target as iOS.
3. Shared fixture outputs match iOS within +/-10% roughness score tolerance.
4. Battery drain is < 20%/hr on a Pixel 7-class device.
5. Foreground service notification is always visible during active background collection and has working Pause/Stop actions.
6. Privacy filtering passes the same endpoint/zone tests as iOS.
7. Play Data Safety and background-location disclosure match implementation.

## Suggested Build Order

1. Gradle project + empty Compose shell.
2. Pure Kotlin domain pipeline port and fixture tests.
3. Permission/readiness state machine.
4. Room schema and stores.
5. Upload DTOs, request factory, parser, and WorkManager drain.
6. Activity recognition + foreground service + location/sensor wrappers.
7. SensorCoordinator integration.
8. Mapbox vector tile rendering and segment detail.
9. Settings/stats/privacy zones.
10. Real-device field pack and Play internal testing.

## Hard Stop Rules

Stop and reassess if:

- Android needs an API contract change that would break iOS.
- Background collection cannot start reliably from activity recognition with documented permissions.
- Battery drain exceeds 25%/hr after the low-power sampling strategy is applied.
- Approximate-location devices appear to upload readings.
- Foreground-service notification can be dismissed while active collection continues.
- Shared fixture scores diverge from iOS by more than 10% without a documented sensor-platform explanation.
