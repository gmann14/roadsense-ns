# RoadSense NS — Android

Android client for the RoadSense NS road-quality measurement project. Plan and architecture lives in [`docs/implementation/12-android-implementation.md`](../docs/implementation/12-android-implementation.md). Release operations live in [`docs/implementation/14-google-play-readiness.md`](../docs/implementation/14-google-play-readiness.md).

## Status

**Phase A12-1 — Sensor pipeline parity.** Landed.
**Phase A12-2 — Wire-format DTOs + upload policies.** Partial; see below.

What exists:

- `core-sensor` (pure Kotlin/JVM) — line-for-line ports of the iOS pipeline (`RoughnessScorer`, `PotholeDetector`, `QualityFilter`, `ReadingBuilder`, `ReadingWindowProcessor`, `SensorCheckpoint`, `MotionMath`, `HighPassBiquad`, `PrivacyZone`, `SensorFixture`, `SensorFixtureRunner`)
- `core-api` (pure Kotlin/JVM) — wire-format DTOs (`UploadReadingsRequest/Response`, `UploadErrorEnvelope`), `UploadCodec` (sorted-keys JSON, ISO-8601 dates, lowercase UUIDs to match iOS), `Endpoints`, `AppConfig`, `UploadEligibilityPolicy`, `UploadPolicy`, `RetentionPolicy`
- `core-fixtures/` — byte-for-byte mirror of iOS test fixtures, parity-checked by `scripts/check-android-fixture-parity.sh`
- JVM unit tests covering both modules; run with `./gradlew test`

What does **not** exist yet (A12-2 remainder + later phases):

- the `:app` Android module with AGP (Room schema, DAOs, Retrofit BackendClient wrapper, WorkManager `UploadDrainWorker`)
- Hilt DI, Compose UI, Mapbox, foreground service
- signing keystores or Play Console wiring

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
├── settings.gradle.kts        # :core-sensor + :core-api
├── build.gradle.kts
├── gradle.properties
├── gradle/wrapper/            # wrapper jar materialized via `gradle wrapper`
├── core-sensor/               # pure JVM — sensor pipeline (A12-1)
│   ├── build.gradle.kts
│   └── src/{main,test}/kotlin/ca/roadsense/ns/sensor/...
├── core-api/                  # pure JVM — wire-format DTOs + policies (A12-2)
│   ├── build.gradle.kts
│   └── src/{main,test}/kotlin/ca/roadsense/ns/api/...
└── core-fixtures/             # byte-for-byte copy of iOS test fixtures
```
