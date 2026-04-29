# 10 — App Store & TestFlight Readiness

*Last updated: 2026-04-28*

Covers: the release-ops source of truth for Apple Developer approval, App Store Connect fields, privacy labels, reviewer notes, screenshots, and the first internal/external TestFlight cycles.

This doc is intentionally operational. [06-security-and-privacy.md](06-security-and-privacy.md) remains the policy source of truth for privacy labels; this doc turns that policy into the concrete checklist and copy needed at release time.

## Current Status

- Apple Developer approval/API access is now far enough along for upload automation.
- There are no outside testers yet.
- Railway staging is provisioned and smoke-tested for hosted backend testing.
- The immediate bottleneck is signed iOS distribution, App Store Connect metadata, and real-device validation.
- The web app now has a fuller `/privacy` page that can back the future public policy URL once deployed.

## What To Finish Before Apple Approval Lands

1. Keep `RoadSense NS`, `ca.roadsense.ios`, and `https://roadsense.ca/privacy` consistent everywhere.
2. Make sure the privacy policy URL is live before any external TestFlight submission.
3. Keep [06-security-and-privacy.md](06-security-and-privacy.md) authoritative for App Store privacy labels.
4. Archive the app once from the production config and run `xcrun PrivacyReport` before the first real upload.
5. Capture the first screenshot set from a signed build, not from simulator-only mockups.

## App Store Connect Record

Fields that should not drift:

| Field | Value / Guidance |
|---|---|
| App name | `RoadSense NS` |
| Bundle ID | `ca.roadsense.ios` |
| Privacy policy URL | `https://roadsense.ca/privacy` |
| Contact email | `graham.mann14@gmail.com` |
| Account requirement | none |
| Demo credentials | N/A |

Fields that still need human product judgment:

- primary category
- subtitle
- promotional text
- long description
- keywords
- support URL if you want something better than the privacy/contact page

## Internal TestFlight Metadata

Recommended `What to Test` copy:

> Drive normally and confirm the map, stats, privacy-zone behavior, and upload flow look plausible. Do not interact with the phone while driving.

Recommended tester notes:

- no account is required
- background location is expected during an active drive
- manual pothole/photo interactions must only happen while stopped
- bugs should include time, route context, and whether the app was foregrounded or backgrounded

## External Beta Review Notes

Recommended review note for Apple:

> RoadSense NS measures road roughness while a user drives so it can publish aggregate road-quality maps. The app uses motion and location data together, including background location during an active drive, so collection can continue after the screen locks or the app backgrounds. No account or sign-in is required. Users can pause collection, define optional privacy zones, and delete all local data from Settings.

If Apple asks why background location is necessary:

- the core function is passive drive measurement, not turn-by-turn navigation
- drives must survive lock-screen/background transitions to produce usable data
- collection is limited to the documented road-quality use case
- users can pause collection and delete local data

## Privacy Labels

Use [06-security-and-privacy.md](06-security-and-privacy.md#app-store-privacy-labels) as the canonical answer set. The current expected answers are:

| Data type | Collected | Linked | Tracking | Purpose |
|---|---|---|---|---|
| Precise Location | yes | yes | no | App Functionality |
| Crash Data | yes | no | no | App Functionality |
| Performance Data | yes | no | no | App Functionality |

Everything else should remain unselected unless the implementation changes and [06-security-and-privacy.md](06-security-and-privacy.md) is updated in the same PR.

## Screenshot Shot List

Capture these from a signed build once the UI is stable enough for review:

1. Ready map shell with live road-quality overlay
2. Segment detail sheet with trust/freshness context visible
3. Stats screen
4. Settings screen showing privacy/delete-local-data controls
5. Privacy zones editor or onboarding privacy explanation

Rules:

- do not use obviously fake lorem ipsum or broken placeholder states
- avoid screenshots that expose a home address or private route
- keep copy aligned with the privacy policy and App Store labels

## Archive Verification

Before the first internal TestFlight upload:

1. confirm GitHub secrets exist for `APPLE_ASC_API_KEY_ID`, `APPLE_ASC_API_ISSUER_ID`, `APPLE_ASC_API_PRIVATE_KEY`, `APPLE_TEAM_ID`, and `MAPBOX_ACCESS_TOKEN`
2. run `.github/workflows/ios-testflight.yml` with `Staging Release` and upload disabled for the first signing dry run
3. run `.github/workflows/ios-testflight.yml` with upload enabled once the signed archive succeeds
4. run `xcrun PrivacyReport` on the archive
5. confirm the aggregated privacy manifest is present and coherent
6. verify the archive does not introduce a new privacy-collected-data category beyond what [06-security-and-privacy.md](06-security-and-privacy.md) already declares

The iOS implementation spec already requires this check:

- see [01-ios-implementation.md](01-ios-implementation.md) under the privacy manifest section

## First Internal Build Checklist

Before uploading a build to internal TestFlight:

1. latest `main` is green in repo CI and local smoke checks
2. privacy policy is published at the real URL
3. App Store Connect record exists with the final bundle ID
4. privacy labels match [06-security-and-privacy.md](06-security-and-privacy.md)
5. `What to Test` text is filled in
6. no sign-in/demo credentials are declared
7. one signed build has been installed locally outside Xcode and opened successfully

## First External Build Checklist

Before submitting for external Beta App Review:

1. at least one internal signed-build cycle is complete
2. crash and log review show no forbidden PII leakage
3. privacy policy URL is live and matches the in-app story
4. screenshots are current
5. reviewer notes mention background location plainly
6. internal field-test evidence exists in the shape described by [09-internal-field-test-pack.md](09-internal-field-test-pack.md)

## Deferred On Purpose

These are not worth front-loading before Apple approval:

- polishing external-tester support workflows before the first internal signed build exists

## Go / No-Go

`Go` for the first internal TestFlight build when:

- Apple Developer approval is complete
- the App Store Connect record is created
- privacy labels and privacy policy are aligned
- one production archive passes the privacy-manifest check

`No-go` if any of these are still unresolved:

- privacy policy URL missing or stale
- App Store Connect privacy labels differ from [06-security-and-privacy.md](06-security-and-privacy.md)
- signed build not yet validated on a real device
- reviewer notes still rely on vague or misleading background-location language
