# 12 — Android Implementation Plan

*Last updated: 2026-04-27*

Covers: Kotlin/Compose project layout, sensor pipeline port, foreground-service collection, Room persistence, upload pipeline, privacy zones, Mapbox Android, permissions/onboarding, shared-fixture testing, distribution.

This doc plans the Android client described as backlog item B120 in [08-implementation-backlog.md](08-implementation-backlog.md). Android is explicitly post-iOS-MVP: do not start coding it until iOS has at least one stable calibration dataset and a clean run of the upload pipeline against staging Supabase.

## Goals

1. **Wire parity** with iOS: same backend endpoints (`upload-readings`, `pothole-actions`, `pothole-photos`, `feedback`, `tiles`, `stats`), same JSON contracts, same anonymous device-token model. **No Android-specific server changes are allowed.** If something needs the backend to change, that's a planning bug.
2. **Sensor parity within tolerance**: roughness scores produced from a shared CSV fixture must match iOS within ±10% on the same drive. Pothole-detector candidate timestamps must match within ±100 ms.
3. **Distribution that doesn't require Apple paperwork**: from day one, ship as a sideloadable APK to friends with Pixel/Samsung devices so we can collect cross-platform calibration data while iOS TestFlight is still being arranged. Google Play closed testing is the second milestone.
4. **Privacy parity**: privacy zones evaluated on-device before any upload; no precise-location storage that bypasses endpoint trimming; Room database excluded from Android Auto Backup; rotating device tokens hashed server-side.

## Non-goals (first Android release)

- Android Auto / Android for Cars head-unit integration. Useful, but scope creep.
- Wear OS companion. Same.
- Custom ROMs (LineageOS etc.) — we test on stock Pixel + stock Samsung One UI only.
- Media Projection / screen-recording for support reproduction.
- Per-vehicle calibration profiles. iOS hasn't shipped them either.

## Tech stack

- **Minimum Android:** API 33 (Android 13). API 34 (Android 14) requires the `FOREGROUND_SERVICE_LOCATION` permission for our background pattern, so we target API 34 baseline and accept that API 33 users get the same code path with the older runtime grants.
- **Language/toolchain:** Kotlin 2.x, JDK 21, Android Studio Ladybug+, Android Gradle Plugin latest stable.
- **UI:** Jetpack Compose (Material 3). No XML view system except where Mapbox forces it.
- **Persistence:** Room 2.6+ with SQLCipher disabled (we don't store user secrets). Migrations land alongside their feature.
- **Background:** A single foreground `Service` per drive with a persistent notification + WorkManager for upload retries.
- **Networking:** Retrofit 2 + OkHttp 5 (logging interceptor in debug only). Single `BackendClient` mirrors iOS `APIClient`.
- **Maps:** Mapbox Maps SDK for Android, same vector tile source as iOS.
- **Sensors:** `Sensor.TYPE_LINEAR_ACCELERATION` (preferred — gravity already removed by HAL); fallback to `TYPE_ACCELEROMETER` + `TYPE_GRAVITY` with on-device gravity subtraction when LINEAR_ACCELERATION isn't reported. Fused location via Google Play Services `FusedLocationProviderClient`.
- **DI:** Hilt. Manual wiring works at this scale, but Hilt is the documented Jetpack default and the team can onboard against it.
- **Crash + perf:** Sentry Android SDK (matches iOS choice), `sendDefaultPii=false`, coordinate scrubbing in `beforeSend`.

## Project layout

```
android/
├── build.gradle.kts
├── settings.gradle.kts
├── gradle/
├── app/                              # main Android app module
│   ├── src/main/AndroidManifest.xml
│   ├── src/main/kotlin/ca/roadsense/ns/
│   │   ├── App.kt                    # @HiltAndroidApp
│   │   ├── ui/                       # Compose screens (Map, Settings, Drives, Feedback, Onboarding)
│   │   ├── data/
│   │   │   ├── room/                 # @Database, DAOs
│   │   │   ├── store/                # Repository facades that mirror iOS *Store classes
│   │   │   ├── network/              # Retrofit BackendClient, request/response models
│   │   │   └── prefs/                # DataStore Preferences for small flags + feedback queue
│   │   ├── pipeline/                 # Sensor pipeline (port of iOS Pipeline/)
│   │   ├── service/
│   │   │   ├── CollectionService.kt  # foreground service
│   │   │   └── UploadWorker.kt       # WorkManager job
│   │   └── permissions/
│   └── src/test/kotlin/              # JVM unit tests, including shared-fixture replay
│   └── src/androidTest/kotlin/       # instrumentation tests for service + permission flows
├── core-sensor/                      # pure-Kotlin module: roughness scorer, pothole detector
│   ├── build.gradle.kts              # no Android dependencies; runs on JVM
│   └── src/{main,test}/kotlin/...
├── core-fixtures/                    # shared CSV fixtures (symlinked or copied from ios/Tests)
└── README.md
```

The `core-sensor` module is a **pure-Kotlin JVM module**. It has zero Android dependencies and replays the same CSVs the iOS bootstrap target uses. This is the cheapest way to lock in scoring parity — both platforms compile against the same fixtures, both produce the same envelope.

## Sensor pipeline port

The iOS pipeline lives in `ios/Sources/RoadSenseNSBootstrap/Pipeline/`:

- `RoughnessScorer.swift` — high-pass filter then RMS over a window
- `PotholeDetector.swift` — dip-then-spike detection on vertical-G
- `MotionMath.swift` — `verticalAcceleration = dot(userAcceleration, gravity)`
- `ReadingWindowProcessor.swift` — combines GPS + motion windows into upload-ready candidates
- `PrivacyZones.swift` — Haversine distance check before queueing
- `DrivingDetector.swift` — speed/acceleration heuristic for "is this driving?"

Each port maps line-for-line to a Kotlin class in `core-sensor`:

```kotlin
class RoughnessScorer(private val highpassCoefficient: Double = 0.97) {
    fun score(verticalAccelerations: DoubleArray): Double { ... }
}

class PotholeDetector(
    var spikeThresholdG: Double = 1.0,
    var dipThresholdG: Double = -0.3,
    var historyWindowSize: Int = 50,
    var dipLookbackSampleCount: Int = 5,
) {
    fun ingest(verticalAccelerationG: Double, location: LocationSample): PotholeCandidate? { ... }
}
```

Defaults must match iOS exactly. Any threshold change updates both platforms in the same PR; CI fails if the shared-fixture replay diverges.

### Vertical acceleration on Android

iOS gives us `userAcceleration` (gravity removed) and `gravity` as separate vectors and we project one onto the other. Android gives us either:

- `TYPE_LINEAR_ACCELERATION`: gravity-removed vector + we still need a gravity vector for the projection. Use `TYPE_GRAVITY` to get it.
- Fallback: `TYPE_ACCELEROMETER` (raw) + `TYPE_GRAVITY` and subtract gravity manually before the projection.

The math after that is identical. The shared-fixture CSV format in `ios/Tests/RoadSenseNSBootstrapTests/Fixtures/` already records `userAcceleration` and `gravity` as separate columns, so the same fixture drives both tests with no rewrites.

## Background collection

iOS uses `BGTaskScheduler` + `significantLocationChange` to wake the app and resume collection. Android forbids that pattern. The Android equivalent:

- A single foreground `CollectionService` runs while a drive is in progress. It owns the sensor listeners + GPS.
- `FOREGROUND_SERVICE_LOCATION` declared in `AndroidManifest.xml`. Android 14+ requires this.
- A persistent notification (a `NotificationChannel` of `IMPORTANCE_LOW`) shows "Recording road quality — tap to stop". Cannot be dismissed without stopping collection.
- WorkManager handles upload retries with backoff (`Constraints.NetworkType.CONNECTED`). Mirrors iOS `BGAppRefreshTaskRequest` semantics.
- We do **not** use `BroadcastReceiver` to wake on motion. Android dropped that for power reasons; equivalent behavior comes from `ActivityRecognitionApi` + starting the service manually.

User-facing copy will need to acknowledge the persistent notification more directly than iOS does — Android users expect a "why is this in my notification shade?" answer.

## Local persistence (Room)

| iOS (SwiftData) | Android (Room) | Notes |
|---|---|---|
| `ReadingRecord` | `ReadingEntity` | Same fields, same indexes |
| `UploadBatch` | `UploadBatchEntity` | Same retry/backoff state machine |
| `PotholeActionRecord` | `PotholeActionEntity` | Carries the same `pendingUndo`/`pendingUpload`/`failedPermanent` states |
| `PotholeReportRecord` (photo) | `PotholePhotoEntity` | Photo file lives in app-internal storage, not in Room |
| `PrivacyZoneRecord` | `PrivacyZoneEntity` | |
| `DeviceTokenRecord` | `DeviceTokenEntity` | Token rotates on schedule; hashed server-side — same as iOS |
| `DriveSessionRecord` | `DriveSessionEntity` | |
| `UserStats` | `UserStatsEntity` | |
| Feedback queue (UserDefaults) | `data/prefs/FeedbackQueueDataStore.kt` (Proto DataStore) | Trivial volume; matches iOS UserDefaults choice |

Room database excluded from Android Auto Backup via `<application android:fullBackupContent="@xml/backup_rules">` listing the Room file as excluded. Same reasoning as iOS: don't ship raw drive samples through cloud backups.

## Upload pipeline

Single `BackendClient` interface mirroring iOS `APIClient`:

```kotlin
interface BackendClient {
    suspend fun uploadReadings(batch: ReadingBatchRequest): UploadResult
    suspend fun submitPotholeAction(action: PotholeActionRequest): PotholeActionResult
    suspend fun beginPotholePhotoUpload(report: PotholePhotoRequest): PhotoMetadataResult
    suspend fun uploadPotholePhotoBytes(uploadUrl: HttpUrl, file: File): SignedUploadResult
    suspend fun submitFeedback(request: FeedbackSubmissionRequest): FeedbackResult
}
```

Retrofit interface mirrors the JSON shape used in iOS — that contract is already in [03-api-contracts.md](03-api-contracts.md), so this is mechanical. Same `Authorization: Bearer <anon_key>` + `apikey` header pattern.

WorkManager owns scheduling: a `PeriodicWorkRequest` for upload-drain (15-minute heartbeat), a `OneTimeWorkRequest` for drive-end and foreground triggers, both routed through a single `UploadDrainWorker` so the queue is never drained concurrently from two callers. Mirrors `UploadDrainCoordinator` on iOS.

## Privacy zones

iOS uses `CLGeocoder` for the optional reverse-geocode label (best-effort). Android uses `android.location.Geocoder`. Either way, the privacy-zone GEOMETRY is user-set on the map and stored locally — no API call required for the actual filter. Identical to iOS.

The `point inside zone?` check is Haversine; can live in `core-sensor` and ship to both platforms.

## Map rendering

Mapbox Maps SDK for Android. Same `tiles` Edge Function URL as iOS. Same `roadQualityCategory` enum drives the same `match` paint expression. The redesign discussion in [`docs/adr/0001-driving-redesign-rollback.md`](../adr/0001-driving-redesign-rollback.md) applies one-to-one.

The pothole + drive-overlay sources are JSON arrays the iOS `LocalDriveOverlayStyleContent` builds in-memory; the Compose port is direct. We do **not** use `mapbox-compose` (still alpha) — wrap the existing View-based `MapView` with `AndroidView { }` once.

## Permissions + onboarding

| Permission | When asked | What happens if denied |
|---|---|---|
| `ACCESS_FINE_LOCATION` | Onboarding step 1 | Cannot collect — show onboarding's "permissions needed" state, same as iOS |
| `ACCESS_BACKGROUND_LOCATION` | After first drive, like iOS Always upgrade | Continues working when app is foregrounded; passive monitoring doesn't run |
| `ACTIVITY_RECOGNITION` | Onboarding step 2 | Falls back to GPS-only driving detection (same as iOS Motion permission denial) |
| `POST_NOTIFICATIONS` (API 33+) | Just before the first drive | Silent foreground service still runs but the persistent notification is hidden; warn the user this is unusual |
| `CAMERA` | When user taps "Add photo" | Same as iOS: graceful empty state, no auto-prompt at app launch |
| `FOREGROUND_SERVICE_LOCATION` (API 34+) | Manifest-declared, granted at install | Without it, the foreground service crashes on first start; we surface a "reinstall required" message rather than degrading |

The onboarding flow mirrors iOS: brand mark + privacy framing + permission requests + "you'll be asked for one more thing after your first drive" copy. Compose lets us share the BrandVoice strings via a generated Kotlin object from the same source spreadsheet (or just hand-port the strings — quantity is small).

## Distribution

**Phase 1 (week 1):** sideloadable APK signed with a debug-style keystore that we keep in `android/keystores/dev.keystore` (gitignored). Build via `./gradlew :app:assembleRelease` and share the APK by URL. Friends with Pixels/Samsungs install it directly. No Google Play account needed for this. Cuts past the Google Play Console "12 testers × 14 days" requirement entirely.

**Phase 2 (after first 5 internal drives are clean):** Google Play Console, Internal Testing track. ~$25 one-time developer fee. We list ourselves + the friends from Phase 1 as testers; Google Play handles signing.

**Phase 3 (only if iOS launches publicly):** Closed Testing → Production. Not in this plan's scope.

## Testing strategy

- **JVM unit tests** in `core-sensor`: replay the same CSV fixtures the iOS bootstrap tests use. CI fails if any fixture's expected RMS / spike-G envelope is missed.
- **JVM unit tests** in `app`: Room DAOs (`@RunWith(AndroidJUnit4::class)` with Robolectric), repository facades (`*Store` equivalents), upload result translation, queue persistence.
- **Instrumentation tests** in `app`: foreground-service start/stop cycle, permission grant denial flows, deep-link handling, Compose screen smokes via `createComposeRule()`.
- **Manual real-device validation**: same checklist as iOS in [09-internal-field-test-pack.md](09-internal-field-test-pack.md), but appended with Android-specific items (battery saver behavior, doze mode interaction, manufacturer-specific killers like Xiaomi MIUI).
- **CI**: a new GitHub Actions workflow `android-ci.yml` running `./gradlew test` (JVM) and `./gradlew connectedAndroidTest` against an emulator. Add only after the codebase compiles and the JVM tests run locally.

## Phase breakdown

Mapping to the existing TDD pattern (RED tests first, GREEN code second). Each phase is a separate PR.

### A12-1 — Project scaffold + sensor pipeline parity

- **RED**: shared-fixture JVM test that compiles against the iOS pothole-hit and smooth-cruise CSVs and asserts the same expected envelopes the iOS test does
- **GREEN**: empty Android Studio project + `core-sensor` module + Kotlin ports of `RoughnessScorer`, `PotholeDetector`, `MotionMath`
- **Acceptance**: `./gradlew :core-sensor:test` passes against the same fixtures iOS does

### A12-2 — Local persistence + upload pipeline shell (no UI)

- **RED**: instrumentation tests for Room migrations, upload-batch state machine, retry/backoff, queue persistence across process death
- **GREEN**: Room schema + DAOs, Retrofit BackendClient, WorkManager UploadDrainWorker
- **Acceptance**: a Kotlin script that hand-feeds 100 synthetic readings can drain them through Retrofit against local Supabase

### A12-3 — Foreground collection service + permissions

- **RED**: instrumentation tests covering permission grant/deny matrices, the foreground notification appearing, the service surviving an app-task swipe, the service stopping when the user explicitly taps "Stop"
- **GREEN**: `CollectionService`, `PermissionsCoordinator`, onboarding Compose screens
- **Acceptance**: a 10-minute drive on a Pixel 7-class device produces samples matching iOS within tolerance and uploads them automatically

### A12-4 — Map UI + manual pothole + photo capture

- **RED**: Compose screen smokes for Map, Drive list, Settings; UI tests for `Mark pothole` happy path + GPS-stale rejection
- **GREEN**: Mapbox `AndroidView` integration, manual pothole flow, photo capture
- **Acceptance**: the user can drive, mark, photograph, and the result lands on the same public map iOS contributes to

### A12-5 — Feedback path + privacy & counts surface (in-app)

- **RED**: tests for the local feedback queue (port of iOS `FeedbackQueue` + `FeedbackQueueDrainer` to Kotlin)
- **GREEN**: feedback Compose screen, queue persistence via Proto DataStore, drain-on-foreground hook
- **Acceptance**: feedback persists across app restart and drains automatically when network returns

### A12-6 — Sideload distribution + Google Play prep

- **RED**: nothing — distribution is checklist work
- **GREEN**: signed APK pipeline, Play Console listing draft (privacy policy link, content rating questionnaire, screenshots), internal-testing release
- **Acceptance**: a friend with a Pixel can install the APK from a one-click link and complete a drive that uploads

## Shared code strategy

We deliberately do **not** try to share Swift and Kotlin source. Past attempts to use Kotlin Multiplatform for an Apple/Android scoring core land in dependency, build-time, and IDE pain that outweighs the ~1500 lines of pipeline code we'd save.

What we **do** share:

- **CSV fixtures** — copied (not symlinked, to avoid file-system gotchas on Windows contributors) from `ios/Tests/RoadSenseNSBootstrapTests/Fixtures/` into `android/core-fixtures/`. A small CI check asserts the two trees stay byte-for-byte identical.
- **JSON schemas** — defined once in [03-api-contracts.md](03-api-contracts.md), code-generated for both platforms (or hand-written in parallel — at this size, hand-written is fine).
- **Threshold constants** — listed in `docs/product-spec.md`. Both platforms re-declare them; tests in both check that the constants haven't drifted from the spec doc.
- **Onboarding copy** — `BrandVoice.swift` strings are documented as the source of truth; the Android port reads from a sibling `BrandVoice.kt` that's audited in PR review for parity.

## Open questions

- **Vehicle-mount calibration**: iOS hasn't shipped per-vehicle calibration profiles. Android won't either. Re-evaluate after we have ~10 testers and see whether the variance is something tunable or just noise.
- **Battery contracts**: Pixels and Samsungs differ wildly in how aggressively they kill foreground services. We'll learn the per-OEM defaults once Phase 1 sideload starts. The doc will get updated then.
- **Carplay/Android Auto**: explicitly out of scope. Re-open when iOS has 100+ testers and the question becomes "is the dataset rich enough to be useful in-car?"
- **Mapbox-Compose**: track the alpha; switch when stable. The `AndroidView` wrapper is a shim, not a long-term home.

## Hard stop rules (Android)

Stop and reassess if:

- the JVM unit-test fixture replay diverges from iOS by more than 10% on any expected envelope
- a real-device drive produces samples that the existing backend rejects in shapes iOS doesn't (out_of_bounds, low_quality at materially higher rates) — that means the sensor port is wrong, not the backend
- the foreground service is killed by the OS before any drive completes — that's a manufacturer/app-killer issue and means we need per-OEM workarounds before going wider
- battery drain on a Pixel 7-class device is materially worse than iOS during a 30-minute drive (iOS target is 4–6%; if Android exceeds 12%, something is wrong with either the sensor frequency or the location-update model)

## What's NOT in scope for the Android first release

- Web frontend (already exists, platform-agnostic)
- Backend changes (must remain unchanged; if you find one needed, that's a planning bug)
- Watch / wearable companion
- Per-vehicle calibration profiles
- Auto Crash detection / call-911 features
- Multi-language support — ship English-only, mirror iOS's single-locale stance from [`docs/adr/0002-localization-stance.md`](../adr/0002-localization-stance.md)
- Dark theme custom palette (system default is fine for v1)
