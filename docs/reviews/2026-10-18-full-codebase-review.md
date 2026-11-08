# 2026-10-18 Full Codebase Review + Launch Assessment

Seven parallel read-only passes: iOS, Android, Postgres/PostGIS, Deno gateway + Cloudflare worker, web, CI/ops, and launch/legal/product. Each pass re-checked every finding in [2026-07-02-full-codebase-review.md](2026-07-02-full-codebase-review.md) and then looked for new bugs. The highest-severity claims were also checked against source by hand. Severity runs across all areas: P0 means it blocks launch or harms users or data now.

**Test results (all run 2026-10-18):**

| Suite | Result |
|---|---|
| iOS `swift test` (Bootstrap package) | 129 passed |
| iOS `xcodebuild test` (RoadSenseNSTests) | 176 passed, 2 skipped |
| Android unit tests | 140 / 140 passed |
| Deno | 224 passed, 1 ignored |
| Web vitest | 109 passed; `tsc --noEmit` and `next build` also pass |
| pgTAP | **not run** (Docker was down) |

Static reading suggests the pgTAP suite would fail: `018` plans 38 tests but contains 41 assertions, and three assertions in `008` contradict the final `get_tile`.

## Fix status (2026-11-08)

Fixes for most P0 and P1 items are merged into local `main` (110 commits ahead of `origin/main`). **Nothing is pushed or deployed**, so production still runs the 2026-06-23 code. P0-1 stays open until the deploy in [05-deployment-and-observability.md](../implementation/05-deployment-and-observability.md) is done.

| Item | Status | Where |
|---|---|---|
| P0-1 deploy | **Open**: push, then migrations → worker → API → web | owner action |
| P0-2 Android token | Fixed: UUIDv4 tokens, legacy tokens replaced | `951429e` |
| P0-3 Android domain | Fixed: `nsroadsense.ca` everywhere, photos off, test guards the ICBC domain | `5c5105d`, `54c2abb` |
| P0-4 worker bypass | Fixed: `x-origin-auth` shared secret, `REQUIRE_ORIGIN_AUTH`; client IP trusted only with the secret | API merge `3d7d352` |
| P0-5 k-anonymity | Fixed for tiles, `/segments/{id}` and `/top-potholes` (≥3 contributors, day-rounded dates). **Coverage tiles still show an "emerging" level for 1–2-contributor segments**: owner decision below | `cd066b7`, `7f53dba` |
| P0-6 retention | Fixed server-side (scheduled sweeps for partitions, unmatched readings, IPs, marks, batches, actions) and on both clients (local sweeps wired, delete-all covers checkpoint and recovered stores). Feedback text and email retention is still an owner decision | `cd066b7`, `6ca003a`, `995de48`, `bc6b30c` |
| P0-7 iOS privacy manifest and links | Fixed: `PrivacyInfo.xcprivacy` (7 types, CA92.1), Privacy/Terms/Support in Settings and onboarding | `e0f3b85`, `236f81a` |
| P0-8 Android target SDK | Fixed to SDK 35. SDK 36 needs AGP ≥ 8.9 if Play requires it | `d10ec0d` |

P1 by area, all merged:
- **Database:** migrations `20261108090000`–`20261108150000`; scheduler on its own pool with advisory locks and a `scheduler_job_runs` ledger.
- **API and worker:** canonical cache keys, streaming body cap, strict RFC 3339, per-reading rejection, `ATTESTATION_ENABLED` gate, IPv6 /64 limits, request logs, SIGTERM drain.
- **Web:** KV binding removed, `/privacy` rewritten, `/terms` and `/support` added, SEO, HSTS plus report-only CSP, data-unavailable states.
- **Ops:** ledgered `migrate-railway.sh`, path-filtered PR CI, SHA-pinned actions, a rewritten production deploy, health monitor. The PostGIS image pin is documented but not yet applied in Railway.
- **iOS:** zone check before session and checkpoint, Sentry scrubbing, Mapbox telemetry off, passenger confirmation, the Siri "Mark Pothole" intent, background-task fixes, 500-reading batches, magnitude clamp, 401/403/408/413 retry.
- **Android:** transactional drive sealing, upload parity with iOS, a stationary tracker, a fail-closed Sentry scrubber, a trimmed permission set.

**Test results on merged `main` (2026-11-08):**

| Suite | Result |
|---|---|
| Deno API handlers | 332 passed, 3 ignored |
| Cloudflare worker | 26 passed |
| Scripts | all passed |
| pgTAP (21 files) | 474 passed |
| Web | `tsc` clean; vitest 165 passed |
| Android unit tests | all passed (0 failures); `assembleProductionRelease` builds |
| iOS | `swift test` 148 + 9 passed; `xcodebuild test` 198 unit (2 skipped) + 6 UI passed; Production Release simulator build succeeds |

**Open owner decisions:**
1. Coverage tiles: hide "emerging" (1–2 contributor) segments from the public, or keep them as a coverage hint.
2. How long to keep feedback text and reply emails.
3. Public contact address: the site and listing use a personal Gmail. A `@nsroadsense.ca` address is recommended.
4. Android application ID `ca.roadsense.android` reads as the ICBC domain reversed, and it can't change after the first Play upload.

---

## TL;DR

1. **Production is running none of the July fixes.**
   - Local `main` is 30 commits ahead of `origin/main` (pushed up to 2026-06-23).
   - iOS P0-1 (the device token is never saved) is still uncommitted.
   - Live checks confirm it: `/?lat=95` still crashes the map, `/health` reports `version: dev, commit: local`, and the 731 km headline is still ~40% too high.
   - The project has had no commits for about 3.5 months.
2. **Android cannot upload anything, and its production build points at a domain you don't own.**
   - Android sends a 43-character base64url device token. Every write endpoint requires a UUIDv4, so every Android batch gets a 400 and is marked permanently failed.
   - `production.env.properties` points the API, the privacy link and the WebView map at `roadsense.ca`. That domain has been registered to ICBC since 2000.
3. **Deploying the July fixes as-is would make rate limiting worse than it is today.**
   - The API now trusts an `x-client-ip` header, but nothing proves the request came through the Cloudflare worker.
   - The Railway origin URL is in this public repo, so anyone can call it directly with any IP they like.
   - `migrate-railway.sh` (the documented runbook) replays all 52 migrations against live production. While it runs, old function bodies come back, including the one that publishes single-device potholes.
4. **The privacy story, which is the brand, isn't true in production yet.**
   - Public tiles have no minimum-contributor floor: one driver's route shows up and grows with every trip.
   - Timestamps are public to the second.
   - The 6-month retention has never run. Data started around April, so the promise is being broken now.
   - `unmatched_readings`, client IPs and pothole reporter marks are kept forever.
5. **Store blockers.**
   - iOS has no `PrivacyInfo.xcprivacy` and no in-app privacy-policy link.
   - Android targets SDK 34; Play requires 35+.
   - The one-tap pothole button on the driving screen is a real App Review 1.4.5 (driver distraction) risk.
6. **The core engineering is good.** The privacy architecture, PostGIS/MVT pipeline, idempotent upload queues and test discipline are well above solo-project norms. What's missing is the last mile: deploys, retention, CI, store compliance, calibration, and data density.

---

## P0 — ship-stoppers

| # | Area | Finding | Evidence |
|---|---|---|---|
| P0-1 | Release | **Nothing since 2026-06-23 is deployed.** 30 local commits are unpushed. The iOS fixes (token save, `URLError.cancelled`, repair race, checkpoint) are uncommitted. | `git rev-list main...origin/main` gives 30/0; live site checks above |
| P0-2 | Android | **Device-token format is rejected by the server.** `DeviceTokenStore` makes a 32-byte base64url token, while `upload-readings`, `pothole-actions` and `pothole-photos` all use `UUID_V4_REGEX`. Every Android upload fails with a permanent 400. Test fixtures use UUID-shaped tokens, which is why the tests miss it. | `android/.../data/DeviceTokenStore.kt:21-23`; `supabase/functions/upload-readings/handler.ts:134` |
| P0-3 | Android | **The production flavor targets a third-party domain.** `API_BASE_URL=https://roadsense.ca`; `roadsense.ca` belongs to ICBC (whois: registrant ICBC, 2000). The privacy link and the WebView fallback map use the same host. If ICBC ever serves `/functions/v1/*`, readings and tokens go to them. `ENABLE_POTHOLE_PHOTOS=true` while the backend returns 503. | `android/config/production.env.properties`; `ui/Screens.kt:250,576`; `ui/map/MapHost.kt:98` |
| P0-4 | API/Ops | **Anyone can bypass the Cloudflare worker.** No shared secret exists between worker and origin. `clientIp.ts:81-82` trusts `x-client-ip`, and `wrangler.toml:19` publishes the origin. Rotating `x-client-ip` per request defeats every per-IP limit and skips the edge cache. Deploy-order trap: if the API ships before the worker, clients can spoof the header even through the proxy. | `cloudflare/api-proxy/src/worker.js`, `_shared/clientIp.ts:79-91` |
| P0-5 | Privacy | **Public tiles have no k-anonymity floor.** The final `get_tile` gates only on `total_readings > 0`; the original required `unique_contributors >= 3`. Coverage tiles expose `updated_at`, and `/segments/{id}` exposes `last_reading_at`, both to the second. With few beta users, individual trips can be followed. This contradicts the project's own aggregate-privacy rule. | `20260506193000_filter_bike_pothole_reports.sql:148`; `20260419103016:30` |
| P0-6 | Privacy | **Retention promises are broken everywhere.** <br>• The partition-drop fix is unpushed, and data from April is now past the 6-month line. <br>• The `unmatched_readings` 90-day purge is never scheduled. <br>• `feedback_submissions.client_ip`, `token_challenges.client_ip`, `pothole_reporter_marks`, `processed_batches` and `pothole_actions` are never cleaned up. <br>• iOS `RetentionPolicy` and Android `pruneUploadedBefore` have zero callers. <br>• iOS keeps raw in-zone GPS fixes, and "Delete local data" doesn't remove the checkpoint or `RecoveredStores/`. | `scheduler.ts:34-48`; `ReadingStore.swift:426-444`; `BackgroundTaskRegistrar.swift:51-54` |
| P0-7 | iOS store | **No `PrivacyInfo.xcprivacy`** (required-reason API: UserDefaults CA92.1; collected types: location, device ID, crash data), so expect ITMS-91053. **No in-app privacy-policy link** (Guideline 5.1.1(i)). | `find ios -name '*.xcprivacy'` finds nothing; only link is in `LicensesView.swift` |
| P0-8 | Play store | **`targetSdk = 34`.** Play requires 35 for new apps (since 2025-08-31), and probably 36 from 2026-08-31; confirm in Play Console. | `android/app/build.gradle.kts:53,63` |

---

## P1 — high, by area

### Deploy & ops
- **`migrate-railway.sh` must not run against production.**
  - Each run re-applies all 52 files. There's no `--single-transaction` and no skip ledger, and the ledger insert silently never writes (`psql -c` doesn't expand `:'name'`).
  - During a run it reinstates `fold_pothole_candidates` versions that insert `'active'`, so single-device potholes are published and never demoted. It also restores the unguarded `apply_road_segment_refresh` and the broken partition drop, and drops and recreates `public_stats_mv` twice.
  - Since addb627 it continues after a failure, applying later migrations onto a broken schema. (`scripts/migrate-railway.sh:286-310`)
- **The deploy workflow migrates first, then fails.** `deploy-production.yml` runs `supabase db push`, then needs `RAILWAY_DEPLOY_HOOK_URL`, which isn't set in any environment. Result: database migrated, service on old code, no rollback. Railway deployments have no commit SHA, so the real path is a manual `railway up`.
- **The web deploy is blocked.** `apps/web/wrangler.jsonc:32` has `"id": "REPLACE_WITH_REAL_KV_NAMESPACE_ID"`. `open-next.config.ts` also sets no `queue`, which defaults to `dummy`. Once KV is real, revalidation would probably throw and ISR pages would stay stale (read from source, not observed).
- **Production PostGIS runs `postgis/postgis:16-master`**, a development snapshot. Any database redeploy can pull untested code. Pin something like `16-3.5`.
- **No verified backups, no restore drill, no staging.** Staging xcconfig and Android staging both point at production. The Railway project has only `production`.
- **No error reporting or alerting for the backend or web** (no Sentry in `supabase/functions`; `app/error.tsx` mentions Sentry but it isn't installed). No uptime monitor. Scheduler failures only reach `console.log`.
- **CI** runs on pull requests only for Android. Backend, web and iOS are `workflow_dispatch` only, and `main` has no branch protection. The repo is public with repo-level release secrets and tag-pinned actions; `r0adkll/upload-google-play@v1` receives the Play service-account JSON.

### Database
- **N1 — one request can make a pothole permanent and unresolvable.** `confirm_present` with `recorded_at=2099-01-01` sets `last_confirmed_at=2099`: it never expires, and "fixed" votes need `recorded_at > last_confirmed_at`. Back-dated actions also get around the 24 h dedupe and inflate `confirmation_count`, the top-potholes sort key. Clamp to `[now()-7d, now()+60s]` in both gateway and SQL. (`20260612182000:371,436,501`; `pothole-actions/handler.ts:134`)
- **N3 — the scheduler shares the gateway pool's 8 s `statement_timeout`.** All daily jobs fire at the same moment, every 24 h from boot, with no advisory lock or last-success record. As data grows, the nightly recompute, the materialized-view refreshes and the partition drop (which needs ACCESS EXCLUSIVE on `readings`) will start failing every day, silently. (`db.ts:36-38`, `scheduler.ts:56-65`)
- **N5 — the P1-s3 length fix is a time bomb.** There was no backfill, so `length_m` and `total_km_mapped` are still about 1.41× too high. The next OSM import re-cuts ways into true 50 m segments, but rows are keyed `(osm_way_id, segment_index)`. Index k ends up on a different stretch of road with the old aggregates, ~20–30% of ids are deleted (cascading aggregates and nulling `pothole_reports.segment_id`), and replay can then fail on foreign keys. Backfill `length_m` from `geom::geography` now, and plan the re-cut as a migration with a rematch and full recompute.
- **N8 — malformed values poison whole batches.** A heading ≥ 10000 or a negative accuracy overflows `NUMERIC(5,1)` or the `::INT` cast, so the batch returns 500 and is retried forever. iOS sends `accuracy = -1` for invalid fixes, which passes the `> 20` filter as "high quality". Validate `[0,360)` and `[0,20]`.
- **Still open from July:**
  - `replay_unmatched_readings` double-counts aggregates and isn't scheduled.
  - The `quality_corridors` layer was dropped from `get_tile`, but the web still requests it.
  - The nightly recompute's fixed 24 h window means segments that haven't been driven recently are never recomputed: scores built on deleted readings stay public.
  - Pothole find-or-create races can split candidates so neither reaches the 2-device gate.
  - Unordered upserts can deadlock.
  - There's no `readings(uploaded_at)` index.
  - The service still connects as the postgres superuser, which bypasses the new RLS.
- **Unified matcher behaviour change.** The unpaved filter now runs after `LIMIT 5`, so gravel-road readings can attach to a nearby, heading-aligned paved road (`20260702150000:69,83-86`).

### API gateway / worker
- **Body cap applied after the read.** `req.text()` buffers the whole body before the 256 KiB check, and chunked bodies have no Content-Length (verified with 50 MB). A few concurrent large POSTs straight to Railway can run the instance out of memory. Stream with a byte counter. (`upload-readings/handler.ts:307,318`, and the same pattern in pothole-actions, feedback and device-tokens)
- **Tile cache can be busted.** Arbitrary query parameters and zero-padded z/x/y become distinct cache keys (`/08/080/090.mvt?bust=1`). Normalize, and drop the query for tile routes. (`worker.js:49-53`)
- **`cacheTtl` probably caches errors for an hour.** That would include a 401 from a bad apikey, because the cache key strips the apikey. Use `cacheTtlByStatus`. (`worker.js:142-145`)
- **Fake attestation verifier wired into production.**
  - `server.ts:150` uses `createFakeVerifyAttestation()`.
  - `upsert_attested_device` overwrites `public_key` and `sign_count` on conflict.
  - Redeem has no rate limit, and `token_challenges` never gets cleaned up.
  - Put the routes behind a flag until B161/B163 land.
- **Unbounded pool queue** (`max: 10`) shared by uploads, the scheduler and uncached GETs. `/potholes` (fires on every pan), `/segments/:id` and `/top-potholes` have no cache headers, and the worker only edge-caches tiles.
- **No request logging**, GET handlers swallow errors, and 503 responses carry no `Retry-After`.
- **Lenient timestamp parsing.** `Date.parse("0")` passes, then Postgres rejects it, so the client gets 502 instead of 400.

### iOS
- **Uncommitted 413 → retry-forever change.** 413 is deterministic: the body is over 262,144 bytes, and a measured 1000-reading batch is already 237 KB. There is only ever one pending batch, so one 413 stalls all uploads permanently. Split the batch or mark it permanent, and lower the batch size. (`UploadPolicy.swift:46-47`)
- **Pothole magnitude isn't clamped.** A phone falling off its mount (free fall, then impact above 8 g) produces a reading the server rejects with 400 (`POTHOLE_MAGNITUDE_MAX_G = 8`), which permanently fails the whole 1000-reading batch. (`PotholeDetector.swift:88`)
- **Drive mini-maps leak home/work coordinates to Mapbox.**
  - The bounding box includes endpoint-trimmed readings and session start/end points, which are captured before the privacy-zone check.
  - Static-image URLs carry about 1 m precision, and Sentry HTTP breadcrumbs record them.
  - The same calls use `logo=false&attribution=false`, which violates Mapbox's terms.
  - (`ReadingStore.swift:64-65`, `DrivesListView.swift:296-336`, `SensorCoordinator.swift:342-344`)
- **Checkpoint redaction is partial.** Only the forced write redacts. The 60 s write from the motion path still saves the in-zone `latestLocation`, and `recentPotholes` stamped with it. (`SensorCoordinator.swift:341,411,476`)
- **Driver distraction (App Review 1.4.5).** The hero "Pothole" button has no speed gate, and the camera only warns when moving. The planned screenshot is a pothole being marked. Gate on speed, or move the tap to App Intents / Action Button / Siri.
- **Still open:**
  - Thermal state isn't monitored continuously.
  - Invalid course is reported as heading 0 (send `null`).
  - `@Model` objects cross into the non-isolated `APIClient`.
  - BGTask handlers are registered with `using: nil`.
  - 57 `try?` sites.
  - Network flaps erase backoff, including 429 Retry-After.
  - A schema reset can silently remove privacy zones: V1–V5 share live model types.
  - Short drives may never upload in the background (threshold of 100+).

### Android
- **The P0-2 / P0-3 privacy fixes are partial.**
  - Sessions are only sealed in `onDestroy`, so force-stop, OOM or a crash leaves them unsealed forever, and nothing finalizes orphans.
  - The seal isn't transactional.
  - `endedAt` is the time Stop was tapped, so end-trimming misses if Stop comes late.
  - There's no automatic drive end. Home → park 8 h at work → drive home is one session, so the work endpoints upload untrimmed.
  - A race in `ensureDriveSession` can persist readings with a null session, which are immediately upload-eligible and never trimmed.
  - Zones added mid-drive aren't applied.
- **Stop or "Delete local data" crash** with `SecurityException` when the service isn't running and location isn't granted (`CollectionService.kt:83-85,350-356`).
- **Unbounded motion buffer.** With a 5 m distance filter, a parked phone gets no fixes while samples keep accumulating at 50 Hz: about 1.4 M samples overnight, a likely out-of-memory.
- **`ACCESS_BACKGROUND_LOCATION` is unnecessary**: a foreground-started location FGS keeps working with the screen off. The in-app claim and the Play justification both say otherwise. Drop the permission for v1 and avoid the declaration video.
- **Data Safety draft is inaccurate**: feedback collects an email and free text. The Play FGS declaration isn't mentioned. `CAMERA` and `ACTIVITY_RECOGNITION` are declared but unused.
- **No logging or crash capture anywhere.** `pipelineScope` has no exception handler.

### Web (all fixes below exist locally only)
- **Feedback dialog regression** from 5d98ae1: `open={isOpen}` means `showModal()` is never called. The result is no backdrop, no focus trap and no Escape. (`feedback-dialog.tsx:132`)
- **Drawer steals focus on every render**: the effect depends on a new `handleClose` each time, and every map `moveend` re-renders (`segment-drawer.tsx:223-240`).
- **Trust-damaging copy and signals:**
  - The freshness pill always says "Updated today", because `generated_at` is the materialized-view refresh time.
  - An API outage renders as "No active potholes".
  - The methodology page's confidence tiers (6/22/78 drives) and its 25 km/h cutoff don't match the code (≥3 / ≥10 contributors, 15 km/h).
  - The privacy page covers iPhone only, is dated April, and lists no processors.
- **SEO is effectively absent**: no canonical, OG, Twitter or JSON-LD tags, `sitemap.xml` returns 404, robots is only Cloudflare's default, and www and apex both serve 200.
- **The Mapbox `pk.` token has no URL restriction**: a request with Referer `evil.example.com` returned 200.
- Hashed static assets are served with `max-age=0`. On mobile, search and stats are hidden and the drawer covers the mode switcher. Every segment click triggers a server render. There's no CSP or HSTS.

---

## P2 / P3 (condensed)

- **API:**
  - The rate limit is bumped before the duplicate check, so retries burn quota.
  - IPv6 is keyed on the full /128.
  - The 10 uploads/hour/IP limit hurts drivers behind carrier NAT.
  - `x-request-id` is stored unbounded.
  - No `deno.lock`, and the base image is pinned by tag only.
  - `.dockerignore` matches `.env*` at the root only.
  - The Dockerfile has no non-root `USER`.
- **SQL:**
  - DBSCAN `eps` is computed in 3857 (about 10.6 m on the ground).
  - `confirm_fixed` voters count toward `unique_reporters`.
  - `ON COMMIT DROP` temp tables bloat the catalog.
  - Effective retention is 6–7 months, not 6.
- **iOS:**
  - The token lookup happens after `markBatchInFlight`.
  - The overlay fetches every pending reading.
  - `NSLocalNetworkUsageDescription` mentions "your Mac".
  - The `processing` background mode is declared but unused.
  - The staging anon key is committed.
- **Android:**
  - The NETWORK provider is mixed into the GPS stream, which resets reading windows and can produce a poor-accuracy start point.
  - Only one 200-reading batch is sent per worker run.
  - `KEEP` swallows "Upload now" while in backoff.
  - OkHttp is `5.0.0-alpha`.
  - R8 is disabled.
  - `user_stats` is never written.
- **Ops:**
  - `DATABASE_URL` is on argv in the import and smoke scripts.
  - `seeded-e2e-smoke.sh` cleanup can delete real readings on its segment.
  - `.context/` (device stores containing GPS traces) is ignored only via `.git/info/exclude`.
  - Supabase CLI and Deno versions drift between CI and deploy.
  - There are 841 `refs/conductor-checkpoints/*` refs.

---

## July fix scorecard

- **Fixed (locally):**
  - **Data and SQL:** P0-4 RLS, P0-5 nullable heading, P0-7 refresh guard (plus a `--confirm` gate), P1-s1 single matcher, P1-s2 partition-drop logic.
  - **Android upload queue:** P1-a1 IN_FLIGHT reclaim, P1-a2 atomic drain, the P1-a3 crash.
  - **Web:** P1-w2 viewport clamp, sticky banner, debounce, NaN.
  - **iOS (uncommitted):** P0-1 token save, P1-i1, P1-i2, stale checkpoint.
  - **Gateway and scripts:** constant-time compare, IP-before-device ordering, world bounds, transactional municipality load, script token echo.
- **Partial:**
  - **Gateway and SQL:** P0-6 client IP (no origin secret), P1-g1 body cap (applied after the read), P1-g3 timeout (also hits the scheduler, and the queue is unbounded), P1-s3 lengths (no backfill).
  - **Web:** P1-w1 ISR (placeholder KV, dummy queue), drawer a11y (now steals focus), ARIA.
  - **Android:** P0-2 trimming, P0-3 zones.
  - **Ops:** P1-o1 deploy verification (no SHA, missing hook), P1-o2 smoke pollution, P1-o3 migrate script (now worse).
  - **iOS:** checkpoint redaction.
- **Regressed:** feedback-dialog Escape (now not modal at all).
- **Still open:** everything retention-related; replay; `quality_corridors`; scheduler locking; deadlock ordering; superuser role; request logging; staging; backups; CI on PR; SEO.

---

## Cross-cutting themes

1. **"Done locally" isn't done.** The July fix sprint produced about 25 good commits that never reached users. Production readiness is now limited by the release process, not by code. Without CI on PRs plus a deploy you trust, every fix sprint ends up in this same state.
2. **Privacy is enforced at collection, not at the edges.** On-device zones and trimming are thoughtful. Meanwhile, tiles, timestamps, retention, mini-map URLs, Sentry breadcrumbs, the Mapbox SDK's telemetry (not disabled anywhere — verify v11 behaviour) and server-side IP storage all leak around it. A privacy-invariants test suite should assert on what is **public** (tile contents, API JSON, logs), not only on what is collected.
3. **One bad item blocks the whole queue** (413, >8 g magnitude, heading overflow, negative accuracy). Validate at every boundary on both sides. The server should reject individual readings instead of whole batches, and clients should clamp.
4. **Function-redefinition drift is still the house failure mode**, now with a second form: the migration runner replays history against production. Apply each migration exactly once (one ledger, one runner) and keep shared logic in single functions.
5. **Silent failure.** Scheduler jobs, GET handlers, the web `fetchJson` → `null`, iOS `try?`, and Android with no crash reporting. An outage looks the same as "no data" everywhere.

---

## Project assessment

**What's strong**
- The architecture is right for the problem:
  - Clients upload points and the server owns segment matching.
  - Readings are partitioned by month.
  - Tiles are generated in PostGIS.
  - Uploads are idempotent per batch.
  - Exact-dedupe contributor and reporter marks.
  - Two-device pothole corroboration.
- About $2/month to run.
- Around 650 automated tests across five suites, and an honest methodology page.
- The web is live, iOS is on TestFlight with outside testers, and the Android code exists.

**What's weak**
- **The core claim, road roughness, is uncalibrated.** B140/B141 (known-road calibration, speed normalization) haven't started. Thresholds are still the spec's g-RMS bands.
- **Data density.** 731 km, really about 520 km after the length fix, against roughly 25,000+ km of NS public road, so about 2% coverage. A sparse heat map looks broken, not "early".
- **Process overhead.** There are about 13k lines of planning and review docs for one developer. The backlog, roadmap, tasks file and reviews overlap, and it's no longer clear where the truth lives.
- **Bus factor of one**, and momentum stalled for 3.5 months.

**Biggest risks, in order**
1. A privacy incident during the low-user beta (P0-5, P0-6, mini-maps). This matters most because privacy is the brand.
2. A journalist or councillor spots a wrong number: km mapped is 40% high, "Updated today" always shows, and the methodology tiers are wrong.
3. Phone, mount and vehicle variance make cross-user scores incomparable; the roadmap's own hard stop is >30% variance.
4. Abuse after publicity, before attestation exists (P0-4, N1, the fake verifier).

**Legal and licensing**
- `road_segments` are OSM-derived, so the scored data and tiles are an **ODbL derivative database**. The planned CC-BY-4.0 export (doc 06:253) is incompatible; publish aggregates under ODbL.
- Show "© OpenStreetMap contributors" on your overlay and on the static images.
- Add Terms of Use covering: informational only, not for navigation, never use the phone while driving, and a contributor data licence.
- Update the privacy policy to cover:
  - Android
  - processors (Railway, Cloudflare, Mapbox, Sentry) and cross-border processing
  - photos, feedback email, attestation
  - how access and deletion requests work
  - the real retention behaviour
- PIPEDA may not strictly apply to a non-commercial project, but the spec's municipal and insurer ambitions make it apply eventually. Comply now. An hour with an NS privacy/IP lawyer before the media push is worth it.

---

## Launch plan

The natural public moment is **freeze–thaw pothole season, late Feb–Apr 2027**. Work backwards from there.

### Phase 0 — make production true (this week)
1. Commit the iOS work, but **first** change 413 to split-or-permanent, and clamp magnitude to ≤ 8 g.
2. Fix the four deploy hazards **before pushing**:
   - Add a worker→origin shared-secret header, and trust `x-client-ip` only when it's present.
   - Give the scheduler its own connection (no 8 s timeout, a per-job advisory lock, a last-success timestamp).
   - Gate the attestation routes behind a flag.
   - Create the KV namespace and a real OpenNext queue, or revert ec809fa.
3. Take a manual Railway snapshot. Pin PostGIS to a release tag.
4. Deploy in this order. Use `supabase db push`, **never** `migrate-railway.sh` against production.
   1. Migrations. Before this, count rows in partitions ≤ 2026-03, because the first partition drop is irreversible.
   2. The Cloudflare worker, with the secret.
   3. The API (`railway up`).
   4. `api-smoke.sh` only.
   5. The web.
   6. A TestFlight build.
5. Set `/health` to report the real git SHA. Add an uptime monitor on `/health/deep`.
6. Push to origin and turn on PR CI for backend, web and iOS-package, path-filtered. Add branch protection.

### Phase 1 — privacy truthfulness and correctness (2–3 weeks)
- Restore a k ≥ 3 tile floor, round public timestamps to the day, and remove `updated_at` from coverage tiles.
- Schedule all retention jobs:
  - `unmatched_readings`
  - IP columns
  - marks, actions, processed batches, challenges
  - iOS and Android on-device retention, plus `RecoveredStores` and the checkpoint in "Delete local data"
- Clamp `recorded_at` on pothole actions; validate heading and accuracy at both gateway and SQL.
- Backfill `length_m`. Fix the "km mapped" headline, the freshness signal and the methodology copy.
- Android: UUID token, `nsroadsense.ca`, orphan-session finalize plus stationary auto-seal, the Stop crash, a bounded motion buffer, Sentry.
- iOS: filter mini-map points to upload-eligible readings only, finish checkpoint redaction, Sentry `beforeBreadcrumb`, disable or declare Mapbox telemetry.
- Run pgTAP and make it green (fix 018's plan count and 008's assertions).

### Phase 2 — stores and calibration (Nov–Dec, before snow)
- **Calibration drives now**, while roads are dry: known-good and known-bad segments, 3+ phones, pocket/mount/cupholder. Publish the results as **relative rankings** ("among the roughest 10% mapped") rather than absolute scores.
- **iOS submission:**
  - privacy manifest and in-app privacy/terms links
  - speed-gated pothole tap, plus App Intent / Action Button / Siri "mark pothole"
  - background-location purpose string that says drives are detected automatically
  - a review-notes video
  - corrected nutrition labels
  - re-shot screenshots
- **Play:**
  - register the console now, because the 12-tester / 14-day clock gates production
  - targetSdk 35/36
  - drop background location
  - a correct Data Safety form and the FGS declaration
- **Legal pages:** ToS, updated privacy policy, ODbL notice and attribution.
- **Web:** SEO package (metadataBase, canonical, OG images per municipality, sitemap, JSON-LD `Dataset`, www→apex redirect), Mapbox URL restriction, an immutable cache on static assets, mobile search.

### Phase 3 — data density (Jan–Feb)
- **Corridor seeding.** Pick about 10 corridors (the 100-series highways plus key HRM arterials). Drive them weekly yourself and recruit 10–20 "corridor captains".
- **Fleet pilots**, in order of value: Halifax Transit (fixed routes, daily, also good for calibration), taxi companies, couriers and delivery, Canada Post rural routes (where the political pain is), driving schools. Give each a "fleet road report" in return.
- **Coverage as a first-class layer**, so unmapped reads as "unmapped", not "smooth".
- **Media kit (B151)**, plus the municipality comparison and worst-roads pages.

### Phase 4 — public launch (late Feb–Apr 2027)
- Lead with a data-backed "worst roads" story pitched to CBC NS (Information Morning), the Halifax Examiner and The Coast.
- Partner with CAA Atlantic's Worst Roads campaign rather than competing with it.
- Post to r/halifax and r/NovaScotia.
- Give councillor one-pagers to the 16 HRM councillors during budget season.
- Time a story around the province's highway-plan release.

---

## Future directions (beyond the existing roadmap, doc 16)

1. **Per-device gain calibration from shared segments.** When two devices drive the same segment, their roughness ratio estimates each device's relative gain. Solve for gains over the graph of segments shared between devices (one least-squares pass during the nightly job), and normalize readings before aggregating. This is the scalable answer to phone, mount and vehicle variance, and it gets better as density grows.
2. **Segment history and seasonality.** Add a monthly `segment_aggregates_history` rollup. Fill the API's `history: []` and render sparklines. This enables "worsening since last winter", repave detection, and the frost-heave story NS media will actually run.
3. **Pothole lifecycle accountability.** A `pothole_status_transitions` table gives median days-to-fix per municipality, which is the number councillors get asked about. Export it under ODbL.
4. **Hands-free contribution.** App Intents, Action Button, Siri and a Live Activity for active drives on iOS; Activity Recognition `IN_VEHICLE` automatic start/stop on Android, which also fixes the Android endpoint-trim gap.
5. **Shareable views.** Sync the viewport to the URL, use segment and municipality permalinks with OG images, and add an `/embed` route for news and municipal sites.
6. **"Drive here next."** Build a coverage-gap layer from `get_coverage_tile` 'none' segments, so contributors know where data is needed.
7. **Trust scoring.** Down-weight devices with a high rejected-reasons rate, as a stepping stone to App Attest / Play Integrity.
8. **Edge-cache all public JSON** (`/stats`, `/potholes`, `/segments/:id`, worst segments) for 60–300 s with ETags. A news spike then costs nearly nothing.

---

## Housekeeping

- **Merged branches safe to delete:** `gmann14/{amarillo,mogadishu,deploy-cost-research,design-audit,public-site-redesign,android-beta-test-fixes}`, `claude/magical-beaver-1530c2`, `codex/testflight-photo-status`.
- **Branches to triage:** `gmann14/android-spec-check` (9 commits ahead; very likely superseded by the Android merge) and `gmann14/calibration-and-resolution-tasks` (one WIP commit with a rejection-diagnostics plan plus about 400 lines of iOS code; decide whether to rebase or drop it).
- **Remove the Conductor worktrees** (`london-v1`, `taipei`) once they're triaged, and prune the 841 `refs/conductor-checkpoints/*`.
- **Doc cleanup:**
  - `docs/deploy-cost-research.md` isn't about RoadSense.
  - `apps/web/vercel.json` is dead.
  - `docs/05` still describes Supabase alerts.
  - `docs/15` wrongly states that targetSdk 34 is the 2026 floor and uses `roadsense.ca` throughout.
- **Choose one canonical task list.** `.claude/tasks.md`, the 08 backlog, the 16 roadmap and these reviews overlap; collapse the open items into `.claude/tasks.md`.
