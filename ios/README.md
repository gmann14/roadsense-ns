# iOS App Scaffold

This directory now contains two layers:

- `Package.swift` + `Sources/RoadSenseNSBootstrap/`
  - Foundation-only bootstrap code we can validate with `swift test`
  - currently owns `AppEnvironment`, `AppConfig`, `BackgroundCollectionPolicy`, `CollectionReadiness`, `DeviceTokenManager`, `DrivingHeuristic`, `Endpoints`, `HighPassBiquad`, `IngestHealthEvaluator`, `MotionMath`, `PotholeDetector`, `PrivacyZone`, `QualityFilter`, `ReadingBuilder`, `RetentionPolicy`, `UploadAPIModels`, `UploadEligibilityPolicy`, `UploadPolicy`, `UploadRequestFactory`, `UploadResponseParser`, `UploadQueueCore`, and `RejectedReason`
- `project.yml` + `RoadSenseNS/`
  - XcodeGen project spec for the real iOS app target
  - app-shell files (`RoadSenseNSApp`, `AppContainer`, `AppModel`, onboarding flow, `PermissionManager`, `Info.plist`, placeholder tests)
  - SwiftData model scaffolding under `RoadSenseNS/Persistence/Models/`
  - persistence/runtime infrastructure under `RoadSenseNS/Persistence/` (`ModelContainerProvider`, `PrivacyZoneStore`, `UploadQueueStore`)
  - network/runtime infrastructure under `RoadSenseNS/Network/` (`APIClient`, `Uploader`)
  - production sensor wrappers under `RoadSenseNS/Sensors/`
  - a manual privacy-zone management screen under `RoadSenseNS/Features/PrivacyZones/`
  - committed base `.xcconfig` files under `Config/` so `xcodegen generate` works from a clean checkout

Current status:

- config/runtime seams are implemented in real Swift code
- permission/onboarding gating is implemented as a pure Swift state machine with `swift test` coverage
- gravity-projection math for motion samples is implemented in a pure Swift seam with tests
- reading-window assembly and documented quality-gate logic are implemented in pure Swift with tests
- upload retry/failure policy is implemented in pure Swift with tests
- privacy-zone creation/filtering, the high-pass filter, and pothole spike detection are implemented in pure Swift with tests
- the GPS-only degraded-permission driving heuristic is implemented in pure Swift with tests
- upload request/response encoding and background-location policy decisions are implemented in pure Swift with tests
- the app target has a real onboarding shell split from the ready-to-collect home shell
- the app target now includes first-pass SwiftData models mirroring the implementation spec
- the app target now includes first-pass persistence adapters (`DeviceTokenStore`, queue mappers, rejected-reason JSON codec)
- the app target now includes a real model-container provider, queue store, API client, uploader, privacy-zone store, and manual privacy-zone UI
- the app target now includes a first live `SensorCoordinator` plus `ReadingStore`, so accepted readings and privacy-filtered local entries can be persisted before the map UI exists
- the app target now persists crash-safe checkpoint state via `SensorCheckpointStore` and restores fresh checkpoints on next launch
- the app target now includes production wrappers for location, motion, driving-activity, thermal-state, background-task registration, and Sentry bootstrapping seams
- the app target now includes first-pass `StatsView` and `SettingsView`, plus delete-local-data and Always-location-upgrade controls
- the pure Swift layer now includes a CSV fixture parser and replay runner for simulator-harness style validation
- queue cleanup, upload eligibility, and ingest-health evaluation now also exist as pure Swift seams with tests
- base `.xcconfig` files exist under `Config/`
- optional secret override files can be created as:
  - `Config/RoadSenseNS.Local.secrets.xcconfig`
  - `Config/RoadSenseNS.Staging.secrets.xcconfig`
  - `Config/RoadSenseNS.Production.secrets.xcconfig`
- `.xcconfig` templates still exist under `Config/Templates/` as copy/reference material
- a generator spec exists and can now generate `RoadSenseNS.xcodeproj`
- the main `RoadSenseNS` app target now builds for `iphonesimulator` with the current pre-map shell; only Sentry is linked for now

Local verification:

- `cd ios && swift test`
- `cd ios && xcodegen generate`
- `xcodebuild -project ios/RoadSenseNS.xcodeproj -scheme RoadSenseNS -configuration "Local Debug" -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build`

Current notes:

- Xcode + iOS SDKs are now installed and usable locally.
- The current app target links only the SDKs it actually uses today. Mapbox and Supabase SDK wiring are deferred until the map screen or SDK-specific features land.
- The ready shell now exposes start/stop passive monitoring and counts for accepted, privacy-filtered, and pending-upload readings.
- Background-task identifiers in the project now match the spec (`nightly-cleanup` and `upload-drain`) instead of the earlier placeholder cleanup-only ID.
- Stats and Settings now exist as real screens before the Mapbox home screen lands.
- The next milestone is no longer “make it compile”; it is “sign it, install it on a real phone, and validate the runtime path.”
- The first golden-style harness replay path now uses checked-in `Fixtures/*.csv` and `Fixtures/*.expected.json` resources.
- `RoadSenseNSSimHarness` now exists as a separate lightweight app target that loads fixture resources, replays them through the real pipeline, and shows the replay summary.
- The remaining harness step is expanding the fixture corpus beyond the current pothole case and keeping the harness target green in CI.
