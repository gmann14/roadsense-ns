# Fastlane Release Automation

The default release lane builds `Staging Release` for internal TestFlight so early testers use the hosted Railway staging API. Use `IOS_RELEASE_CONFIGURATION="Production Release"` only after the production backend, privacy policy, and App Store metadata are ready.

Required environment:

- `APPLE_ASC_API_KEY_ID`
- `APPLE_ASC_API_ISSUER_ID`
- `APPLE_ASC_API_PRIVATE_KEY_PATH` or `APPLE_ASC_API_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `MAPBOX_ACCESS_TOKEN`
- `ROAD_SENSE_PUBLIC_API_KEY` for shared TestFlight builds

Optional environment:

- `ROAD_SENSE_APP_IDENTIFIER` defaults to `ca.roadsense.ios`
- `IOS_RELEASE_CONFIGURATION` defaults to `Staging Release`
- `IOS_BUILD_NUMBER` defaults to the GitHub run number, or a UTC timestamp locally
- `ROAD_SENSE_PUBLIC_API_KEY` overrides the API key baked into the selected xcconfig
- `API_BASE_URL` overrides the selected environment API URL
- `SENTRY_DSN`
- `ENABLE_POTHOLE_PHOTOS` defaults to `NO` locally; the GitHub TestFlight workflow sets it to `YES` for field-test builds
- `SKIP_TESTFLIGHT_UPLOAD=1` builds the IPA without uploading

The release lane creates or renews an Apple Distribution certificate and an App Store provisioning profile named `RoadSense NS App Store ca.roadsense.ios`, then writes that profile into the app target's release xcconfig for manual App Store signing. This keeps GitHub Actions independent from a logged-in Xcode account on the runner without forcing provisioning settings onto Swift Package dependencies.

Local build/upload:

```bash
bundle install
cd ios
APPLE_ASC_API_PRIVATE_KEY_PATH=/path/to/AuthKey.p8 \
APPLE_ASC_API_KEY_ID=... \
APPLE_ASC_API_ISSUER_ID=... \
APPLE_TEAM_ID=... \
MAPBOX_ACCESS_TOKEN=... \
bundle exec fastlane ios internal_testflight
```
