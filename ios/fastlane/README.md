# Fastlane Release Automation

The default release lane builds `Staging Release` for internal TestFlight so early testers use the hosted Railway staging API. Use `IOS_RELEASE_CONFIGURATION="Production Release"` only after the production backend, privacy policy, and App Store metadata are ready.

Required environment:

- `APPLE_ASC_API_KEY_ID`
- `APPLE_ASC_API_ISSUER_ID`
- `APPLE_ASC_API_PRIVATE_KEY_PATH` or `APPLE_ASC_API_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` or the legacy typo `APPLE_DISTRIBUTION_SECRET_BASE64` in GitHub Actions
- `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `APPLE_PROVISIONING_PROFILE_BASE64`
- `MAPBOX_ACCESS_TOKEN`
- `ROAD_SENSE_PUBLIC_API_KEY` for shared TestFlight builds

Optional environment:

- `ROAD_SENSE_APP_IDENTIFIER` defaults to `ca.roadsense.ios`
- `IOS_RELEASE_CONFIGURATION` defaults to `Staging Release`
- `IOS_BUILD_NUMBER` defaults to the GitHub run number, or a UTC timestamp locally
- `IOS_MARKETING_VERSION` overrides `CFBundleShortVersionString`; use `1.0` when uploading the first public App Store build
- `ROAD_SENSE_PUBLIC_API_KEY` overrides the API key baked into the selected xcconfig
- `API_BASE_URL` overrides the selected environment API URL
- `SENTRY_DSN`
- `ENABLE_POTHOLE_PHOTOS` defaults to `NO` locally; the GitHub TestFlight workflow sets it to `YES` for field-test builds
- `SKIP_TESTFLIGHT_UPLOAD=1` builds the IPA without uploading

Production Release builds require `SENTRY_DSN` in GitHub Actions so TestFlight crash reports are not the only crash source.

The release lane must use a stable Apple Distribution signing setup that already exists in CI. Routine TestFlight builds must not create, renew, or revoke Apple signing certificates.

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
