# iOS App Scaffold

This directory now contains two layers:

- `Package.swift` + `Sources/RoadSenseNSBootstrap/`
  - Foundation-only bootstrap code we can validate with `swift test`
  - currently owns `AppEnvironment`, `AppConfig`, `CollectionReadiness`, `Endpoints`, and `RejectedReason`
- `project.yml` + `RoadSenseNS/`
  - XcodeGen project spec for the real iOS app target
  - app-shell files (`RoadSenseNSApp`, `AppContainer`, `AppModel`, onboarding flow, `PermissionManager`, `Info.plist`, placeholder tests)
  - committed base `.xcconfig` files under `Config/` so `xcodegen generate` works from a clean checkout

Current status:

- config/runtime seams are implemented in real Swift code
- permission/onboarding gating is implemented as a pure Swift state machine with `swift test` coverage
- the app target has a real onboarding shell split from the ready-to-collect home shell
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
