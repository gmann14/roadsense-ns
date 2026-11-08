# 2026-07-02 Full Codebase Review

Six parallel review passes over iOS, Android, the Postgres/PostGIS layer, the Deno gateway + Cloudflare proxy, the Next.js web dashboard, and CI/scripts/docs. Findings verified against source; each item cites file/function. Severity is cross-area (P0 = fix before anything else ships).

---

## P0 — Critical

### P0-1 (iOS) Device token is never persisted — every request mints a new token
`ios/RoadSenseNS/Persistence/DeviceTokenStore.swift:36-46` inserts a `DeviceTokenRecord` but never calls `context.save()`, and every caller (`Uploader.swift:90-91, 161-162, 216-217`) uses a throwaway `ModelContext` with autosave off. No token ever reaches disk, so every batch/action/photo request carries a fresh random token. This silently breaks server-side cross-batch dedupe (keyed on `device_token_hash + recorded_at`), the two-device pothole corroboration gate (one phone can look like N devices), and per-device attribution. Fix: `try context.save()` in `currentToken`; add a test asserting token stability across two drains.

### P0-2 (Android, privacy) Drive-endpoint trimming never runs — home coordinates upload every drive
iOS trims 60 s / 300 m around drive start/end (`DriveEndpointTrimmer.swift`). Android has the schema (`ReadingEntity.kt:44-48`, `DriveSessionEntity`) but `CollectionService.startCollection` (`collection/CollectionService.kt:131-149`) never creates a session or calls `pipeline.setDriveSession(...)`. All readings persist with `driveSessionId = null`, which `ReadingDao.pendingForUpload` treats as immediately upload-eligible — no sealing, no trimming, ever. Driveway coordinates upload on every Android drive.

### P0-3 (Android, privacy) Privacy zones can't be created; manual pothole reports bypass them anyway
No production code inserts a `PrivacyZoneEntity` (only `list()`/`deleteAll()` callers exist) while the Settings screen advertises the feature (`ui/Screens.kt:534-543`). And `AppViewModel.reportPothole` (`ui/AppViewModel.kt:129-160`) submits `lastKnownLocation` verbatim with no `PrivacyZoneFilter.shouldDrop` check.

### P0-4 (SQL, privacy) `pothole_actions` has no RLS and no anon REVOKE
`supabase/migrations/20260421164516_pothole_actions.sql`. Every other sensitive table gets RLS + `REVOKE ... FROM anon`; this one gets neither (verified across all 44 migrations). Under PostgREST-style grants, anon can `SELECT device_token_hash, geom, recorded_at` — precise user locations joined to a stable device identifier. Same gap (non-sensitive): `road_segments_staging`. Fix: one-line RLS + revoke + a pgTAP RLS assertion.

### P0-5 (SQL) NULL `heading` poison-loops entire upload batches
`ingest_reading_batch` (final state, `20260612120000`) inserts `heading` into `unmatched_readings.heading_degrees` which is `NOT NULL`. The gateway explicitly allows `heading: null`. One null-heading reading that fails segment match → NOT NULL violation → whole 1000-reading transaction rolls back with a 500 → `processed_batches` never records the batch → client retries the poison batch forever. Fix: drop the NOT NULL (nullable everywhere else) or COALESCE; add a null-heading test (test 016 uses `heading: 90`).

### P0-6 (API) Rate limits key on Cloudflare egress IPs, not client IPs
`cloudflare/api-proxy/src/worker.js:86` deletes `cf-connecting-ip`; `_shared/clientIp.ts:51-59` then picks the rightmost public XFF entry — which, behind the proxy, is Cloudflare's egress IP. All users in a region share a few buckets against a 10-uploads/hour/IP limit (`upload-readings/runtime.ts:109-113`) → false 429s for real users as soon as there are concurrent drivers, and no per-attacker isolation (plus the public Railway URL bypasses the proxy entirely). Fix: worker sets a trusted `x-client-ip` from `cf-connecting-ip`; gateway prefers it.

### P0-7 (Ops) OSM re-import can mass-delete the production road network
`scripts/osm-import.sh` runs `apply_road_segment_refresh()` unconditionally; that function (`20260418110009:205-212`) deletes every `road_segments` row absent from staging. No count guard (doc 05 promises one; roadmap B143 plans it), no empty-staging exception, and the table-existence check at `osm-import.sh:33` is vacuous (tests psql exit code, not the boolean). A truncated PBF or wrong `REGION_KEY` wipes the live network, cascading to aggregates. Fix now: `RAISE EXCEPTION` in `apply_road_segment_refresh` when staging is empty or < N% of current count.

---

## P1 — High

### iOS
- **P1-i1 Cancellation burns backoff.** `Uploader.swift:113-127` (+3 more sites) only rethrows `CancellationError`, but cancelled `URLSession` calls throw `URLError(.cancelled)` → recorded as failure, attempt count inflated, up to 1 h backoff after every BG-task expiration mid-upload. Foreground drains then silently no-op.
- **P1-i2 Session repair vs in-flight drain → duplicate uploads.** `ReadingStore.swift:341-343, 354-356` clears `uploadBatchID` on non-uploaded readings; runs at drive end, can interleave with a suspended drain on the same MainActor. Server 200 then finds no readings to mark uploaded → re-batched and re-uploaded (and with P0-1, un-dedupable). Fix: exclude readings in `pending`/`inFlight` batches, or gate repair during drains.

### Android
- **P1-a1 Batches strand in `IN_FLIGHT` forever.** `upload/UploadDrainCoordinator.kt:115-121` catches only `IOException`; worker cancellation (`CancellationException`), process death, or serialization errors leave the batch in `IN_FLIGHT` permanently. `nextDrainable` only selects `PENDING`; `releaseBatch` has zero callers. iOS handles this (`UploadQueueStore.swift:202-209`). Fix: include `IN_FLIGHT` in drainable (with staleness), widen the catch.
- **P1-a2 Concurrent drain workers double-upload.** `AppViewModel.enqueueDrain` uses `WorkManager.enqueue` (not unique work); `drainOnce`'s select→insert→assign is non-transactional. Two workers batch the same readings under different batch IDs; server dedupes on batch_id only. Fix: `enqueueUniqueWork(KEEP)` + Room `@Transaction`.
- **P1-a3 Photo upload will crash the drain worker when the capture UI ships.** `PotholePhotoCoordinator.kt:82` does `UUID.fromString(deviceToken)` on a 43-char base64url token — guaranteed throw. Root cause: wire-model drift (`deviceToken: UUID` on Android vs `String` on iOS). Fixture-parity script only checks sensor CSVs, so this sailed through.

### SQL
- **P1-s1 Three divergent segment matchers.** `rematch_readings_after_segment_refresh` (`20260418123010`, never updated) uses flat 20 m + strict surface allowlist vs ingest's tiered 45/25/20 m + permissive unknown-surface. Running the documented refresh→rematch pipeline mass-NULLs legitimate highway and untagged-surface matches. `replay_unmatched_readings` is a third variant. Same disease as the dropped-holding-insert incident. Fix: one `match_reading_to_segment()` called from all three paths.
- **P1-s2 Partition retention has never worked.** `drop_old_readings_partitions` (`20260418165013`) parses bounds with a date-only regex, but timestamptz bounds deparse with a time component → substring NULL → no partition ever dropped, while the job "succeeds" in logs. The 6-month retention promise (privacy docs depend on it) is unenforced.
- **P1-s3 Web-Mercator lengths overstate ~40% at NS latitude.** `stage_osm_segments` uses `ST_Length(ST_Transform(geom, 3857))`; at 44.5–45.5°N that's ~1.41× real length. `total_km_mapped` (headline public stat) is ~40% high; "50 m" segments are ~35 m. Fix: `geom::geography` or EPSG:2961.

### API
- **P1-g1 No body-size cap on `/upload-readings` and `/pothole-actions`.** `upload-readings/handler.ts:235` buffers unbounded JSON before any check; validation never strips unknown fields, which flow verbatim into jsonb (`pgRuntime.ts:11`). Memory DoS + jsonb bloat. Feedback already has a 16 KB cap — replicate, plus whitelist-rebuild payloads (pothole-actions already does the whitelist part).
- **P1-g2 Advertised tile edge cache doesn't exist.** `worker.js:97` is a plain `fetch` — no `cf.cacheEverything/cacheTtl`, and `.mvt` isn't on Cloudflare's default cache list, so the origin's `max-age=3600` is ignored. Every tile hits Postgres. Compounds with **P1-g3**: no statement timeout / query deadline anywhere (`db.ts:23-30`), unbounded pool queue — slow low-zoom tiles can hang the whole gateway including uploads.

### Web
- **P1-w1 ISR/data cache is a no-op on Cloudflare.** `open-next.config.ts:3` configures no incremental cache and `wrangler.jsonc` has no KV/R2 binding, so every `revalidate` hint in `lib/api/client.ts` does nothing; every page view refetches `/stats` with a 3 s timeout and all errors are swallowed to `null` (silent "—" stats). The worst-roads copy claims a 15-minute cache that doesn't exist.
- **P1-w2 Crafted URL crashes the map.** `lib/url-state.ts:31-33` doesn't clamp `lat/lng/z`; `/?lat=95` throws inside Mapbox init in a dynamic-import `.then()` → blank canvas, no error UI. Clamp in `parseViewportState`.

### Ops
- **P1-o1 Deploy verification is largely fictional.** `deploy-production.yml`/`deploy-staging.yml` invoke `./scripts/seeded-e2e-smoke.sh` which is mode 644 (not executable) → Permission denied; missing env vars make both the precheck and smoke steps `exit 0` (green run, zero verification); and the smoke runs immediately after the Railway deploy *hook*, i.e., against the old deployment. Fix: `chmod +x`/invoke via bash, fail on missing env, poll deploy status (or compare a `/health` build SHA) before smoking.
- **P1-o2 Prod smoke tests pollute production data.** `seeded-e2e-smoke.sh:77-113` inserts a fake "Smoke Test Rd" segment (visible in public tiles/stats until the next deploy) and runs `REFRESH MATERIALIZED VIEW` without CONCURRENTLY (exclusive lock); `api-smoke.sh:64-91` adds a fake reading + a fresh random contributor per run — an inflation source for the very `unique_contributors` metric B166 just made exact. Fix: reserved smoke token / `is_synthetic` flag excluded from public models + cleanup trap.
- **P1-o3 `migrate-railway.sh` failure path kills the run.** Lines 279–288: the failure-replay pipeline trips `set -e` at the first failing migration (and re-executes the failed file's statements a second time). The fail-count summary is dead code. Also no migration ledger — every run re-applies everything, relying on unenforced idempotency; meanwhile the deploy workflow uses `supabase db push` (split-brain with the runbook).

---

## P2 — Medium (selected)

- **iOS:** stale sensor checkpoint resumes full-power collection after app kill while parked (`SensorCoordinator.swift:289-314` never clears checkpoint; `:187-192` resumes); SwiftData `@Model` objects cross actor/context boundaries in pothole paths (`PotholeActionStore.swift:366-402`, `APIClient.swift:122-144`) — latent crash under Swift 6/TSan; BGTask handlers registered `using: nil` call `@MainActor` code off-main (`BackgroundTaskRegistrar.swift:51,55`); `UploadPolicy` defaults 401/403/408/413 to `failedPermanent` (`UploadPolicy.swift:53-54`); checkpoint file persists in-privacy-zone coordinates to disk unprotected.
- **Android:** phantom-recording state after force-stop (`PREF_IS_RUNNING` only cleared in `onDestroy`; `ACTION_STOP` is unreachable dead code); `startForeground(location)` crash-loop on API 34+ if location revoked mid-drive (guard runs after `startForeground`); `reportPothole` returns before its coroutine runs and one report disables the button for the session (`pendingActionId` never cleared); photo bytes-step 400/403 → permanent despite KDoc contract; unbounded motion buffer during GPS outages (`ReadingBuilder.kt:57-59`).
- **SQL:** `replay_unmatched_readings` re-adds all originally-accepted readings to aggregates (up to ~24 h inflated public numbers per replay) and never folds pothole candidates; `unmatched_readings` never drains and its 90-day purge never runs (nothing schedules it — privacy retention violation); `quality_corridors` tile layer silently dropped by later `get_tile` redefinitions while the web map still requests it (`road-quality-map-view.tsx:237`); nightly recompute's fixed 24 h window leaves permanent gaps after >1 day downtime (use a watermark); scheduler runs all daily jobs on every deploy on every replica (no advisory lock, no last-run state); find-or-create races can split pothole candidates so neither reaches the corroboration gate.
- **API:** rate-limit ordering lets IP-limited attackers write unbounded `rate_limits` rows via rotating device tokens (check IP bucket first); auth fails open if `PUBLIC_API_KEY` unset (fatal-at-boot when on Railway); non-constant-time compare on the service-role key (`internalAuth.ts:12`) — fix before R2 photos; no world-bounds check on lat/lng at the gateway.
- **Web:** sticky over-broad map error banner (one failed tile → permanent banner); focusable controls inside `aria-hidden` drawer + no Escape close + no focus management (WCAG failure); listbox/tablist ARIA misuse in search and mode switcher; no runtime validation of API rows + **no `error.tsx`/`not-found.tsx`/`loading.tsx` anywhere**; `normalizePublicStats` renders NaN as "NaN km"; feedback dialog destroys a 4000-char draft on Escape; Mapbox geocoding fires per keystroke (billable — debounce it).
- **Ops:** hardcoded fallback API key + raw device token echoed to logs in `replay-snapshot-readings.sh`; `load-municipalities.sh` non-transactional drop/recreate; DATABASE_URL on argv (visible in `ps`) for hours-long imports; keychain password derived from public values in `ios-testflight.yml`.

---

## Cross-cutting themes

1. **Function-redefinition drift is the house failure mode.** The dropped holding insert (fixed), the dropped `quality_corridors` layer (open), and the stale rematch matcher (open) are all last-write-wins regressions in SQL function bodies. Countermeasures: single-source shared logic (one matcher function), contract tests (tile-layer manifest test, matcher parity fixtures), and a lint that flags a migration redefining a function from a non-latest body.
2. **Retention never actually runs — anywhere.** iOS `RetentionPolicy` has zero call sites and the nightly-cleanup BGTask is a no-op; Android `pruneUploadedBefore`/`RetentionPolicy` have zero callers; SQL partition drops have never fired (regex bug); `unmatched_readings` purge is unscheduled; `processed_batches`/`pothole_actions`/`feedback_submissions` (stores `client_ip`) have no GC. Every layer promises retention; none delivers it.
3. **Privacy promises need end-to-end enforcement, not per-platform reimplementation.** Android missing trimming/zones, `pothole_actions` RLS, iOS checkpoint persisting in-zone coordinates, feedback IP retention. A "privacy invariants" test suite that runs against both clients' fixtures and the DB would have caught all of these.
4. **Silent failure is systemic.** Scheduler jobs log-and-swallow (a job that succeeds-while-doing-nothing is invisible — see P1-s2); deploy workflows exit 0 on missing config; gateway has zero request logging/metrics; iOS has 54 `try?` sites; Android's pipeline-init failure records nothing for a whole drive. Priority: per-job last-success timestamps surfaced in `/health/deep` + a scheduled read-only prod probe.
5. **CI doesn't run automatically** for backend/web/iOS (workflow_dispatch only; only Android triggers on PR). pgTAP suites 017/018 were committed without ever being executed. Path-filtered cheap PR jobs (tsc+vitest; deno test+pgTAP) would close the "merge untested migrations" window that produced NEW-1.

---

## Improvements worth scheduling (beyond bug fixes)

- iOS: `#Predicate`/`fetchCount` instead of full-table fetches every 2 s during drives; backoff preservation across network flaps; HTTP-date `Retry-After` parsing; camera failure surfacing.
- Android: drain loop until empty (currently one 200-reading batch per 15-min heartbeat ≈ 800/hr ceiling — an hour drive takes many hours to drain); user-facing retry for `FAILED_PERMANENT`; align feedback-queue retry policy with the readings policy; thermal listener + real power-save state; extend parity script to request/response JSON fixtures (would have caught P1-a3).
- SQL: index on `readings (uploaded_at)`; CHECK constraints on roughness/speed/magnitude (defense against the next function rewrite); fold category/confidence UPDATE into the UPSERT (halves dead tuples on the hottest table); advisory locks around MV refreshes.
- API: structured request logging; graceful shutdown (SIGTERM → server.shutdown + sql.end); `Retry-After` on 503s; cache headers on `/potholes`, `/top-potholes`, `/segments/:id`; in-process cache for the municipality allowlist scan.
- Web: SEO package (metadataBase, canonicals, OG/Twitter cards, sitemap, robots, JSON-LD `Dataset`, per-page metadata on content pages); decide the fate of the fully-built-but-redirected `/reports/*` pages (ship or delete — currently maintained, tested, unreachable); legend missing the "unpaved" category the map paints; make the tsc gate real in CI (currently errors on `open-next.config.ts` locally).
- Ops: staging Railway project (deploy-production is currently the first place a migration meets real Railway PG); document/enable Railway backups + a quarterly restore drill; migration ledger; region-guard for imports.

Also from the pre-launch reviews, still open and still important: iOS P1-2 (thermal keeps 50 Hz sensors), P1-3 (in-zone GPS breadcrumbs survive "Delete local data"), P1-5/P1-6/P1-7; backend P2-1 (UPSERT deadlock one-liner), P2-3 (scheduler alerting — now escalated by P1-s2 above); Deno service still connects as the postgres superuser (tasks.md Active).

---

## Future feature ideas (deduped against roadmap doc 16)

Roadmap already covers: Android ship, calibration drives, battery benchmark, OSM dry-run assertions (B143), share/OG/CSV growth artifacts (B150–153), My Drives, attestation, gamification, French, open-sourcing.

New ideas, roughly ordered by leverage:

1. **Segment score history + trends.** The web drawer already fetches and types `SegmentDetail.history` but never renders it; the nightly job could persist a monthly `segment_aggregates_history` rollup (one row/segment/month). Unlocks sparklines, "worsening this quarter," before/after-repave detection — and feeds seasonal/freeze-thaw analysis (frost-heave season is *the* NS road story) plus de-seasoned trend classification.
2. **Road-authority export + pothole lifecycle analytics.** Per-municipality GeoJSON/CSV of worst segments and corroborated potholes with first/last-seen; a `pothole_status_transitions` audit table gives median-days-to-fix and re-open rates per municipality — the accountability metric journalists and councillors will actually quote. Pairs with an IRI calibration bridge so exports speak the authorities' language.
3. **Scheduled synthetic monitoring + job heartbeats in `/health/deep`** (read-only prod probe every 15–30 min; fail deep health when any scheduler job's last success is stale). Turns the silent-failure theme into an alerting story almost for free.
4. **iOS Live Activity / Dynamic Island for active drives** + App Intents/Action Button "mark pothole" (hands-free is the safety-correct interaction; `ManualPotholeLocator` logic slots straight in) + post-drive summary notification (natural foreground drain moment).
5. **Android automatic drive detection** via Activity Recognition Transition API (`IN_VEHICLE`) — permission already in the manifest, unused; the analog of the iOS passive-monitoring work. Plus expedited drive-end drain WorkRequest.
6. **Share-this-view + segment permalinks with OG images + `/embed` route.** URL schema already exists; viewport→URL sync is nearly free. Embeds for municipal sites/news require only a frame-ancestors carve-out.
7. **Coverage-gap targeting** ("drive here next"): cluster `unmatched_readings` + `get_coverage_tile` 'none' segments into a contributor-facing layer.
8. **Per-device trust scoring** from `processed_batches.rejected_reasons` history — down-weight noisy devices in recompute; a stepping stone to the planned attestation work.
9. **`/municipalities` endpoint** replacing the web's hardcoded manifest; municipality comparison view (fits the existing three-layer aggregate-metrics privacy rule).
10. **ETag/conditional-GET on tiles + stats** once the edge cache is fixed — makes the map nearly free to serve.

---

## Suggested fix order

1. Privacy/data-integrity P0s: P0-4 RLS (one line), P0-5 heading NOT NULL (one line), P0-1 token save (one line + test), P0-2/P0-3 Android privacy layer (real work — consider holding Android field builds until done), P0-7 refresh guard (small function change).
2. P0-6 + P1-g1/g2/g3 as one "gateway hardening" pass (client IP, body caps, edge cache, statement timeouts).
3. P1-o1/o2/o3 deploy-pipeline truthfulness — cheap, and everything else depends on trusting green runs.
4. iOS/Android upload-queue correctness pass (P1-i1/i2, P1-a1/a2/a3) with the missing seam tests.
5. P1-s1 matcher consolidation + P1-s2 retention fix + scheduler heartbeats.
6. Web P1-w1/w2 + error boundaries + a11y batch.
