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
  - a map-backed privacy-zone editor under `RoadSenseNS/Features/PrivacyZones/`
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
- the app target now includes a real model-container provider, queue store, API client, uploader, privacy-zone store, and a map-backed privacy-zone editor
- the app target now includes a first live `SensorCoordinator` plus `ReadingStore`, so accepted readings and privacy-filtered local entries can be persisted before the map UI exists
- the app target now persists crash-safe checkpoint state via `SensorCheckpointStore` and restores fresh checkpoints on next launch
- the app target now includes production wrappers for location, motion, driving-activity, thermal-state, background-task registration, and Sentry bootstrapping seams
- the app target now includes first-pass `StatsView` and `SettingsView`, plus delete-local-data and Always-location-upgrade controls
- the app target now includes a real map-style home shell (`MapScreen`) with recording status, floating contribution card, stats/settings chrome, and expandable road-quality legend
- the app target now overlays locally collected but unuploaded drives as a dashed teal line above the community layer
- the app target now includes the first editorial `SegmentDetailSheet` plus typed `GET /segments/{id}` endpoint/model/parser/client support
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
- The main app target now links Mapbox and Sentry and builds successfully for `iphonesimulator`.
- The home screen is now a product-style map shell with live Mapbox-backed road-quality tiles, pothole markers, and tap-to-detail presentation.
- Background-task identifiers in the project now match the spec (`nightly-cleanup` and `upload-drain`) instead of the earlier placeholder cleanup-only ID.
- Stats and Settings now exist as real screens off the home-shell overlay buttons.
- The next milestone is no longer “make it compile”; it is “sign it, install it on a real phone, and validate the runtime path.”
- The first golden-style harness replay path now uses checked-in `Fixtures/*.csv` and `Fixtures/*.expected.json` resources.
- The harness suite now auto-discovers every checked-in `.expected.json` resource, so new fixtures join the deterministic replay suite without extra test boilerplate.
- `RoadSenseNSSimHarness` now exists as a separate lightweight app target that loads fixture resources, replays them through the real pipeline, and shows the replay summary.
- The app target now supports explicit XCTest launch scenarios via `ROAD_SENSE_TEST_SCENARIO=default|ready-shell`, and UI tests use a deterministic non-Mapbox testing surface so simulator automation can validate app flows without waiting on live map startup.
- `RoadSenseNSTests` now includes first app-target network/uploader coverage, and the app enters an inert in-memory bootstrap path when launched under XCTest so host-based unit tests do not start real sensors, background tasks, or Sentry.
- The remaining harness step is expanding the fixture corpus beyond the current pothole and smooth-cruise cases and keeping the harness target green in CI.
- The remaining product-facing iOS steps are deeper retry/empty-state handling around the live map, broader fixture replay coverage, richer map-selection UI testing, and real-device runtime validation.

Additional verification commands:

- `xcodebuild -project ios/RoadSenseNS.xcodeproj -scheme RoadSenseNS -configuration "Local Debug" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build-for-testing`
