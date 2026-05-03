# RoadSense NS — Android

Android client for the RoadSense NS road-quality measurement project. Plan and architecture lives in [`docs/implementation/12-android-implementation.md`](../docs/implementation/12-android-implementation.md). Release operations live in [`docs/implementation/14-google-play-readiness.md`](../docs/implementation/14-google-play-readiness.md).

## Status

| Phase | Status | Notes |
|---|---|---|
| A12-1 — Sensor pipeline parity | Landed | `core-sensor` JVM module + iOS-fixture replay |
| A12-2a — Wire-format DTOs + policies | Landed | `core-api` JVM module + iOS JSON parity |
| A12-2b — Room + Retrofit shells | Landed | `:app` module compiles, schema exported, 10 DB tests pass |
| A12-3 — Foreground service + permissions | Not started | Needs an emulator for instrumentation tests |
| A12-4 — Mapbox + Compose UI + manual pothole | Not started | |
| A12-5 — Feedback queue | Not started | |
| A12-6 — Sideload distribution + Play prep | Not started | See `docs/implementation/14-google-play-readiness.md` |

Total tests passing across all modules: **48** (`core-sensor` 16 + `core-api` 22 + `app` 10).

What exists:

- `core-sensor` (pure Kotlin/JVM) — line-for-line ports of the iOS pipeline
- `core-api` (pure Kotlin/JVM) — wire-format DTOs + upload eligibility/backoff/retention policies
- `core-fixtures/` — byte-for-byte mirror of iOS test fixtures, parity-checked
- `:app` Android module — AGP 8.7, AndroidX, Room schema (8 entities + DAOs), Retrofit `BackendClient` over `core-api` DTOs, OkHttp auth interceptor, backup rules excluding the Room DB
- Robolectric tests covering Room schema + the upload-pipeline DAO queries

What does **not** exist yet:

- WorkManager `UploadDrainWorker` (deferred from A12-2b → A12-3 since it ties into the service lifecycle)
- Foreground `CollectionService`, `PermissionsCoordinator`, `SensorBridge` (Android Sensor/Location → `core-sensor`)
- Compose UI, Mapbox, photo capture
- Hilt DI (using manual constructor injection so far — Hilt can land alongside Compose)
- Signing keystores, Play Console wiring

## Prerequisites

- JDK 21 (`brew install --cask temurin@21` or any JDK 21 distribution)
- Gradle 8.10.2+ (or run `gradle wrapper --gradle-version 8.10.2` once to materialize the wrapper)

The Android SDK is **not** required for A12-1. `core-sensor` is JVM-only.

## First-time setup

```sh
cd android
gradle wrapper --gradle-version 8.10.2  # one-time; creates gradlew + gradle-wrapper.jar
git add gradlew gradlew.bat gradle/wrapper/gradle-wrapper.jar
```

The wrapper jar is `.gitignore`d in this PR — commit it in the follow-up so contributors don't need a host gradle install.

## Running the parity tests

```sh
cd android
./gradlew :core-sensor:test
```

Expected output: 4 fixture-replay tests pass, plus the targeted unit tests for `HighPassBiquad`, `RoughnessScorer`, `PotholeDetector`, and `PrivacyZone`.

If a fixture test fails, do **not** edit the expected envelope in `core-fixtures/` to make Android pass — that breaks iOS parity. The fix is to bring the Kotlin port back in line with the iOS Swift code, or to update *both* platforms together.

## Fixture parity

```sh
./scripts/check-android-fixture-parity.sh
```

This must pass in CI. Drift is a planning bug.

## Layout

```
android/
├── settings.gradle.kts        # :core-sensor, :core-api, :app
├── build.gradle.kts
├── gradle.properties          # android.useAndroidX=true
├── gradle/wrapper/
├── core-sensor/               # pure JVM — sensor pipeline (A12-1)
│   └── src/{main,test}/kotlin/ca/roadsense/ns/sensor/...
├── core-api/                  # pure JVM — wire-format DTOs + policies (A12-2a)
│   └── src/{main,test}/kotlin/ca/roadsense/ns/api/...
├── app/                       # Android — Room + Retrofit (A12-2b)
│   ├── build.gradle.kts
│   ├── schemas/               # Room schema export, committed for migrations
│   └── src/main/kotlin/ca/roadsense/ns/{data/room,data/network,…}
└── core-fixtures/             # byte-for-byte copy of iOS test fixtures
```
