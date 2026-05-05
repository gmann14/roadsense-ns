# 10 — App Store & TestFlight Readiness

*Last updated: 2026-04-28*

Covers: the release-ops source of truth for Apple Developer approval, App Store Connect fields, privacy labels, reviewer notes, screenshots, and the first internal/external TestFlight cycles.

This doc is intentionally operational. [06-security-and-privacy.md](06-security-and-privacy.md) remains the policy source of truth for privacy labels; this doc turns that policy into the concrete checklist and copy needed at release time.

## Current Status

- Apple Developer approval/API access is now far enough along for upload automation.
- There are no outside testers yet.
- Railway staging is provisioned and smoke-tested for hosted backend testing.
- The immediate bottleneck is signed iOS distribution, App Store Connect metadata, and real-device validation. The GitHub TestFlight workflow exists, but CI must still be able to use Apple distribution signing assets for `ca.roadsense.ios`.
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
| Privacy policy URL | `https://nsroadsense.ca/privacy` |
| Contact email | `graham.mann14@gmail.com` |
| Account requirement | none |
| Demo credentials | N/A |
| Support URL | `https://nsroadsense.ca` (homepage; add a dedicated `/contact` later if you want a richer support surface) |
| Primary category | Travel |
| Secondary category | Utilities |
| Age rating | 4+ |

## Drafted copy for App Store submission

Drafted 2026-05-05 alongside the build 5 TestFlight submission. Lock these strings on App Store submission day; until then, treat as the leading candidate.

### Subtitle (≤30 chars)

`Community road-quality map` (26 chars)

Alternates if you want a different angle: `Pothole map for Nova Scotia` (27), `Map Nova Scotia's roads` (23), `A community road map of NS` (26).

### Promotional text (≤170 chars, editable post-approval without re-review)

> Drive normally. Your phone quietly measures road roughness and shares it with a public map of every pothole and rough stretch in Nova Scotia. No account needed.

(157 chars.)

### Description (≤4,000 chars; below ≈1,400)

> RoadSense NS turns your daily drives into a public map of every pothole and rough stretch in Nova Scotia.
>
> While you drive — phone in your pocket, screen off, music playing — RoadSense quietly measures road roughness using your phone's accelerometer and GPS. Your readings combine with everyone else's to build a community-owned map of road quality across the province.
>
> No account. No sign-up. Open the app, accept location and motion permissions, drive normally.
>
> **What you get**
> - A live map of road quality across Nova Scotia, refreshed nightly
> - One-tap pothole reports with optional photos
> - See your kilometres mapped, your contributions, and the community's collective coverage
>
> **Privacy you can verify**
> RoadSense was built privacy-first:
> - Your home and work are automatically shielded — RoadSense trims trip endpoints before any data leaves the device
> - You can add custom privacy zones for any place you stop often
> - Device tokens rotate monthly so contributions can't be linked back to you over time
> - All on-device data can be deleted from Settings with one tap
> - Background location is used only during active drives — read the full policy at nsroadsense.ca/privacy
>
> **Why this matters**
> Road quality data has historically been collected by provincial transportation departments using expensive vans on a multi-year cycle. RoadSense puts that capability in every driver's pocket — and makes the result public, so anyone can see which roads need fixing first.
>
> Built in Halifax. Free and ad-free.

### Keywords (≤100 chars, comma-separated, no spaces between commas)

```
pothole,roads,nova scotia,road quality,halifax,driving,commute,infrastructure,civic,transit
```

(91 chars; budget room for one more concrete-noun term — `mapping` or `community` if you want to fill the keyword surface.)

### Screenshot capture plan

Wait until build 6/7 stabilizes from the first wave of external testers and the public map has filled out from real-world drives (currently 196 km / 4,032 segments — visibly thin in screenshots; needs more density before it markets the product well). Capture from `Staging Debug` (or `Local Debug` with the prod-override secrets file) on a single iPhone 17 Pro Max simulator — Apple auto-scales for smaller devices. Use `xcrun simctl io booted screenshot ~/Desktop/screenshot-N.png` so the captures are clean PNGs at the device's native resolution.

Order in App Store Connect so the hero (#1) is the one Apple shows in search results.

| # | Screen | What to show |
|---|---|---|
| 1 | Active drive (hero) | Heatmap rendered behind the road-ribbon overlay, RoadSense chip top-left, pothole FAB visible |
| 2 | Stats | km mapped, community kilometres this week, drives count |
| 3 | Segment detail sheet | A coloured road tapped, showing roughness score / freshness / confidence / pothole count |
| 4 | Settings → Privacy | Privacy zones list, trim-endpoints explanation, delete-local-data button |
| 5 | First-run mission hook | "A shared map of every pothole and rough stretch in Nova Scotia" with the brand mark |

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
3. if the dry run cannot sign automatically on the GitHub runner, add an explicit signing path with `fastlane match` or an imported Apple Distribution certificate plus App Store provisioning profile
4. run `.github/workflows/ios-testflight.yml` with upload enabled once the signed archive succeeds
5. run `xcrun PrivacyReport` on the archive
6. confirm the aggregated privacy manifest is present and coherent
7. verify the archive does not introduce a new privacy-collected-data category beyond what [06-security-and-privacy.md](06-security-and-privacy.md) already declares

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
