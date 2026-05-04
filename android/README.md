# RoadSense NS — Android

Android client for the RoadSense NS road-quality measurement project. Plan and architecture lives in [`docs/implementation/12-android-implementation.md`](../docs/implementation/12-android-implementation.md). Release operations live in [`docs/implementation/14-google-play-readiness.md`](../docs/implementation/14-google-play-readiness.md).

## Status

| Phase | Status | Notes |
|---|---|---|
| A12-1 — Sensor pipeline parity | Landed | `core-sensor` JVM module + iOS-fixture replay |
| A12-2a — Wire-format DTOs + policies | Landed | `core-api` JVM module + iOS JSON parity |
| A12-2b — Room + Retrofit shells | Landed | `:app` module compiles, schema exported, 10 DB tests pass |
| A12-3 — Foreground service + permissions | Partial | Sensor/location bridges, permissions snapshot, CollectionPipeline, CollectionService skeleton, UploadDrainCoordinator all landed and tested. Real sensor + GPS subscription inside the service still stubbed pending an emulator pass. |
| A12-4 — Mapbox + Compose UI + manual pothole | Not started | Genuinely UI work — pair with a designer in Android Studio |
| A12-5 — Feedback queue | Not started | |
| A12-6 — Sideload distribution + Play prep | Not started | See `docs/implementation/14-google-play-readiness.md` |

Total tests passing across all modules: **61** (`core-sensor` 16 + `core-api` 22 + `app` 23).

What exists:

- `core-sensor` (pure Kotlin/JVM) — line-for-line ports of the iOS pipeline
- `core-api` (pure Kotlin/JVM) — wire-format DTOs + upload eligibility/backoff/retention policies
- `core-fixtures/` — byte-for-byte mirror of iOS test fixtures, parity-checked
- `:app` Android module — AGP 8.7, AndroidX, Room schema (8 entities + DAOs), Retrofit `BackendClient` over `core-api` DTOs, OkHttp auth interceptor, backup rules excluding the Room DB
- Robolectric tests covering Room schema + the upload-pipeline DAO queries

What does **not** exist yet:

- Real sensor + GPS subscription inside `CollectionService` (the skeleton + notification + manifest are landed; the `SensorManager.registerListener` / `FusedLocationProviderClient` calls are stubbed pending an emulator validation pass)
- Final `UploadDrainWorker` wiring (the worker class exists; the service-locator hookup that constructs `UploadDrainCoordinator` lands with Hilt in A12-4)
- Compose UI, Mapbox, photo capture (A12-4)
- Feedback queue (A12-5)
- Signing keystores, Play Console wiring (A12-6)

## Prerequisites

- **JDK 21** (`brew install openjdk@21`). Set `JAVA_HOME` to `/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`.
- **Android SDK** — Platform 34, Build-Tools 34, Platform-Tools. Install via `brew install --cask android-commandlinetools`, then `sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools"`. Set `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`.
- **Android Studio** (Ladybug 2024.1+ recommended) — `brew install --cask android-studio`. Required only for UI work and instrumentation tests; CLI builds and JVM/Robolectric tests work without it.
- **Emulator + system image** (only for instrumentation tests) — `sdkmanager "emulator" "system-images;android-34;google_apis_playstore;arm64-v8a"` on Apple Silicon.

JDK 21 is required because Gradle 8.10 doesn't support JDK 25 (the brew default). If you already have a newer JDK, install JDK 21 alongside and point `JAVA_HOME` at it.

For convenience, add this to `~/.zshrc` so `./gradlew` and `sdkmanager` work in any new shell:

```sh
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$PATH"
```

## Opening in Android Studio

1. **File → Open**, pick `android/build.gradle.kts` (the project root, not the repo root).
2. When prompted "Trust project?", trust it.
3. Studio will sync Gradle and download AGP-managed dependencies on first open (~3–5 min).
4. To run unit tests, right-click `core-sensor`, `core-api`, or `app/src/test` and pick **Run Tests**.
5. To run instrumentation tests, you'll need an AVD running (see below) — right-click `app/src/androidTest` and **Run** (none defined yet — A12-3 follow-on adds them).

If Studio asks about `local.properties`, it will write `sdk.dir=/opt/homebrew/share/android-commandlinetools` automatically. That file is gitignored.

## Creating an AVD (for instrumentation tests)

A `pixel7-api34` AVD already exists locally if you ran the setup above. List with `avdmanager list avd`. Boot it with:

```sh
$ANDROID_HOME/emulator/emulator -avd pixel7-api34
```

To recreate from scratch (CLI, no Studio needed):

```sh
echo "no" | avdmanager create avd \
    --name pixel7-api34 \
    --package "system-images;android-34;google_apis_playstore;arm64-v8a" \
    --device pixel_7
```

Or do it through Studio's **Device Manager** with the same image.

## Running tests from the CLI

```sh
cd android
./gradlew test                    # JVM unit tests across all modules (61 tests)
./gradlew :core-sensor:test       # iOS-fixture parity only (16 tests)
./gradlew :core-api:test          # wire-format parity + policies (22 tests)
./gradlew :app:testDebugUnitTest  # Robolectric DAO + pipeline tests (23 tests)
./gradlew :app:assembleDebug      # build the debug APK
```

If a fixture test fails, do **not** edit the expected envelope in `core-fixtures/` to make Android pass — that breaks iOS parity. The fix is to bring the Kotlin port back in line with the iOS Swift code, or to update *both* platforms together.

## Environment configuration

Mirrors the iOS xcconfig pattern (see `ios/Config/RoadSenseNS.*.xcconfig`).
Each environment has a properties file in `android/config/`:

| Environment | Committed defaults | Local override |
|---|---|---|
| local | `config/local.env.properties` | `config/local.env.secrets.properties` (gitignored) |
| staging | `config/staging.env.properties` | `config/staging.env.secrets.properties` (gitignored) |
| production | `config/production.env.properties` | `config/production.env.secrets.properties` (gitignored) |

Committed values:

- `API_BASE_URL` — local: `http://10.0.2.2:54321` (emulator → host loopback); staging: the Railway URL iOS uses; production: `https://roadsense.ca`
- `SUPABASE_ANON_KEY` — staging is the same key committed in iOS (anon keys are public by design); local + production have placeholders for now
- `MAPBOX_ACCESS_TOKEN` — placeholder in every committed file. Override per environment in the secrets file.
- `SENTRY_DSN` — empty in committed files; goes in secrets if you want crash reports.
- `ENABLE_POTHOLE_PHOTOS` — matches iOS (false in staging, true elsewhere).

To run a real local build with your real Mapbox token:

```sh
echo "MAPBOX_ACCESS_TOKEN=pk.your-real-token" > android/config/local.env.secrets.properties
./gradlew :app:assembleLocalDebug
```

The Gradle build merges defaults + secrets at sync time and emits the values as `BuildConfig` fields. `AppConfigProvider.current()` returns a typed `AppConfig` from those fields.

## Build variants

Three product flavors × two build types = six variants. Each flavor sets a distinct application id suffix so you can side-load all three at once:

| Variant | Application id |
|---|---|
| `localDebug` | `ca.roadsense.android.localdebug` |
| `stagingDebug` | `ca.roadsense.android.staging` |
| `productionDebug` | `ca.roadsense.android` |
| `…Release` | same id, signed for release |

Run `./gradlew :app:assembleLocalDebug` (or `stagingDebug`, etc.) to build a specific variant. `./gradlew test` runs unit tests across all flavors.

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
