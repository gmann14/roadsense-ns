# App Store Submission Package

Use a public-release build with marketing version `1.0` for the first App Store submission. The current TestFlight build `0.1.0 (22)` is good for beta testing, but App Store Connect is already set up as iOS App Version `1.0`, so upload/select a matching build such as `1.0 (23)`.

## Product Page

- App name: `RoadSense NS`
- Subtitle: `Community road-quality map`
- Category: Travel
- Secondary category: Utilities
- Support URL: `https://nsroadsense.ca`
- Marketing URL: `https://nsroadsense.ca`
- Privacy Policy URL: `https://nsroadsense.ca/privacy`
- Copyright: `© 2026 Graham Mann`

Localized metadata lives under `ios/fastlane/metadata/en-CA/`.

## Screenshots

Generate the 6.5-inch iPhone screenshots with:

```bash
scripts/render-app-store-screenshots.sh
```

The generated App Store PNGs are written to `ios/fastlane/screenshots/en-CA/` at `1284x2778`.

Upload these screenshots to the iPhone 6.5-inch screenshot slot:

1. `appstore-active-drive.png`
2. `appstore-idle-between-drives.png`
3. `appstore-just-marked-a-pothole.png`
4. `appstore-first-run.png`

## App Privacy

Use the policy source of truth in `docs/implementation/06-security-and-privacy.md`.

Data collected:

- Precise Location: linked to user, not used for tracking, purpose App Functionality
- Crash Data: not linked to user, not used for tracking, purpose App Functionality
- Performance Data: not linked to user, not used for tracking, purpose App Functionality

Do not select Contact Info, Health & Fitness, Financial Info, User Content, Browsing History, Search History, Identifiers, Purchases, or Usage Data unless the implementation changes.

## App Review Notes

No account or demo credentials are required.

RoadSense NS measures road roughness while a user drives so it can publish aggregate road-quality maps. The app uses motion and location data together, including background location during an active drive, so collection can continue after the screen locks or the app backgrounds. Users can pause collection, define optional privacy zones, and delete local app data from Settings. Pothole photo capture is optional and should only be used while stopped.

## Export Compliance

The app uses standard Apple platform networking/HTTPS and does not include custom or proprietary cryptography. Answer export-compliance questions accordingly in App Store Connect.

## Rating, Pricing, And Review

- Age rating: answer the content questionnaire as no objectionable content, no gambling, no unrestricted web access, no medical or treatment information, and no commerce. The expected rating is `4+` unless Apple changes the questionnaire result.
- Pricing: Free.
- In-app purchases/subscriptions: none.
- App Review contact: use the account owner's current phone/email in App Store Connect.
- Demo credentials: not applicable; no account is required.
- Release option: choose manual release if you want one last check after approval, or automatic release if the goal is to go public as soon as Apple approves it.

## Final Manual Checks

- Confirm no new TestFlight crash cluster exists for the selected build.
- Confirm the selected production build was created with `SENTRY_DSN` present in GitHub Actions.
- Upload/select a `1.0` build for version `1.0` in App Store Connect.
- The GitHub workflow can create one by running `iOS TestFlight` with `Production Release`, `build_number` set to the next unused number, and `marketing_version` set to `1.0`.
- Set pricing to Free.
- Confirm availability countries/regions.
- Complete Age Rating.
- Complete App Privacy.
- Complete App Accessibility if App Store Connect requires it.
- Add screenshots and metadata.
- Submit for App Review.

## Crash Triage Before Review

If testers report crash notices, pause App Store submission until one of these sources confirms the cause:

- App Store Connect: `RoadSense NS` -> `TestFlight` -> `Crashes`, filter to the affected build, open the newest crash group, and download/share the stack trace.
- Tester device: `Settings` -> `Privacy & Security` -> `Analytics & Improvements` -> `Analytics Data`, search for `RoadSense`, then share the newest `.ips` file.
- Sentry: verify the GitHub secret `SENTRY_DSN` is set before cutting the next production build, then use Sentry issues/events for the crash stack.
