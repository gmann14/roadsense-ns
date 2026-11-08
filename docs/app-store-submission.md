# App Store Submission Package (v1.0)

This is the single checklist for getting RoadSense NS 1.0 through App Review. The listing text lives in `ios/fastlane/metadata/` and can be pushed with `bundle exec fastlane upload_metadata`. That lane never submits for review. Everything else is a one-time App Store Connect (ASC) setting, listed below.

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

These must match `ios/RoadSenseNS/PrivacyInfo.xcprivacy`. **Tracking: No** for every type, and no data is shared with third parties for their own purposes.

| ASC data type | Collected | Linked to user | Purpose | Why |
|---|---|---|---|---|
| Location → **Precise Location** | Yes | **Yes** | App Functionality | Road readings carry GPS points and are keyed by the rotating device token. |
| Identifiers → **Device ID** | Yes | **Yes** | App Functionality | The random rotating upload token. It is not the IDFA or IDFV. |
| Contact Info → **Email Address** | Yes (optional) | Yes | App Functionality | Optional reply address in the feedback form. |
| User Content → **Customer Support** | Yes | Yes | App Functionality | Feedback message text. |
| Other Data → **Other Data Types** | Yes | Yes | App Functionality | Road-roughness values derived from motion sensors. |
| Diagnostics → **Crash Data** | Yes | No | App Functionality | Sentry crash reports. |
| Diagnostics → **Performance Data** | Yes | No | App Functionality | Sentry performance traces. |

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

The current `ios/fastlane/screenshots/en-CA/*.png` are **not suitable**:

- They're un-captioned 6.5" UI mockups with no map.
- Two of the four show the large Pothole button and the Photo button on the driving screen. That invites a Guideline 1.4.5 (driver distraction) objection, and Photo isn't in 1.0.

Replace them with real captures from the 1.0 build, in this order:

1. **The map** with the road-quality overlay over Halifax. Caption: "See which Nova Scotia roads are rough".
2. **Segment detail** drawer. Caption: "Every road scored from real drives".
3. **Driving screen during auto-recorded drive.** Caption: "Drive normally. RoadSense records on its own".
4. **Privacy zones.** Caption: "Your home and work stay private".
5. **Stats.** Caption: "Track the kilometres you've mapped".
6. Optional: **Siri phrase.** Caption: "Report potholes hands-free".

Capture on the iPhone 17 Pro Max simulator (`xcrun simctl io booted screenshot`) running a Production-config build. The map overlay needs a real Mapbox token in the gitignored `ios/Config/RoadSenseNS.Production.secrets.xcconfig`. Then add captions with any frame tool, or with `fastlane frameit` (it needs `Framefile.json` and fonts).

Screenshots must show the real app, so take them from the build you submit.

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
