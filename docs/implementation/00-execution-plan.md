# 00 — Execution Plan

*Last updated: 2026-04-17*

## Objective

Ship a private TestFlight build to 20–50 Halifax-area beta testers within **8 weeks**, with end-to-end data flow working: drive → on-device processing → upload → server map-matching → aggregate update → vector tile served → rendered on device.

"Done" for MVP is defined in §Release Criteria at the bottom of this doc. It's deliberately narrower than the full product spec — the goal is a real, dogfoodable loop that we can iterate on in public, not feature completeness.

For literal task order and acceptance-criteria slicing, use [08-implementation-backlog.md](08-implementation-backlog.md) alongside this roadmap.

## Guiding Principles

1. **Own the critical path ruthlessly.** Backend schema, OSM import, and vector tile plumbing block everything. Start them week 1, even before the iOS client is collecting real data.
2. **Ship the boring path first.** Skeleton end-to-end loop (with fake/stub scoring) before polishing any single layer.
3. **Calibrate early with real driving.** The roughness thresholds in the spec are guesses. Drive a known-bad road in week 3 and look at the data before writing the UI.
4. **Privacy-first defaults are cheaper to implement than to retrofit.** Ship with 500m zones, randomized offsets, WiFi-only upload from day one.
5. **Observability before scale.** Logs/metrics in place before first outside tester. A silent failure in a civic-data app is worse than a loud one.

## Critical Path (8 Weeks)

```
Week 1 ──┬─ Apple Developer Program enrollment (Day 1 — can take 48h)
         ├─ Domain purchased (`roadsense.ca`)
         ├─ Supabase project + PostGIS + schema migrations 001–008 applied
         ├─ Xcode project skeleton + SPM deps (Mapbox, Supabase, Sentry) — builds empty shell
         └─ HRM-only OSM import (proof-of-concept, not full NS)

Week 2 ──┬─ Full NS OSM import pipeline (osm2pgsql → 50m segments, all HRM + rest of NS)
         ├─ App Store Connect app record created (bundle ID ca.roadsense.ios — matches the placeholder used throughout 01/05)
         ├─ Ingestion edge function (validation, rate limit, stub)
         ├─ Stored procedure skeleton (map matching, aggregate upsert)
         ├─ iOS: permission flow + CMMotionActivity + CLLocationManager
         └─ CI (GitHub Actions) with lint + typecheck

Week 3 ──┬─ End-to-end smoke test: stub reading → upload → aggregate
         ├─ iOS: gravity-compensated accel collection, SwiftData schema
         ├─ Vector tile endpoint (ST_AsMVT) with caching
         └─ First calibration drive — collect raw accel + GPS on 5 known roads

Week 4 ──┬─ Roughness scoring algorithm tuned against calibration data
         ├─ iOS: Mapbox map view with vector tile source
         ├─ Privacy zone filtering + batched upload queue
         └─ Nightly aggregate recompute job

Week 5 ──┬─ UI polish pass: onboarding, permission prompts, empty states
         ├─ Segment detail view + stats screen
         ├─ Upload retry + exponential backoff + resume
         ├─ Rate limiting + plausibility checks hardened
         └─ First TestFlight INTERNAL build: 5–10 internal testers (self + family)
            — no Apple review needed; builds available ~15 min after upload

Week 6 ──┬─ Internal dogfood: 3–5 team devices for 5 days
         ├─ Sentry Cocoa + Deno SDKs wired (projects created, DSNs in secrets)
         ├─ Structured batch logs (JSON one-line-per-batch) + ops_metrics counters
         ├─ Supabase Studio dashboard + external uptime ping on /health
         ├─ Battery impact measurement on 2 device classes (old + new)
         └─ Pothole spike detection + pothole_reports ingestion

Week 7 ──┬─ Fix top issues from dogfood
         ├─ Privacy policy published + in-app copy
         ├─ Expand internal TestFlight to ~30 testers (friends, neighbours)
         └─ App Store Connect metadata (screenshots, description)

Week 8 ──┬─ Submit for Beta App Review (external TestFlight) — typically 24–48h
         ├─ On approval, expand tester pool to 20–50 via public link
         └─ Launch monitoring + support channel (GitHub issues)
```

## Parallelizable Workstreams

If you add a second engineer, split along this seam:

- **Engineer A (iOS-heavy):** sensor pipeline, scoring, SwiftUI, Mapbox, upload queue
- **Engineer B (backend-heavy):** Supabase, OSM import, stored procedures, tile endpoint, observability

They converge at week 3 on the API contract ([03-api-contracts.md](03-api-contracts.md)) — lock that shape by end of week 2 so it doesn't churn.

## Decisions to Lock by Week 2

These are reversible-but-expensive choices. Make them early and explicitly:

1. **[DECISION] Mapbox account tier.** Free (< 50k MAU) for MVP. Confirmed — but sign up for the account week 1 so the SDK key isn't blocking in week 3.
2. **[DECISION] Supabase region.** `us-east-1` (Halifax → US East has lowest latency vs. EU or west coast). Lock before any migrations run.
3. **[DECISION] `batch_id` generation.** Client generates UUIDv4 per batch; server enforces uniqueness for idempotent retries. See [03-api-contracts.md](03-api-contracts.md).
4. **[DECISION] Device token rotation cadence.** Monthly, generated on device, sent as a cleartext UUID over TLS, and hashed with a server-side pepper inside the upload Edge Function before persistence. Rotation means one person = multiple contributor counts over time; accept this.
5. **[DECISION] OSM snapshot date for MVP.** Pin a specific Geofabrik `nova-scotia-latest.osm.pbf` download date in the import script (lets us reproduce segment IDs). Refresh quarterly after launch.
6. **[DECISION] Bundle ID / app name.** Lock to bundle ID `ca.roadsense.ios`, display name `RoadSense NS`, and public site domain `roadsense.ca`. Use those values consistently across App Store Connect, privacy policy, screenshots, and deployment config.
7. **[DECISION] Platform: iOS native first.** Decision made. Swift + SwiftUI + CoreMotion + CoreLocation. No React Native / Flutter for MVP. Rationale: raw-sensor access and tight battery control are the differentiator; cross-platform frameworks add friction with no upside in our 8-week window. Android follow-on starts week 9 (see §Android Follow-On below).

## Risks to Watch (and Trip-Wires)

Ranked by likelihood × impact. Each has an explicit detection signal so we can course-correct without panicking.

| Risk | Trip-wire | Response |
|---|---|---|
| App Store rejects background-location justification | TestFlight external review takes > 3 days or returns rejection | Have a pre-written justification draft ready by week 6 citing SmartRoadSense precedent. Prep a foreground-only fallback variant of the app. |
| Battery drain > 15%/hr on older devices | iPhone 12-class device drops below 80% after 1-hour calibration drive | Cut GPS to 0.5Hz on low-battery mode, increase accelerometer buffer flush to 10min, ship with `kCLLocationAccuracyHundredMeters` for initial bootstrap |
| OSM segment count blows up the database | NS road import > 500k segments or DB > 1.5GB after first aggregate pass | Drop residential-minor roads below zoom 14, simplify geometry at import time, enable `ST_SnapToGrid` at 1m precision |
| Crowdsourced data is too noisy to score | After 100+ calibration readings on known roads, cross-user score variance > 30% | Introduce vehicle-type tag, lengthen aggregation window to 100m, require 5+ contributors before publishing a score |
| iOS kills background process too aggressively | Test device stops collecting within 30min of backgrounding on 3+ occasions | Register `significantLocationChange` as relaunch; add foreground-only "Recording" sticky mode as fallback |
| Supabase Edge Function exceeds 150ms CPU for batch matching | p95 upload latency > 2s or timeout errors | Confirmed assumption: move matching to stored procedure. If procedure itself is slow, add KNN bbox prefilter + a `_segments_subset` materialized view for Halifax only. |
| Privacy zone triangulation concern raised by a user/press | Any mention of reverse-engineering home address from gaps | Already mitigated with randomized offset; prepare a 200-word explainer before launch. |

## Milestones & Acceptance Criteria

### M1 — "Dial tone" (end of week 2)

- Supabase project exists, migrations applied, `road_segments` table populated for HRM only (we expand later)
- iOS project builds and runs; permission prompts render; dummy upload to `/upload-readings` with 1 hardcoded reading returns 200
- CI green

### M2 — "End-to-end stub" (end of week 3)

- Real driving from an iPhone produces readings in `readings` table
- `segment_aggregates` updates after upload
- Vector tile endpoint returns MVT with at least 1 colored segment
- Roughness score is stubbed (constant or random); real scoring comes next

### M3 — "Roughness is believable" (end of week 4)

- Calibration drive on 3 known-bad and 3 known-good roads produces visually distinct colors
- Privacy zones filter readings (verified by mock drive-through)
- Upload queue survives offline → online transition

### M4 — "Dogfoodable" (end of week 5)

- 2+ team members running the app daily without crashes
- Map renders smoothly at all zoom levels in Halifax
- Settings screen works; users can delete local data

### M5 — "Internal beta ready" (end of week 6)

- Sentry capturing crashes
- Battery drain measured and documented
- Pothole detection produces reasonable flagging (manual review)

### M6 — "TestFlight submitted" (end of week 7)

- Privacy policy live at a public URL
- App Store Connect metadata complete
- TestFlight build uploaded and processed

### M7 — "External beta live" (end of week 8)

- TestFlight external review approved
- 20–50 invites sent
- Public GitHub issues open for bug reports

## Release Criteria (MVP definition)

We ship TestFlight beta when all of these are true:

1. App successfully collects, processes, and uploads readings for at least 1 hour of driving on 2+ iPhone models (one ≥ 4 years old)
2. Server assigns ≥ 95% of valid uploaded readings to a segment within 20m
3. Map renders Halifax roads with ≥ 50 segments showing community scores (aggregated from team dogfood)
4. Privacy policy published; no PII stored server-side (verified by schema review)
5. Crash-free rate > 99% across internal dogfood (Sentry)
6. p95 upload batch latency < 4s for 1000 readings (warm Edge Function). This soft target allows for cold-start overhead on Deno Deploy and the 1000-row KNN pass. If we land below 2s we should, but don't gate launch on the tighter number without measurement.
7. Battery drain during active driving < 15%/hr on iPhone 12 Pro (our "reference" device class)
8. App Store privacy labels accurate and match what the app actually does

## What We Do NOT Block Launch On

To stay disciplined about scope, these are explicitly NOT gating criteria:

- Android client
- Web dashboard
- Perfect IRI-correlated scoring — "relative roughness that looks right on known roads" is enough
- Vehicle-type tagging
- Municipal data sharing agreement
- Open-sourcing the repo (do it right after launch — less pressure on code quality for v0.1)

## Post-Launch Immediate Roadmap (weeks 9–12)

Not part of MVP delivery, but the "what's next" so we can answer users asking:

- Open-source the repo
- Expand beyond HRM to Cape Breton Regional Municipality
- "Worst roads in Halifax" automated report → local media outreach
- First municipal contact (informal — not a commercial deal)
- Web dashboard for public + municipal aggregation (see next section)
- Android client (see below)

## Web Dashboard Direction (Phase 2+)

The web interface is **not** a clone of the phone app. The phone is for passive collection and quick visualization; the web is where we aggregate, explain, compare, and publish.

Detailed UX and implementation guidance lives in [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md). This section exists to keep roadmap and product-shape assumptions aligned with the week-by-week plan.

Primary audiences:

- **Public explorer** — "what roads near me are rough?"
- **Journalist / advocate** — "what neighborhoods or corridors look worst, and is it getting better or worse?"
- **Municipal / public-works viewer** — "where do we have confident signal, where is coverage thin, and what changed recently?"

### UX goals

1. **Explain the map in one screen.** A first-time visitor should understand the color scale, confidence, and freshness without reading a whitepaper.
2. **Make trust visible.** Show confidence, last-updated times, methodology link, and coverage caveats prominently.
3. **Support scanning before analysis.** The first experience is visual discovery; tables and exports come second.
4. **Stay public-facing.** Avoid "enterprise dashboard" clutter, over-filtering, and tiny control panels.

### Proposed information architecture

1. **Home / Map**
   - full-width aggregate map
   - clear legend
   - municipality selector
   - freshness + confidence explainer
2. **Road detail panel**
   - current category
   - recent trend
   - pothole presence
   - number of contributors / readings
3. **Coverage view**
   - where we have enough data vs. where we need drivers
4. **Trends / Reports**
   - worst segments
   - improving / worsening corridors
   - municipality comparison
5. **Methodology / Privacy**
   - how scoring works
   - what data is collected
   - why some roads are missing

### Visual direction

- Think **civic newsroom + high-quality map**, not generic BI dashboard.
- Light background by default, strong typography, restrained chrome, large map area.
- One accent family for controls, one semantic ramp for road quality, and one neutral ramp for confidence / unscored states.
- Use motion sparingly: panel transitions, hover emphasis, animated trend lines. No spinning metric cards or noisy dashboard ornaments.

### What to avoid on the web

- dashboard-soup layouts with 12 cards above the fold
- overuse of tables before the map
- mystery colors without a legend
- default admin-template styling
- hiding methodology or freshness behind tiny info icons

## Android Follow-On (weeks 13–18)

Android doubles the addressable beta pool in Halifax and unlocks Google Pixel / Samsung sensor quality for the scoring model. iOS-first gives us a tight MVP; Android second keeps the data model and backend identical.

### Platform Choice

**Kotlin native** (not Flutter, not KMP). Rationale mirrors iOS:
- Raw sensor access is the core differentiator; Android `Sensor.TYPE_LINEAR_ACCELERATION` + `FusedLocationProviderClient` map cleanly to CoreMotion + CoreLocation
- Flutter's sensor plugins wrap the same APIs but add latency and obscure the fine-grained control we need (rate capping, thermal handling)
- KMP (shared business logic in Kotlin) is tempting but the only genuinely shareable code is the roughness scorer (~500 LOC); not worth the build complexity at MVP scale
- Our backend is Supabase — any client can speak HTTPS JSON, no client SDK lock-in

### Tech Stack

- Kotlin 2.x, Android Gradle Plugin latest
- Jetpack Compose for UI
- Hilt for DI (lightweight; we're deliberately not overengineering)
- Mapbox Maps SDK for Android (parity with iOS)
- Retrofit + OkHttp + kotlinx-serialization for networking
- Room for local queue + cache (SwiftData analogue)
- WorkManager for background upload flushing
- `ForegroundService` with LocationManager FOREGROUND_SERVICE_LOCATION permission for active recording

### Critical Differences from iOS

| Concern | iOS approach | Android approach |
|---|---|---|
| Background location | Always auth + `significantLocationChange` + BGTaskScheduler | Foreground service with persistent notification (Android 14+: FOREGROUND_SERVICE_LOCATION permission); no background-without-foreground-service option on modern Android |
| Sensor rate | `CMDeviceMotion` at 50Hz | `SensorManager.SENSOR_DELAY_GAME` (~50Hz; not guaranteed — clamp to max 60Hz) |
| Gravity removal | `userAcceleration` already removed by iOS | `Sensor.TYPE_LINEAR_ACCELERATION` (gravity removed by sensor fusion) OR compute manually from TYPE_ACCELEROMETER + TYPE_GRAVITY |
| Device token | In Keychain | In EncryptedSharedPreferences (same rotation logic, same SHA-256 hash server-side) |
| Privacy zones | Reverse geocoding via CLGeocoder | Android Geocoder (best-effort; no dependency because we store user-set points) |
| Thermal state | `ProcessInfo.thermalState` | `PowerManager.getCurrentThermalStatus()` (API 29+) |
| Battery monitoring | `UIDevice.current.batteryLevel` | `BatteryManager.EXTRA_LEVEL` from sticky broadcast |
| Store review | Apple TestFlight | Google Play Internal Testing → Closed Testing → Open Testing. No mandatory pre-release review for Internal, but new dev accounts require a 14-test-user closed-testing phase before production. |
| Backup | `NSFileProtectionComplete` auto | `android:allowBackup="false"` on Application + explicit excludes for Room DB |

### Weeks 13–18 Plan

```
Week 13 ──┬─ Kotlin project bootstrap + Compose + Hilt scaffold
          ├─ Port the domain model (Reading, Segment, RoughnessScorer)
          └─ Google Play Console enrollment (one-time $25)

Week 14 ──┬─ Sensor + location collection, parity with iOS
          ├─ Foreground service + notification for recording state
          └─ Room schema matches SwiftData shape

Week 15 ──┬─ Upload queue + WorkManager retry
          ├─ Privacy zone + quality filters (ported from Swift)
          └─ First calibration drives on an Android test device

Week 16 ──┬─ Mapbox Android integration + vector tile rendering
          ├─ Settings, onboarding, permission flow
          └─ Cross-platform data consistency check (same drive on iOS + Android should produce similar scores)

Week 17 ──┬─ Internal testing track (closed to team + family)
          ├─ Battery + thermal characterization on 2 device classes
          └─ Bug bash

Week 18 ──┬─ Closed Testing (external), Google Play review
          ├─ Cross-platform release announcement
          └─ Update CI to matrix iOS + Android
```

### Release Criteria (Android parity)

Same as iOS MVP criteria plus:

1. Scoring output on identical drive is within ±10% of iOS output (calibrated via shared CSV fixtures run through both harnesses)
2. Battery drain < 20%/hr on a Pixel 7-class device (higher than iOS bar, acceptable because Android sensor cost varies more)
3. Foreground service notification is clear, dismissible only via in-app stop

### What Explicitly Does NOT Block Android Launch

- Google Play Games / any Play-specific store feature
- Samsung health integration
- Android Auto integration (attractive but scope creep)
- Tablet layout (phone-only to start)
