# App Store Submission Package (v1.0)

This is the single checklist for getting RoadSense NS 1.0 through App Review. The listing text lives in `ios/fastlane/metadata/` and can be pushed with `fastlane upload_metadata` (add `screenshots:true` to replace the screenshots). That lane never submits for review.

**Status (2026-11-09):** every ASC setting below is done and was checked through the API. Build 35 is attached with manual release. The remaining steps are the real-drive gate, the review video and the submit itself.

Running the lane from a Mac: load the API key from `~/.context/secrets/roadsense-asc.env` (it holds the key ID, issuer ID and .p8 path; never commit it). Two gotchas for version 1.0:
- Move `metadata/en-CA/release_notes.txt` aside while running. Apple rejects "What's New" on a first version.
- The review-information upload fails unless the version already has a review-detail record with the contact name, email and phone. Those are set in ASC now; keep them out of the repo. Everything else is a one-time App Store Connect (ASC) setting, listed below.

Submitting: `fastlane submit_review` (run from `ios/`, with the same env file loaded). It needs `IOS_BUILD_NUMBER` and refuses to run unless `SUBMIT_CONFIRM` is exactly `submit <version> (<build>)`, for example `submit 1.0 (35)`. Set that only after the owner has approved this exact build. Optional: set `APP_REVIEW_ATTACHMENT` to a video path to attach a review video. Release stays manual.

Last updated 2026-11-08, after the [2026-10-18 review](reviews/2026-10-18-full-codebase-review.md).

---

## 0. Gates: do not submit until all are true

1. **Backend fixes are deployed.** The app talks to `api.nsroadsense.ca`, and reviewers will exercise it. Push `main` and deploy in the safe order from `docs/implementation/05-deployment-and-observability.md`: migrations, then the Cloudflare worker, then the API, then the web.
2. **`/privacy`, `/terms` and `/support` all return 200 on `nsroadsense.ca`** with the November 2026 content (privacy updated for Android and processors, terms new, support new).
3. **A `1.0` build from current `main` is in TestFlight and smoke-tested on a real iPhone.** The smoke test is one real drive. Check that:
   - the drive appears in Drives;
   - the upload queue drains;
   - the pothole Siri phrase works;
   - the passenger confirmation appears above walking speed;
   - Settings has the Privacy, Terms and Support links.
4. **No crash cluster** for that build in ASC → TestFlight → Crashes.
5. **Privacy report from the archive matches section 4.** Run Xcode Organizer → archive → Generate Privacy Report. The app's `PrivacyInfo.xcprivacy` plus the Mapbox and Sentry SDK manifests must not declare anything missing from section 4.

---

## 1. Build to submit

- Workflow: GitHub `iOS TestFlight` (runs on `macos-26`, Xcode 26, so it meets Apple's current SDK requirement).
  - `configuration`: **Production Release**
  - `marketing_version`: **1.0**
  - `build_number`: the next unused number, ≥ 30. Builds 24–26 had launch crashes; 27–29 predate the review fixes.
  - `enable_sentry`: your call. If on, set the `SENTRY_DSN` secret first. Crash and Performance data are declared either way.
  - `ENABLE_POTHOLE_PHOTOS` is hard-wired to `NO` in the workflow. Photos stay off for 1.0, so **Photos is not declared**.
- Encryption: `ITSAppUsesNonExemptEncryption = false` is in `Info.plist`, so ASC won't ask export-compliance questions. The app uses only standard HTTPS.

---

## 2. App Information (one-time ASC settings)

| Field | Value |
|---|---|
| Name | RoadSense NS |
| Subtitle | Community road-quality map |
| Bundle ID | `ca.roadsense.ios` |
| Primary language | English (Canada). Must match the `en-CA` metadata folder. |
| Primary category | Travel |
| Secondary category | Utilities |
| Content rights | **Yes**: it contains third-party content (OpenStreetMap data under ODbL; Mapbox map tiles) and you have the rights to use it. |
| Age rating | Answer **None/No** to every content question. No user-generated content is shared publicly (feedback is private and photos are off), no unrestricted web browsing (links open in Safari), no messaging, no ads, no gambling. Expected result: **4+**. |
| Privacy Policy URL | https://nsroadsense.ca/privacy |
| User Privacy Choices URL | leave blank (optional) |
| Copyright | `© 2026 Graham Mann` (`metadata/copyright.txt`) |

## 3. Pricing and availability

- Price: **Free**. No in-app purchases.
- Availability: **Canada only** for 1.0. The data is Nova Scotia-specific, and limiting availability avoids the EU Digital Services Act trader-status disclosure (a public address and phone number). Widen later if you want.
- Not on Apple silicon Macs / Vision Pro (uncheck both): background driving collection makes no sense there.

## 4. App Privacy ("nutrition labels")

These must match `ios/RoadSenseNS/PrivacyInfo.xcprivacy` (8 types since 2026-11-09). **Tracking: No** for every type, and no data is shared with third parties for their own purposes.

| ASC data type | Collected | Linked to user | Purpose | Why |
|---|---|---|---|---|
| Location → **Precise Location** | Yes | **Yes** | App Functionality | Road readings carry GPS points and are keyed by the rotating device token. |
| Identifiers → **Device ID** | Yes | **Yes** | App Functionality | The random rotating upload token. It is not the IDFA or IDFV. |
| Contact Info → **Email Address** | Yes (optional) | Yes | App Functionality | Optional reply address in the feedback form. |
| User Content → **Customer Support** | Yes | Yes | App Functionality | Feedback message text. |
| Other Data → **Other Data Types** | Yes | Yes | App Functionality | Road-roughness values derived from motion sensors. |
| Diagnostics → **Crash Data** | Yes | No | App Functionality | Sentry crash reports. |
| Diagnostics → **Performance Data** | Yes | No | App Functionality | Sentry performance traces. |
| Diagnostics → **Other Diagnostic Data** | Yes | No | App Functionality | Sentry breadcrumbs and device context. Sentry's own manifest declares it (found in the build 35 check). |

Gate 5 check on build 35 (2026-11-09): the IPA has five manifests (the app, MapboxMaps, MapboxCommon, MapboxCoreMaps and Sentry), and none declares tracking. The Mapbox manifests list analytics types (User ID, Coarse/Precise Location, Product Interaction, Other Usage Data). They aren't collected, because the app writes `MGLMapboxMetricsEnabled = false` before the SDK starts (`MapboxTelemetryOptOut`), so they aren't declared. Mapbox's per-install ID is covered by Device ID.

Do **not** select Photos, Contacts, Health & Fitness, Financial, Browsing/Search History, Purchases, Usage Data, Sensitive Info, or Audio.

"Linked" is the conservative answer: Apple treats data attached to a device identifier as linked, even a random rotating one. Over-declaring is not a rejection risk; under-declaring is.

## 5. Version 1.0 page

| Field | Source |
|---|---|
| Promotional text (≤170) | `metadata/en-CA/promotional_text.txt` |
| Description | `metadata/en-CA/description.txt` |
| Keywords (≤100) | `metadata/en-CA/keywords.txt` |
| Support URL | https://nsroadsense.ca/support |
| Marketing URL | https://nsroadsense.ca |
| What's New | `metadata/en-CA/release_notes.txt` (hidden on a first release) |
| Version / build | 1.0 / the build from section 1 |
| Release | **Manually release this version**, so you can deploy or announce before it's public |

### Screenshots

The app is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so only iPhone screenshots are required. Upload one set to **6.9" (1320 × 2868)**. ASC scales it down for smaller sizes. If 6.9" isn't offered, use 6.5" (1284 × 2778).

Status (2026-11-09): three captioned 6.9" shots are in `ios/fastlane/screenshots/en-CA/`. That folder is gitignored, so the PNGs exist only on the Mac that made them; the raw captures can be regenerated as described below. The old un-captioned mockups were moved to `~/.context/backups/roadsense-ns/appstore-mockups-2026-05/`.

1. `01-map.png`: the map with the road-quality overlay over Halifax. Caption: "See which Nova Scotia roads are rough". **Done.**
2. `02-privacy-zones.png`: the privacy-zone editor. Caption: "Your home and work stay private". **Done.**
3. `03-stats.png`: Stats after a week of drives. Caption: "Track the kilometres you've mapped". **Done** (seeded `screenshot` scenario).
4. Optional: **driving screen during an auto-recorded drive.** Caption: "Drive normally. RoadSense records on its own". This needs a real drive on a 6.9" iPhone, because test mode can't show an active recording.
5. Optional: **Siri phrase.** Caption: "Report potholes hands-free".

There is no segment-detail shot. In the 1.0 build (`ENABLE_ROAD_QUALITY_VECTOR_OVERLAY=YES`) the map is the UIKit Mapbox view, which has no tap-to-select. Only the disabled SwiftUI map path supports it. The review notes were changed on 2026-11-09 so they no longer promise it.

How shots 1 and 2 were made:

- Write the gitignored `ios/Config/RoadSenseNS.Production.secrets.xcconfig` with the public Mapbox token and `PUBLIC_API_KEY`.
- Build `Production Release` for the iPhone 17 Pro Max simulator with `CODE_SIGNING_ALLOWED=NO`, then set the status bar with `xcrun simctl status_bar … override --time 9:41`.
- Launch with `SIMCTL_CHILD_ROAD_SENSE_UI_TESTS=1 SIMCTL_CHILD_ROAD_SENSE_TEST_SCENARIO=screenshot SIMCTL_CHILD_ROAD_SENSE_SCREENSHOT_LIVE_MAP=1 xcrun simctl launch … ca.roadsense.ios`. The `screenshot` scenario seeds four sealed, uploaded Halifax drives (22.9 km, 4 trips) and a Home zone. Use `ready-shell` for the privacy-zone editor. The live-map flag keeps the real map on.
- Capture with `xcrun simctl io booted screenshot`, then caption with `python3 -I ios/fastlane/caption_screenshot.py raw.png "Caption" out.png`.
- Test-mode launches can't write to the API: `TestingNetworkGuard` blocks every request except GET and HEAD. Before that guard existed, a screenshot launch on 2026-11-09 uploaded the seeded readings to production. Never take screenshots from a normal (non-test) launch while simulating a drive, because that would upload real-looking readings.

On a real device, screenshots must also be 1320 × 2868 (an iPhone 16/17 Pro Max) or 1284 × 2778 (6.5"). Screenshots must show the real app, so take them from the build you submit.

## 6. App Review Information

- Sign-in required: **No**.
- Contact: your name, phone and email. Enter them in ASC only, never in this public repo.
- Notes: `metadata/review_information/notes.txt`. The fastlane lane uploads them. They cover background location, privacy, driver safety, and how to review outside Nova Scotia.
- Attachment (strongly recommended): a 30–60 s screen recording of a real drive. Show onboarding with the While-Using → Always explanation sheet, a drive auto-starting and ending, and the Settings privacy links. This pre-empts the usual Guideline 2.5.4 follow-up question.

## 7. Known review risks and their mitigations

| Guideline | Risk | Mitigation in 1.0 |
|---|---|---|
| 2.5.4 / 5.1.5 background location | "Why Always?" | Purpose string says drives are detected and recorded automatically. The Always upgrade comes from an explanation sheet. Review notes and video cover it. |
| 1.4.5 driver distraction | Tap-to-report while driving | Siri / App Shortcut "Mark a pothole". Above walking speed the tap asks for passenger/stopped confirmation. Camera hidden (photos off). Screenshots don't show tapping. |
| 5.1.1(i) privacy policy access | Must be reachable in the app | Settings → Privacy Policy / Terms / Support. |
| 5.1.2 / privacy manifest | ITMS-91053 missing required-reason APIs | `PrivacyInfo.xcprivacy` added, and the archive privacy report was checked (gate 5). |
| 2.1 completeness | Reviewers outside Nova Scotia see no local data | The map opens on Nova Scotia with live public data, and the notes explain this. |
| 2.3 accurate metadata | Claims must match behaviour | Description revised. Claims like "rotating token", "≥3 contributors", "dates rounded" and "Siri" all depend on the 2026-11 fixes being deployed (gate 1). |

## 8. After approval

1. Deploy anything pending, then press **Release** in ASC.
2. Add the App Store badge and link to `nsroadsense.ca` and `/support`.
3. Watch ASC Crashes and Sentry for 48 h. Cut 1.0.1 for anything at launch.
4. Turn on Android only after its Play closed test (see `docs/implementation/15-google-play-readiness.md`).

## Historical notes (builds 22–29)

- Builds 24–26 crashed at launch: a Sentry launch crash, then Mapbox SwiftUI representable traps.
- Build 27 disabled the SwiftUI Mapbox map. Build 28 replaced it with an Apple map. Build 29 restored the road-quality overlay via a UIKit-backed Mapbox view.
- Public builds must keep `ENABLE_LIVE_MAPBOX_MAP=NO`, `ENABLE_MAP_FOLLOW_PUCK_ON_LAUNCH=NO` and `ENABLE_ROAD_QUALITY_VECTOR_OVERLAY=YES`. These are asserted by tests against the release xcconfigs and the TestFlight workflow.
- SwiftData launch: `ModelContainerProvider` backs up and resets unreadable stores. Treat any future SwiftData launch crash as a store-recovery bug.
