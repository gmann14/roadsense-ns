# 15 — Google Play Readiness

*Last updated: 2026-05-03*

Covers: the release-ops source of truth for Google Play Console approval, store listing fields, Data Safety form, App Content questionnaires, reviewer notes, screenshots/feature graphic, and the first internal/closed testing cycles.

This doc is the Android twin of [10-app-store-and-testflight-readiness.md](10-app-store-and-testflight-readiness.md). Build-level architecture lives in [12-android-implementation.md](12-android-implementation.md); this doc turns release-time policy into a concrete checklist and copy. [06-security-and-privacy.md](06-security-and-privacy.md) remains the canonical privacy source of truth — the Data Safety answers below must match it.

## Current Status

- Native Mapbox vector-tile + pothole overlay rendering wiring landed on `gmann14/android-beta-test-fixes`. The Compose `MapHost` calls into `MapboxBridge` (`android/app/src/mapboxMain/kotlin/`) which is compiled in whenever `MAPBOX_DOWNLOADS_TOKEN` is set at sync time; otherwise the no-Mapbox stub keeps reporting unavailable so CI keeps building. Real-device verification on a Pixel still pending — see "Real-device validation checklist" below.
- Google Play Console developer account not yet created. One-time $25 fee applies.
- New developer accounts created after 2023-11-13 must complete Closed Testing with **at least 12 testers opted in for at least 14 continuous days** before Production access is granted. Plan around that gate from day one.
- No Android signing keys exist. Sideload (Phase 1 of doc 12) uses a debug-style keystore at `android/keystores/dev.keystore` (gitignored). Play distribution (Phase 2) uses Google Play App Signing — we hold an **upload key**, Google holds the app-signing key.
- Build wiring for the upload key is in place: `android/app/build.gradle.kts` registers a `signingConfigs.upload` block iff `ANDROID_UPLOAD_KEYSTORE_PATH` + `ANDROID_UPLOAD_KEYSTORE_PASSWORD` + `ANDROID_UPLOAD_KEY_ALIAS` + `ANDROID_UPLOAD_KEY_PASSWORD` are exported. CI deliberately runs without those env vars so PR builds keep working without the upload key.
- `.github/workflows/android-internal.yml` exists as the manually-dispatched workflow that builds the production-flavor AAB and (when the `ANDROID_PUBLISH_ENABLED` repo variable is `true`) uploads it to Internal Testing via the Play Developer API. It is dormant until the secrets below are populated.
- `https://roadsense.ca/privacy` already covers the iOS app and is acceptable for Android too. Confirm the page mentions Android by name before the first Closed Testing submission.
- `apps/web` is the host for the privacy policy + (optional) support page. No Android-specific marketing site is required.

## Real-device validation checklist (unverified — no field evidence yet)

These steps are blocked on access to physical Android devices and an active Play developer account. They are intentionally not faked. Owner / date / device fingerprint must be filled in by the engineer running the drive — do not copy a stale "OK" from a prior cycle.

Foreground collection + permission ladder (Pixel-class device):

- [ ] install the latest staging-debug APK (`./gradlew :app:installStagingDebug`)
- [ ] grant fine location, activity recognition, and notifications when prompted at first launch
- [ ] confirm the persistent "Recording road quality" notification appears within 2 seconds of tapping Start
- [ ] confirm the notification cannot be dismissed without tapping Stop
- [ ] drive ≥10 minutes, screen on; confirm GPS fix card updates at ≥1 Hz cadence and the recording indicator stays green
- [ ] drive ≥10 minutes, screen off (locked); confirm the foreground service is still running on return — task manager + adb shell `dumpsys activity services ca.roadsense.android.staging | head` shows `running=true`
- [ ] tap Stop; confirm pending readings count drops to 0 within one heartbeat tick (≤15 min) and the upload result card surfaces no errors

Background collection upgrade:

- [ ] from the in-app "Open Android settings" affordance, switch the location permission to "Allow all the time"
- [ ] start a drive, walk into a Faraday-y building / put the phone face-down on the desk for ≥5 minutes, return — confirm the drive is still recording

Manual pothole + feedback + delete flows:

- [ ] tap "Mark pothole here" while stopped; confirm the 8-second undo appears and clears on its own
- [ ] tap "Mark pothole here" then "Undo last report" within 8 seconds; confirm no upload happens
- [ ] submit a feedback message offline (airplane mode), enable network, confirm it drains on the next heartbeat
- [ ] Settings → Delete all local data; confirm pending counts read 0 and the drive control card returns to "Grant permissions to start" state until permissions are re-requested

Upload acceptance against staging backend:

- [ ] after the first clean ≥10 minute drive, hit `https://roadsense.ca/?staging` (or the staging web URL) and confirm the segments the device covered show up in the public map within ~15 minutes
- [ ] verify the `x-request-id` of an `upload-readings` 200 response lands in the staging logs (Railway dashboard) with `accepted > 0`

Native Mapbox map shell (requires `MAPBOX_DOWNLOADS_TOKEN` + real `MAPBOX_ACCESS_TOKEN`):

- [ ] export `MAPBOX_DOWNLOADS_TOKEN` in the build environment and re-sync; confirm `BuildConfig.MAPBOX_AVAILABLE == true`
- [ ] add a real `pk.…` token to `android/config/staging.env.secrets.properties` (gitignored), rebuild
- [ ] launch the app; confirm the Map tab renders the native `MapView` (not the WebView) and the `© Mapbox © OpenStreetMap` plate is visible bottom-right
- [ ] confirm road-quality lines appear at zooms ≥10 and pothole circles at zooms ≥13 (matches the iOS source-layer min-zoom bounds in `RoadQualityStyle`)
- [ ] confirm category colors match the iOS ramp (smooth/fair/rough/very_rough match `DesignTokens.Palette` hexes)

Battery + foreground-service survivability (per OEM):

- [ ] Pixel-class device: 30-minute continuous drive, screen off; battery delta should be ≤6%. Record `adb shell dumpsys batterystats --charged ca.roadsense.android.staging | head -200` for evidence
- [ ] Samsung One UI device: same drive, same evidence; battery delta should be ≤12% per the hard-stop rule in `docs/implementation/12-android-implementation.md`
- [ ] confirm Samsung's "Put unused apps to sleep" policy does not auto-suspend the app between drives; if it does, document the user-facing setting change in the onboarding screen

If a step cannot be exercised (no device, no Play account, no `MAPBOX_DOWNLOADS_TOKEN` yet), leave the checkbox unticked and note the blocker. Do not pre-tick on the assumption it will probably work.

## Credentials You Personally Have To Create

The wiring is in the repo. These are the human-only steps that the agent cannot do for you. Each item produces a value that ends up either in `android/config/<env>.env.secrets.properties` (gitignored), in your local shell's environment variables, or as a GitHub Actions secret.

### `MAPBOX_DOWNLOADS_TOKEN` — private Maven scope

This is **not** the public `pk.…` access token the app sends with each tile request — it's a separate **secret** token (Mapbox calls them "secret tokens", prefixed `sk.…`) that authenticates Gradle against `api.mapbox.com/downloads/v2/releases/maven` so the Mapbox SDK artifacts can be fetched.

1. Sign in at `https://account.mapbox.com/`.
2. **Tokens → Create a token**.
3. Name: `roadsense-android-downloads`.
4. Scopes: enable **`DOWNLOADS:READ`** only. Leave everything else off.
5. Copy the resulting `sk.…` token immediately (it is shown only once).
6. Store it in:
   - your local shell: `export MAPBOX_DOWNLOADS_TOKEN='sk.…'` in `~/.zshrc`, or equivalently as `MAPBOX_DOWNLOADS_TOKEN=sk.…` in `~/.gradle/gradle.properties`.
   - GitHub Actions repo secrets (used by the future Mapbox-aware CI job): `gh secret set MAPBOX_DOWNLOADS_TOKEN`.
7. Resync Android Studio (or run `./gradlew help`) and confirm `BuildConfig.MAPBOX_AVAILABLE == true` — the project will now pull `com.mapbox.maps:android:11.7.0` from the private Maven and `MapboxBridge` (Mapbox-typed) will land on the classpath.

### `MAPBOX_ACCESS_TOKEN` — runtime tile auth

This is the public `pk.…` token the app embeds in every tile request URL. It does **not** authorize Maven access.

1. Same Mapbox dashboard, **Tokens → Create a token**.
2. Name: `roadsense-android-runtime`.
3. Scopes: leave the default **public** scopes selected (no `DOWNLOADS:*` scopes). The token starts with `pk.…`.
4. Add to each environment's secrets file (gitignored):
   - `android/config/staging.env.secrets.properties` → `MAPBOX_ACCESS_TOKEN=pk.…`
   - `android/config/production.env.secrets.properties` → `MAPBOX_ACCESS_TOKEN=pk.…` (can be the same token; Mapbox bills per request)
5. For the Play publishing CI workflow, also add it as a GitHub Actions repo secret: `gh secret set MAPBOX_ACCESS_TOKEN`.

### `SENTRY_DSN` — Android project DSN

The Android app already wires `SentryBootstrapper.bootstrap(...)` from `RoadSenseApp.onCreate`. It is a no-op until a DSN is configured.

1. Sign in at `https://sentry.io/` (same org as the iOS project; create a new org if you don't have one — free tier covers a small beta).
2. **Projects → Create Project** → platform **Android** → name `roadsense-android` → team your default team. Keep "Set your default rules" enabled.
3. Copy the DSN from **Settings → Projects → roadsense-android → Client Keys (DSN)**. It looks like `https://abcdef1234@o123456.ingest.sentry.io/789012`.
4. Add it to each environment's secrets file:
   - `android/config/staging.env.secrets.properties` → `SENTRY_DSN=https://…`
   - `android/config/production.env.secrets.properties` → `SENTRY_DSN=https://…`
   - Local-debug intentionally has no DSN so development crashes don't pollute the issue list.
5. Smoke-test the wiring: launch a debug build with the staging DSN configured, trigger an intentional crash (uncomment a `throw RuntimeException("sentry smoke")` line in a button handler, then revert), confirm the event lands in Sentry within ~60s.

### `GOOGLE_PLAY_JSON_KEY` — Play Developer API service account

Required by `.github/workflows/android-internal.yml` to push AABs to Internal Testing. Even if you only plan to upload by hand the first time, the workflow is the long-term path.

1. Sign in to **Google Play Console**. **Setup → API access**.
2. If you haven't linked a Google Cloud project yet, click **Create new Google Cloud project** (Play will hand you back to the API access page with the new project linked).
3. **Service accounts → Create new service account** → click through to Google Cloud Console.
4. In Cloud Console: name `roadsense-play-publisher`, role **none** (Play Console grants the permissions, not IAM). Create.
5. On the service account page **Keys → Add key → JSON**. The browser downloads `roadsense-play-publisher-….json`. Treat this file like a password.
6. Back in Play Console **API access → Grant access** for the new service account. Grant: **Release manager** at the app level. Select the `RoadSense NS` app.
7. Store the JSON:
   - `gh secret set GOOGLE_PLAY_JSON_KEY < roadsense-play-publisher-….json`
   - delete the local copy when you confirm the workflow can use it.

### `ANDROID_UPLOAD_*` — upload keystore

The four `ANDROID_UPLOAD_*` env vars (already covered later in this doc) are not third-party credentials — they're generated locally with `keytool -genkey -v -keystore upload-key.jks ...`. The keystore itself must never enter the repo.

## What To Finish Before Play Console Submission

1. Register the Google Play developer account; verify identity (current Play policy requires government ID).
2. Reserve the application id `ca.roadsense.android` (mirror of `ca.roadsense.ios`).
3. Create an `upload-key.jks` upload keystore offline; store the password and key alias in 1Password and as GitHub Actions secrets (`ANDROID_UPLOAD_KEYSTORE`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD`). The keystore itself stays out of git.
4. Confirm the privacy policy URL is live and explicitly names Android collection in the same terms as iOS.
5. Build one signed Android App Bundle (`.aab`) locally and verify `bundletool build-apks` produces an installable APK on a real Pixel before any Play upload. App Bundle is mandatory; standalone APKs are not accepted for Play distribution.
6. Run a Firebase Test Lab pre-launch report on the AAB before submitting to Internal Testing. Resolve any crashes flagged.
7. Recruit 12+ closed-testing volunteers (the same Phase 1 sideload friends qualify) and have their Google account emails ready before opening Closed Testing.

## Play Console Record

Fields that should not drift:

| Field | Value / Guidance |
|---|---|
| App name | `RoadSense NS` |
| Application id | `ca.roadsense.android` |
| Default language | `en-CA` |
| Privacy policy URL | `https://roadsense.ca/privacy` |
| Contact email | `graham.mann14@gmail.com` |
| Developer name | `RoadSense NS` (or `Graham Mann` until a developer entity exists) |
| App category | `Maps & Navigation` |
| Content rating | `Everyone` (driven by the IARC questionnaire below) |
| Account requirement | none |
| Demo credentials | N/A |
| Target SDK | API 34 (Android 14). Play policy moves the floor each year — check before each release. |
| Min SDK | API 33 (Android 13) |

Fields that still need human product judgment:

- short description (80 chars)
- full description (4000 chars)
- promotional graphics copy
- support email vs. support URL
- whether to set a "tester opt-in URL" alias

## App Content Declarations

Play Console requires every entry below before Production. Most can be answered as soon as the AAB exists.

| Declaration | Expected answer | Notes |
|---|---|---|
| Privacy policy | `https://roadsense.ca/privacy` | Must load over HTTPS, no auth wall |
| App access | "All functionality available without restrictions" | No login |
| Ads | "No ads" | Matches design principle 4 in [06-security-and-privacy.md](06-security-and-privacy.md) |
| Content rating (IARC) | Everyone | Answer "no" to violence, sexual, gambling, profanity, drug/alcohol, user-generated content sharing |
| Target audience | 13+ | Matches the iOS minors stance |
| News app | No | |
| COVID-19 contact tracing | No | |
| Data safety | See table below | Must match [06-security-and-privacy.md](06-security-and-privacy.md) |
| Government app | No | |
| Financial features | No | |
| Health | No | |
| Permissions: background location | Declared with use-case justification | See "Background Location Declaration" below |

## Data Safety Form (Play equivalent of iOS Privacy Labels)

The Play Data Safety form is *more granular* than App Store Connect. The answer set below matches the privacy labels in [06-security-and-privacy.md](06-security-and-privacy.md):

| Data type | Collected? | Shared? | Optional? | Purpose | Encrypted in transit? | User can request deletion? |
|---|---|---|---|---|---|---|
| Approximate location | No | — | — | — | — | — |
| Precise location | Yes | No | No (required for app function) | App functionality, Analytics (road quality only) | Yes (TLS) | Yes — by clearing local data and rotating device token monthly; aggregate readings auto-delete at the 6-month partition drop |
| Personal info (name, email, address, phone, identifiers) | No | — | — | — | — | — |
| Financial info | No | — | — | — | — | — |
| Health and fitness | No | — | — | — | — | — |
| Messages | No | — | — | — | — | — |
| Photos | Yes (only if user attaches a pothole photo) | No | Yes | App functionality | Yes (TLS) | Yes — local delete; server image bound to anonymous reading |
| Audio | No | — | — | — | — | — |
| Files and docs | No | — | — | — | — | — |
| Calendar | No | — | — | — | — | — |
| Contacts | No | — | — | — | — | — |
| App activity (in-app actions) | No | — | — | — | — | — |
| Web browsing | No | — | — | — | — | — |
| App info and performance | Yes (crash logs, perf diagnostics) | No | No | App functionality, Diagnostics | Yes (TLS) | No (anonymous) |
| Device or other identifiers | Yes (rotating anonymous device token) | No | No | App functionality, Fraud prevention | Yes (TLS) | Yes — token rotates monthly and is hashed server-side |

If any answer drifts from this table, [06-security-and-privacy.md](06-security-and-privacy.md) must be updated in the same PR.

## Background Location Declaration

Play requires a separate "Permissions Declaration" for `ACCESS_BACKGROUND_LOCATION`. This is reviewed by a human and is the most common reason for Play rejections in this app's category. Include all of:

- **Feature description**: "RoadSense NS measures road roughness while a user drives so it can publish aggregate road-quality maps. Background location is required so a measurement drive survives lock-screen and screen-off transitions; without it, drives end whenever the screen turns off, which is unacceptable for the core use case."
- **Use cases selected**: "Other" → describe the foreground-service-bound passive measurement model. Do NOT select "Asset tracking" (implies fleet/B2B), "Family location sharing", or "Fitness/health".
- **Demo video**: a 30–60s screen recording showing onboarding → permission grant → the persistent foreground notification appearing → driving with the screen off → the map updating after the drive ends. Hosted on YouTube unlisted; URL in the declaration.
- **Justification of why foreground-only is insufficient**: the foreground-service approach we ship already minimizes footprint — collection only runs while the persistent notification is visible. Background location is still required because Android's foreground service alone does not grant location access in the background; the runtime permission is independent.

If Play rejects, the most likely fix is sharpening the demo video — not changing the architecture.

## Internal Testing Metadata

Recommended `What's new` copy for the first Internal Testing release:

> First internal Android build. Drive normally; confirm the map, stats, privacy-zone behavior, and upload flow look plausible. Do not interact with the phone while driving.

Recommended tester notes (in the optional release notes field):

- no account is required
- background location is expected during an active drive
- the persistent "Recording road quality" notification cannot be dismissed without stopping the drive — that is intentional
- manual pothole/photo interactions must only happen while stopped
- bugs should include time, route context, OEM (Pixel/Samsung/etc.), and whether the screen was on or off

## Closed Testing Review Notes

Recommended reviewer note for the closed-testing application (the one that unlocks Production after 14 days):

> RoadSense NS measures road roughness while a user drives so it can publish aggregate road-quality maps. The app uses motion and location data together, including background location during an active drive, so collection can continue when the screen is off or the app is backgrounded. A persistent foreground-service notification is shown while a drive is active. No account or sign-in is required. Users can pause collection, define optional privacy zones, and delete all local data from Settings. Aggregate server-side data auto-deletes within 6 months via partition drop.

If Play asks why background location is necessary:

- the core function is passive drive measurement, not turn-by-turn navigation
- drives must survive screen-off and app-backgrounded transitions to produce usable data
- collection is limited to the documented road-quality use case
- users can pause collection, define privacy zones, and delete all local data
- the foreground-service notification is always shown when collection is running

## Asset Shot List

Capture from a signed AAB on a real device once UI is stable. Play requires more assets than App Store Connect — plan for all of these:

| Asset | Spec | Source |
|---|---|---|
| App icon | 512×512 PNG, 32-bit | Generated from `core` brand mark |
| Feature graphic | 1024×500 PNG/JPG, no alpha | Hero shot of the public road-quality map |
| Phone screenshots (≥2, ≤8) | 16:9 or 9:16, min 320 px, max 3840 px | Pixel 7 device |
| 7" tablet screenshots (optional but recommended) | 16:9 or 9:16 | Emulator OK |
| 10" tablet screenshots (optional) | 16:9 or 9:16 | Emulator OK |
| Promo video (optional) | YouTube URL | Same recording as the background-location declaration video, or a higher-quality cut |

Required phone screenshot subjects (mirror iOS shot list 1–5 from doc 10):

1. Ready map shell with live road-quality overlay
2. Segment detail sheet with trust/freshness context visible
3. Stats screen
4. Settings screen showing privacy/delete-local-data controls
5. Privacy zones editor or onboarding privacy explanation
6. Persistent foreground-service notification visible (shows the always-on transparency the app offers — Play reviewers respond well to this)

Rules:

- do not use lorem ipsum or broken placeholder states
- avoid screenshots that expose a home address or private route
- keep all on-screen copy aligned with the privacy policy and Data Safety answers
- screenshot 6 (notification) is what Play reviewers look for to confirm background-location use is transparent — do not omit it

## Pre-launch Verification

Before the first Internal Testing AAB upload:

1. confirm GitHub secrets exist for `ANDROID_UPLOAD_KEYSTORE` (base64-encoded), `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD`, `GOOGLE_PLAY_JSON_KEY` (Play Developer API service account), `MAPBOX_DOWNLOADS_TOKEN` (secret `sk.…` token with `DOWNLOADS:READ` scope, drives Maven access at sync time), and `MAPBOX_ACCESS_TOKEN` (public `pk.…` token, drives runtime tile auth). See "Credentials You Personally Have To Create" above for the click-path to each.
2. add `.github/workflows/android-internal.yml` mirroring `ios-testflight.yml`: builds the AAB, signs with the upload key, uploads to Internal Testing via the Play Developer API
3. dry-run the workflow with upload disabled and confirm the AAB exists and is signed (`bundletool dump manifest --bundle app-release.aab`)
4. enable upload and confirm the build appears in Play Console → Internal Testing
5. run a Firebase Test Lab pre-launch report against that build and resolve any flagged crashes
6. install via Play Internal Testing tester link on a real Pixel and complete one drive end-to-end
7. verify `targetSdkVersion` matches current Play policy (API 34 floor as of 2026)
8. verify the AAB includes the privacy-policy-aligned set of `<uses-permission>` entries — no extras (especially nothing in the [Sensitive Permissions list](https://support.google.com/googleplay/android-developer/answer/9888170))

## First Internal Build Checklist

Before uploading a build to Internal Testing:

1. latest `main` is green in repo CI and local smoke checks
2. privacy policy is published and explicitly names Android
3. Play Console record exists with the final application id
4. Data Safety answers match [06-security-and-privacy.md](06-security-and-privacy.md)
5. background-location permissions declaration includes the demo-video URL
6. `What's new` text is filled in
7. no sign-in/demo credentials are declared
8. one signed AAB has been installed locally on a Pixel via `bundletool` and opened successfully
9. one signed AAB has been installed on a non-Pixel (Samsung One UI is the second tier we test against) and opened successfully

## First Closed Testing Build Checklist

Before promoting from Internal to Closed Testing (which starts the 14-day production-access timer):

1. at least one Internal Testing build cycle is complete with no crashes from real-device drives
2. crash and log review show no forbidden PII leakage
3. privacy policy URL is live and matches the in-app story
4. screenshots are current (including the persistent-notification screenshot)
5. background-location permissions declaration video is live and accurately reflects current onboarding
6. ≥12 closed-testing volunteers have opted in via the Play tester link
7. internal field-test evidence exists in the shape described by [09-internal-field-test-pack.md](09-internal-field-test-pack.md), with at least one Android-specific drive logged
8. Firebase Test Lab pre-launch report shows zero blocking issues
9. Sentry Android DSN is configured and a real crash from a debug build has been observed in the dashboard (proves the wiring works before Closed Testing volunteers find one)

## Production Promotion Checklist

Production access is gated by Play's 14-day, 12-tester rule. Before promoting from Closed Testing to Production:

1. ≥14 continuous days have elapsed since Closed Testing opened with ≥12 active testers throughout
2. zero unresolved crashes in the last 7 days (Sentry + Play vitals)
3. Play vitals "Bad behavior" thresholds are clean: ANRs < 0.47%, crashes < 1.09%, slow rendering within Play guidance
4. battery-drain field evidence on at least Pixel + Samsung shows ≤12% in a 30-minute drive (matches the hard-stop rule in [12-android-implementation.md](12-android-implementation.md))
5. iOS launch criteria are met or production-deferred-on-purpose is explicitly recorded — we don't promote Android ahead of iOS unless that decision is made consciously
6. Production rollout starts at 10%, escalates to 50% only after 48h with no regressions, then 100% after another 48h

## Deferred On Purpose

These are not worth front-loading before Internal Testing:

- polishing external-tester support workflows before the first Internal Testing build exists
- localizing store listing into French (the iOS doc 0002 ADR locks us to English-only for v1)
- App Bundle dynamic feature modules — single AAB is fine until install size or feature-flag work demands it
- Play Games Services / Play Billing — not applicable

## Go / No-Go

`Go` for the first Internal Testing AAB when:

- Play Console developer account is verified
- the Play Console listing record is created with the final application id
- Data Safety answers and privacy policy are aligned
- one signed AAB passes the bundletool install check
- Sentry Android DSN is wired and proven

`Go` for promotion to Closed Testing when:

- Internal Testing has produced at least one full clean drive
- background-location permissions declaration with demo video is submitted
- ≥12 testers are queued and ready to opt in

`Go` for promotion to Production when:

- the 14-day, 12-tester Closed Testing window has elapsed
- crash/ANR vitals are clean
- battery-drain real-device evidence meets the hard-stop bar in [12-android-implementation.md](12-android-implementation.md)

`No-go` if any of these are still unresolved:

- privacy policy URL missing, stale, or doesn't name Android
- Data Safety answers differ from [06-security-and-privacy.md](06-security-and-privacy.md)
- background-location permissions declaration rejected or with a stale demo video
- signed AAB not yet validated on a real Pixel and at least one Samsung
- Sentry Android wiring untested
- Closed Testing volunteer count below 12 or window shorter than 14 continuous days
- Play vitals (crashes, ANRs) above policy thresholds in the trailing 7 days
