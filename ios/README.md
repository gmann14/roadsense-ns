# iOS App Scaffold

This directory now contains two layers:

- `Package.swift` + `Sources/RoadSenseNSBootstrap/`
  - Foundation-only bootstrap code we can validate with `swift test`
  - currently owns `AppEnvironment`, `AppConfig`, `CollectionReadiness`, `DeviceTokenManager`, `DrivingHeuristic`, `Endpoints`, `HighPassBiquad`, `IngestHealthEvaluator`, `MotionMath`, `PotholeDetector`, `PrivacyZone`, `QualityFilter`, `ReadingBuilder`, `RetentionPolicy`, `UploadEligibilityPolicy`, `UploadPolicy`, `UploadQueueCore`, and `RejectedReason`
- `project.yml` + `RoadSenseNS/`
  - XcodeGen project spec for the real iOS app target
  - app-shell files (`RoadSenseNSApp`, `AppContainer`, `AppModel`, onboarding flow, `PermissionManager`, `Info.plist`, placeholder tests)
  - SwiftData model scaffolding under `RoadSenseNS/Persistence/Models/`
  - committed base `.xcconfig` files under `Config/` so `xcodegen generate` works from a clean checkout

Current status:

- config/runtime seams are implemented in real Swift code
- permission/onboarding gating is implemented as a pure Swift state machine with `swift test` coverage
- gravity-projection math for motion samples is implemented in a pure Swift seam with tests
- reading-window assembly and documented quality-gate logic are implemented in pure Swift with tests
- upload retry/failure policy is implemented in pure Swift with tests
- privacy-zone creation/filtering, the high-pass filter, and pothole spike detection are implemented in pure Swift with tests
- the GPS-only degraded-permission driving heuristic is implemented in pure Swift with tests
- the app target has a real onboarding shell split from the ready-to-collect home shell
- the app target now includes first-pass SwiftData models mirroring the implementation spec
- the app target now includes first-pass persistence adapters (`DeviceTokenStore`, queue mappers, rejected-reason JSON codec)
- queue cleanup, upload eligibility, and ingest-health evaluation now also exist as pure Swift seams with tests
- base `.xcconfig` files exist under `Config/`
- optional secret override files can be created as:
  - `Config/RoadSenseNS.Local.secrets.xcconfig`
  - `Config/RoadSenseNS.Staging.secrets.xcconfig`
  - `Config/RoadSenseNS.Production.secrets.xcconfig`
- `.xcconfig` templates still exist under `Config/Templates/` as copy/reference material
- a generator spec exists and can now generate `RoadSenseNS.xcodeproj`
- the first simulator build is package-resolution limited rather than Xcode-install limited

Local verification:

- `cd ios && swift test`
- `cd ios && xcodegen generate`
- `xcodebuild -project ios/RoadSenseNS.xcodeproj -scheme RoadSenseNS -configuration "Local Debug" -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build`

Current notes:

- Xcode + iOS SDKs are now installed and usable locally.
- The first full app build will need the real package/dependency path to resolve cleanly, including Mapbox package fetches.
