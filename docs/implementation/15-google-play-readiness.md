# 15 — Google Play Readiness

*Last updated: 2026-11-08 (permissions trimmed to foreground-only location, target SDK 35, Data Safety and foreground-service declaration rewritten, production hosts moved to `nsroadsense.ca`)*

Covers: the release-ops source of truth for Google Play Console approval, store listing fields, Data Safety form, App Content questionnaires, reviewer notes, screenshots/feature graphic, and the first internal/closed testing cycles.

This doc is the Android twin of [10-app-store-and-testflight-readiness.md](10-app-store-and-testflight-readiness.md). Build-level architecture lives in [12-android-implementation.md](12-android-implementation.md); this doc turns release-time policy into a concrete checklist and copy. [06-security-and-privacy.md](06-security-and-privacy.md) remains the canonical privacy source of truth — the Data Safety answers below must match it.

## Current Status

- Native Mapbox vector-tile + pothole overlay rendering wiring landed on `gmann14/android-beta-test-fixes`. The Compose `MapHost` calls into `MapboxBridge` (`android/app/src/mapboxMain/kotlin/`) which is compiled in whenever `MAPBOX_DOWNLOADS_TOKEN` is set at sync time; otherwise the no-Mapbox stub keeps reporting unavailable so CI keeps building. Real-device verification on a Pixel still pending — see "Real-device validation checklist" below.
- Google Play Console developer account not yet created. One-time $25 fee applies.
- New developer accounts created after 2023-11-13 must complete Closed Testing with **at least 12 testers opted in for at least 14 continuous days** before Production access is granted. Plan around that gate from day one.
- No Android signing keys exist. Sideload (Phase 1 of doc 12) uses a debug-style keystore at `android/keystores/dev.keystore` (gitignored). Play distribution (Phase 2) uses Google Play App Signing — we hold an **upload key**, Google holds the app-signing key.
- Build wiring for the upload key is in place: `android/app/build.gradle.kts` registers a `signingConfigs.upload` block iff `ANDROID_UPLOAD_KEYSTORE_PATH` + `ANDROID_UPLOAD_KEYSTORE_PASSWORD` + `ANDROID_UPLOAD_KEY_ALIAS` + `ANDROID_UPLOAD_KEY_PASSWORD` are exported. CI deliberately runs without those env vars so PR builds keep working without the upload key.
- `.github/workflows/android-internal.yml` exists as the manually-dispatched workflow that builds the production-flavor AAB and (when the `ANDROID_PUBLISH_ENABLED` repo variable is `true`) uploads it to Internal Testing via the Play Developer API. It is dormant until the secrets below are populated.
- The project's domain is **`nsroadsense.ca`** (API: `https://api.nsroadsense.ca`, web: `https://nsroadsense.ca`). The similarly named domain without `ns` belongs to an unrelated third party — never put it in a listing field, a declaration or the app.
- `https://nsroadsense.ca/privacy` covers the iOS app and is acceptable for Android too. Confirm the page mentions Android by name, and describes the deletion-request path used in the Data Safety answers below, before the first Closed Testing submission.
- `apps/web` hosts the privacy policy. The app's Settings screen also links `https://nsroadsense.ca/terms` and `https://nsroadsense.ca/support`; both pages must exist before the first Play upload. No Android-specific marketing site is required.
- Permissions are foreground-only (see "Permissions the AAB declares"). There is **no** background-location permission and therefore no background-location declaration; the only sensitive declaration is the foreground-service (location) declaration.

## Real-device validation checklist (unverified — no field evidence yet)

These steps are blocked on access to physical Android devices and an active Play developer account. They are intentionally not faked. Owner / date / device fingerprint must be filled in by the engineer running the drive — do not copy a stale "OK" from a prior cycle.

Foreground collection + permission ladder (Pixel-class device):

- [ ] install the latest staging-debug APK (`./gradlew :app:installStagingDebug`)
- [ ] grant precise location and notifications when prompted (one system dialog; there is no "Allow all the time" step)
- [ ] choose "Approximate" once on a second install; confirm the Map tab says precise location is needed and the button opens app settings
- [ ] confirm the persistent "Recording road quality" notification appears within 2 seconds of tapping Start
- [ ] confirm the notification cannot be dismissed without tapping Stop
- [ ] drive ≥10 minutes, screen on; confirm GPS fix card updates at ≥1 Hz cadence and the recording indicator stays green
- [ ] drive ≥10 minutes, screen off (locked); confirm the foreground service is still running on return — task manager + adb shell `dumpsys activity services ca.roadsense.android.staging | head` shows `running=true`, and readings kept arriving (Stats → Local pending grows)
- [ ] tap Stop; confirm pending readings count drops to 0 within a few minutes (a one-shot upload is queued at drive end) and the upload result card surfaces no errors

Auto drive end:

- [ ] start a drive, park and leave the phone still for ≥6 minutes; confirm the drive's readings become uploadable (pending count drains) without tapping Stop, and that driving off again starts a new drive
- [ ] force-stop the app mid-drive (`adb shell am force-stop ca.roadsense.android.staging`), reopen it; confirm the "Recording" state is cleared and the interrupted drive's readings upload

Manual pothole + feedback + delete flows:

- [ ] tap "Mark pothole here" while stopped; confirm the 8-second undo appears and clears on its own
- [ ] tap "Mark pothole here" then "Undo last report" within 8 seconds; confirm no upload happens
- [ ] submit a feedback message offline (airplane mode), enable network, confirm it drains on the next heartbeat
- [ ] Settings → Delete all local data, during an active drive and again with location permission revoked; confirm no crash, pending counts read 0, and recording is stopped

Upload acceptance against staging backend:

- [ ] after the first clean ≥10 minute drive, open the public map at `https://nsroadsense.ca` and confirm the segments the device covered show up within ~15 minutes
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
2. Reserve the application id. The build currently uses `ca.roadsense.android` (mirror of `ca.roadsense.ios`). An application id can never change after the first upload, and its reverse-DNS reads as the third-party `roadsense` .ca domain; decide whether to keep it or switch to an id under `nsroadsense.ca` (for example `ca.nsroadsense.android`) **before** the first upload.
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
| Privacy policy URL | `https://nsroadsense.ca/privacy` |
| Website | `https://nsroadsense.ca` |
| Contact email | `graham.mann14@gmail.com` |
| Developer name | `RoadSense NS` (or `Graham Mann` until a developer entity exists) |
| App category | `Maps & Navigation` |
| Content rating | `Everyone` (driven by the IARC questionnaire below) |
| Account requirement | none |
| Demo credentials | N/A |
| Target SDK | API 35 (Android 15) in the build today. Play's rule: new apps and updates must target within one year of the latest major Android release, enforced each 31 August (API 35 from 31 Aug 2025; API 36 is expected from 31 Aug 2026). **Check Play Console → Policy status before the first upload**; if the floor is 36, upgrade AGP to 8.9+ and set `compileSdk`/`targetSdk` 36 first. |
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
| Privacy policy | `https://nsroadsense.ca/privacy` | Must load over HTTPS, no auth wall |
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
| Foreground service permissions | `FOREGROUND_SERVICE_LOCATION`, declared with use case + video | See "Foreground Service (Location) Declaration" below |
| Location permissions (background) | Not applicable — the app does not request `ACCESS_BACKGROUND_LOCATION` | Play only shows this form when the permission is in the manifest; `ManifestPermissionsTest` keeps it out |

## Permissions the AAB declares

The merged manifest must contain exactly these (`ManifestPermissionsTest` fails the unit-test run on any drift; re-check with `bundletool dump manifest` on the signed AAB):

| Permission | Why |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Upload readings; WorkManager's "connected" constraint |
| `ACCESS_FINE_LOCATION` | GPS fixes during a drive the user started |
| `ACCESS_COARSE_LOCATION` | Android 12+ rejects a fine-only request; the app needs precise and asks the user to upgrade if they choose "Approximate" |
| `POST_NOTIFICATIONS` | The persistent "Recording road quality" notification (Android 13+) |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | The `location`-type foreground service that keeps a user-started drive recording with the screen off |

Not requested, on purpose: `ACCESS_BACKGROUND_LOCATION` (a drive is always started from the app's own screen, so the foreground service has location access without it), `ACTIVITY_RECOGNITION` (no automatic drive detection — drives end after 5 minutes parked or on Stop), `CAMERA` (pothole photos are off in every build; re-adding it needs a Data Safety and privacy-policy update first).

## Data Safety Form (Play equivalent of iOS Privacy Labels)

The Play Data Safety form is *more granular* than App Store Connect. Answer it from what the shipped build actually sends:

**Overview questions**

- Does the app collect or share any of the required user data types? **Yes**
- Is all of the user data collected by the app encrypted in transit? **Yes** (staging and production API, Sentry and Mapbox are all HTTPS; the manifest sets no cleartext override, so Android blocks plain HTTP at target SDK 35)
- Do you provide a way for users to request that their data be deleted? **Yes** — Settings → "Delete all local data" removes everything on the device immediately; for server-side data, users email the contact address in the privacy policy (graham.mann14@gmail.com) with their request, and all raw readings are deleted automatically within 6 months by the partition drop. The privacy policy must describe this path.
- Is data shared with third parties? **No** for every type below. Sentry (crash reporting) and the hosting providers act as service providers processing data on the developer's behalf, which Play does not count as sharing. Nothing is sold.

**Data types**

| Data type | Collected? | Shared? | Required or optional | Purpose | Notes |
|---|---|---|---|---|---|
| Location → Precise location | Yes | No | Required | App functionality | GPS points with motion roughness, only while a user-started drive is recording, after on-device privacy-zone filtering and start/end trimming. Not tied to an account. |
| Location → Approximate location | No | — | — | — | `ACCESS_COARSE_LOCATION` is declared only because Android requires it alongside fine; no approximate location is sent |
| Personal info → Email address | Yes | No | Optional | Developer communications | Only if the user types a reply address into the in-app feedback form |
| Personal info → name, address, phone, race, religion, other info | No | — | — | — | — |
| Messages → Other in-app messages | Yes | No | Optional | Developer communications, App functionality | The text of in-app feedback the user chooses to send |
| Photos and videos | No | — | — | — | Pothole photos are disabled in every Android build. If they are ever enabled, add Photos (optional, app functionality) and `CAMERA` in the same release |
| Financial info, Health and fitness, Audio, Files and docs, Calendar, Contacts, Web browsing | No | — | — | — | — |
| App activity | No | — | — | — | No analytics SDK; pothole reports are part of the location readings above |
| App info and performance → Crash logs | Yes | No | Required | Analytics (stability) | Sentry crash reports; coordinates, tokens, emails and feedback text are scrubbed before send (`SentryBootstrapper.scrub`) |
| App info and performance → Diagnostics | Yes | No | Required | Analytics (stability) | Sentry device/OS/app-version context attached to crash reports; no performance tracing |
| Device or other IDs | Yes | No | Required | App functionality, Fraud prevention | Random UUID device token, rotated every 30 days, hashed server-side; not an advertising ID or hardware ID |

**Deletion answers**: data is not deleted automatically when the app is uninstalled from the server's side, so describe the 6-month automatic deletion plus the email request path; on-device data is removed on uninstall or via Settings.

[06-security-and-privacy.md](06-security-and-privacy.md) is still the canonical privacy source. It currently says the app collects no email; the optional feedback reply address above must be added there (and to the privacy policy) before this form is submitted. If any answer drifts from the shipped build, update this table, doc 06 and the privacy policy together.

## Foreground Service (Location) Declaration

Apps targeting API 34+ that declare `FOREGROUND_SERVICE_LOCATION` must complete Play Console → App content → **Foreground service permissions**. This is the only sensitive-permission declaration the app needs; there is no background-location declaration because `ACCESS_BACKGROUND_LOCATION` is not requested.

- **Foreground service type**: Location.
- **Task / use case**: user-initiated, user-visible recording of a drive. Suggested description: "RoadSense NS measures road roughness while the user drives and publishes an aggregate road-quality map. The user taps Start on the app's main screen before driving; a location foreground service with a persistent notification keeps measuring GPS position and phone motion while the screen is off, and stops when the user taps Stop or after 5 minutes parked. Collection never starts on its own."
- **Why it can't be deferred or interrupted**: the measurement only has value while the car is moving; WorkManager or a deferred job would miss the drive, and stopping when the screen turns off would end every drive in a phone mount.
- **Demo video** (30–60 s, YouTube unlisted, URL in the declaration). Show, in order: opening the app → granting precise location and notifications → tapping Start → the persistent "Recording road quality" notification → locking the screen during a drive (passenger-held phone or simulated route) → unlocking to show recording continued → tapping Stop (or waiting out the 5-minute parked auto-end) and the notification disappearing. Record on a staging build with no home address or private route visible; redo the video whenever the Start/Stop flow or notification text changes.

If Play rejects, the most likely fix is sharpening the demo video so the user-initiated start and the visible notification are unmistakable — not adding permissions.

## Internal Testing Metadata

Recommended `What's new` copy for the first Internal Testing release:

> First internal Android build. Drive normally; confirm the map, stats, privacy-zone behavior, and upload flow look plausible. Do not interact with the phone while driving.

Recommended tester notes (in the optional release notes field):

- no account is required
- tap Start before each drive; recording continues with the screen off and ends on Stop or after 5 minutes parked
- the app only asks for location "while using the app" — testers should never see an "Allow all the time" prompt; report it if they do
- the persistent "Recording road quality" notification cannot be dismissed without stopping the drive — that is intentional
- manual pothole reports must only happen while stopped (photos are off in this build)
- bugs should include time, route context, OEM (Pixel/Samsung/etc.), and whether the screen was on or off

## Closed Testing Review Notes

Recommended reviewer note for the closed-testing application (the one that unlocks Production after 14 days):

> RoadSense NS measures road roughness while a user drives so it can publish aggregate road-quality maps. The user starts each drive by tapping Start in the app; a location foreground service with a persistent notification then keeps measuring while the screen is off, and stops when the user taps Stop or after 5 minutes parked. The app does not request background location or activity recognition and never starts collecting on its own. No account or sign-in is required. Users can define optional privacy zones and delete all local data from Settings. Raw server-side readings auto-delete within 6 months via partition drop.

If Play asks about location use:

- the core function is user-started drive measurement, not turn-by-turn navigation or tracking
- location is only used while the user-started foreground service runs, with its notification visible
- no `ACCESS_BACKGROUND_LOCATION` is requested; the foreground service type is `location`
- collection is limited to the documented road-quality use case
- users can define privacy zones and delete all local data

## Asset Shot List

Capture from a signed AAB on a real device once UI is stable. Play requires more assets than App Store Connect — plan for all of these:

| Asset | Spec | Source |
|---|---|---|
| App icon | 512×512 PNG, 32-bit | Generated from `core` brand mark |
| Feature graphic | 1024×500 PNG/JPG, no alpha | Hero shot of the public road-quality map |
| Phone screenshots (≥2, ≤8) | 16:9 or 9:16, min 320 px, max 3840 px | Pixel 7 device |
| 7" tablet screenshots (optional but recommended) | 16:9 or 9:16 | Emulator OK |
| 10" tablet screenshots (optional) | 16:9 or 9:16 | Emulator OK |
| Promo video (optional) | YouTube URL | Same recording as the foreground-service declaration video, or a higher-quality cut |

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
- screenshot 6 (notification) is what Play reviewers look for to confirm the location foreground service is user-visible — do not omit it

## Pre-launch Verification

Before the first Internal Testing AAB upload:

1. confirm GitHub secrets exist for `ANDROID_UPLOAD_KEYSTORE` (base64-encoded), `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD`, `GOOGLE_PLAY_JSON_KEY` (Play Developer API service account), `MAPBOX_DOWNLOADS_TOKEN` (secret `sk.…` token with `DOWNLOADS:READ` scope, drives Maven access at sync time), and `MAPBOX_ACCESS_TOKEN` (public `pk.…` token, drives runtime tile auth). See "Credentials You Personally Have To Create" above for the click-path to each.
2. add `.github/workflows/android-internal.yml` mirroring `ios-testflight.yml`: builds the AAB, signs with the upload key, uploads to Internal Testing via the Play Developer API
3. dry-run the workflow with upload disabled and confirm the AAB exists and is signed (`bundletool dump manifest --bundle app-release.aab`)
4. enable upload and confirm the build appears in Play Console → Internal Testing
5. run a Firebase Test Lab pre-launch report against that build and resolve any flagged crashes
6. install via Play Internal Testing tester link on a real Pixel and complete one drive end-to-end
7. verify `targetSdkVersion` meets current Play policy: the build targets API 35; if Play Console shows a 36 requirement, upgrade AGP to 8.9+ and target 36 before uploading
8. verify the AAB's `<uses-permission>` entries are exactly the list in "Permissions the AAB declares" — no extras (especially nothing in the [Sensitive Permissions list](https://support.google.com/googleplay/android-developer/answer/9888170))

## First Internal Build Checklist

Before uploading a build to Internal Testing:

1. latest `main` is green in repo CI and local smoke checks
2. privacy policy is published and explicitly names Android
3. Play Console record exists with the final application id
4. Data Safety answers match [06-security-and-privacy.md](06-security-and-privacy.md)
5. foreground-service (location) declaration includes the demo-video URL
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
5. foreground-service (location) declaration video is live and accurately reflects the current Start/Stop flow and notification
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
- foreground-service (location) declaration with demo video is submitted
- ≥12 testers are queued and ready to opt in

`Go` for promotion to Production when:

- the 14-day, 12-tester Closed Testing window has elapsed
- crash/ANR vitals are clean
- battery-drain real-device evidence meets the hard-stop bar in [12-android-implementation.md](12-android-implementation.md)

`No-go` if any of these are still unresolved:

- privacy policy URL missing, stale, or doesn't name Android
- Data Safety answers differ from [06-security-and-privacy.md](06-security-and-privacy.md)
- foreground-service (location) declaration rejected or with a stale demo video
- `/terms` or `/support` pages linked from Settings still missing on `nsroadsense.ca`
- application-id decision not made
- signed AAB not yet validated on a real Pixel and at least one Samsung
- Sentry Android wiring untested
- Closed Testing volunteer count below 12 or window shorter than 14 continuous days
- Play vitals (crashes, ANRs) above policy thresholds in the trailing 7 days
