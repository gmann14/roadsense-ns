# RoadSense NS — Android

Android client for the RoadSense NS road-quality measurement project. Plan and architecture lives in [`docs/implementation/12-android-implementation.md`](../docs/implementation/12-android-implementation.md). Release operations live in [`docs/implementation/15-google-play-readiness.md`](../docs/implementation/15-google-play-readiness.md).

## Status

| Phase | Status | Notes |
|---|---|---|
| A12-1 — Sensor pipeline parity | Landed | `core-sensor` JVM module + iOS-fixture replay |
| A12-2a — Wire-format DTOs + policies | Landed | `core-api` JVM module + iOS JSON parity, now also covering `pothole-actions` and `feedback` |
| A12-2b — Room + Retrofit shells | Landed | `:app` module compiles, schema exported, DAO tests pass |
| A12-3 — Foreground service + permissions | Landed | Production permission ladder (`PermissionState`), foreground notification, Android sensor/location subscriptions, Room-backed collection pipeline, unified `UploadDrainWorker`, manifest declares `FOREGROUND_SERVICE_LOCATION` |
| A12-4 — Compose UI + manual pothole + feedback | Landed (beta) | Material 3 shell with Map / Stats / Settings tabs, drive controls, manual pothole report with 8s undo, in-app feedback queue, Settings → Delete local data, Material You dynamic colors. Native Mapbox map shell is the remaining sub-task — see "What does not exist yet" |
| A12-5 — Feedback queue | Landed | Room-backed `FeedbackEntity` + `FeedbackQueueDrainer` mirroring iOS, drains on the same heartbeat as readings + pothole actions |
| A12-6 — Sideload distribution + Play prep | Scaffolded | Optional env-driven release signing config + `.github/workflows/android-internal.yml` placeholder; needs Play Console developer account + upload keystore offline-generated. See `docs/implementation/15-google-play-readiness.md` |

Total tests passing across all modules: run `./gradlew test` from `android/`.

What exists:

- `core-sensor` (pure Kotlin/JVM) — line-for-line ports of the iOS pipeline
- `core-api` (pure Kotlin/JVM) — wire-format DTOs + upload eligibility/backoff/retention policies, plus pothole-actions + feedback parity tests
- `core-fixtures/` — byte-for-byte mirror of iOS test fixtures, parity-checked
- `:app` Android module — AGP 8.7, Jetpack Compose Material 3 shell, AndroidX, Room schema (9 entities + DAOs), Retrofit `BackendClient` over `core-api` DTOs, OkHttp auth interceptor, foreground collection service, unified `UploadDrainWorker` (readings + pothole actions + feedback), backup disabled with explicit Room excludes
- Production permission ladder via `PermissionState` (fine location → activity recognition → notifications → background location), with API 30+ background routed to Settings per Play policy
- Manual pothole action flow with PENDING_UNDO → PENDING_UPLOAD state machine and an 8-second in-app undo window
- Persistent in-app feedback queue with backend submission, validation-failed → permanent + rate-limited → reschedule semantics
- Settings → Delete all local data (clears every Room table including the rotating device token)
- Optional release signing wired from `ANDROID_UPLOAD_*` env vars; release falls back to the debug keystore when the env vars are absent so local + CI builds keep working
- `.github/workflows/android-internal.yml` Play Internal Testing publish workflow stub (manual dispatch only; needs the Play developer account + signing secrets to actually upload)
- Robolectric tests covering Room schema, the upload-pipeline DAO queries, the feedback queue + drainer, the pothole repository + coordinator (success/retry/permanent), and the data-wipe path

What does **not** exist yet:

- Native Mapbox Android map rendering (vector-tile + pothole overlay). The Compose `MapHost` is wired to use the real Mapbox `MapView` the moment `MAPBOX_DOWNLOADS_TOKEN` is exposed at sync time (env var or `~/.gradle/gradle.properties`); without the token the host falls back to a WebView pointing at the public web map so CI builds keep working without a private Maven credential. Once the token is provisioned, the Mapbox SDK is added automatically and `MapHost` swaps the WebView for an in-process `MapView`.
- Pothole photo capture. The action flow (manual report + upload) ships in beta; the photo follow-up is iOS-parity work tracked separately.
- Signing keystore + Google Play Console developer account. Build wiring is done — the release machine just exports the four `ANDROID_UPLOAD_*` env vars to produce an upload-key-signed AAB.
- Real-device evidence on at least one Pixel-class and one Samsung-class phone: sensor parity, upload acceptance, battery drain, foreground-service survivability, plus the new manual pothole + feedback + delete-local-data flows.

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
5. To run instrumentation tests, you'll need an AVD running (see below) — right-click `app/src/androidTest` and **Run**.

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
./gradlew test                    # JVM unit tests across all modules
./gradlew :core-sensor:test       # iOS-fixture parity only
./gradlew :core-api:test          # wire-format parity + policies
./gradlew :app:testStagingDebugUnitTest # Robolectric DAO + pipeline tests
./gradlew :app:assembleStagingDebug    # build the staging debug APK
./gradlew :app:bundleStagingRelease    # build the staging release AAB (debug-signed unless ANDROID_UPLOAD_* env vars are set)
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

## Release signing (Phase 2 — Play distribution)

The release signing config is wired entirely from environment variables so the upload key never lives in the repo or CI logs.

To produce a Play-acceptable signed AAB, set all four:

```sh
export ANDROID_UPLOAD_KEYSTORE_PATH=/abs/path/to/upload-key.jks
export ANDROID_UPLOAD_KEYSTORE_PASSWORD='…'
export ANDROID_UPLOAD_KEY_ALIAS='upload'
export ANDROID_UPLOAD_KEY_PASSWORD='…'
./gradlew :app:bundleProductionRelease
```

If any of the four are missing the build still succeeds, but the AAB is signed with the debug keystore — useful for sideload but rejected by Play. CI runs without the env vars on purpose so PR builds don't need the upload key.

`.github/workflows/android-internal.yml` is the manually-dispatched workflow that builds the production-flavor AAB and (when `vars.ANDROID_PUBLISH_ENABLED == 'true'`) uploads it to Google Play Internal Testing via the Play Developer API. See [`docs/implementation/15-google-play-readiness.md`](../docs/implementation/15-google-play-readiness.md) for the secret list.

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
├── core-api/                  # pure JVM — wire-format DTOs + policies (A12-2a + A12-4 contracts)
│   └── src/{main,test}/kotlin/ca/roadsense/ns/api/...
├── app/                       # Android — Compose UI, foreground service, Room, Retrofit
│   ├── build.gradle.kts
│   ├── schemas/               # Room schema export, committed for migrations
│   └── src/main/kotlin/ca/roadsense/ns/{ui,collection,upload,pothole,feedback,permissions,data,…}
├── distribution/whatsnew/     # Play Internal Testing release notes
└── core-fixtures/             # byte-for-byte copy of iOS test fixtures
```
