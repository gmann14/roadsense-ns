# RoadSense NS — Backend + Web Pre-Launch Review (REVISED)

>## ⚠️ REVISION NOTICE — original review ran against a stale branch
>
> The 2026-06-11 review was accidentally run against `codex/testflight-build`,
> **~109 commits behind** the real code (47 edge-function files, 20 migrations,
> and 52 web files differed). Every finding has now been re-validated against
> the true latest code: **`codex/testflight-signing-secrets` @ `34402f2`**
> (2026-05-29), checked out read-only at `/tmp/roadsense-main-review`.
>
> The stale review missed the production architecture entirely: latest does
> **not** deploy per-function Supabase edge functions. Production is a single
> Deno gateway (`supabase/functions/server.ts`) on Railway, fronted by a
> Cloudflare worker (`cloudflare/api-proxy/`) at `api.nsroadsense.ca` /
> `tiles.nsroadsense.ca`, with an in-process scheduler replacing pg_cron.
> That architecture change alone invalidates two P1s and changes several P2s.
>
> All file:line references below are to the worktree at `34402f2`.

**Original date:** 2026-06-11 · **Revised:** 2026-06-12
**Scope:** Supabase migrations + functions gateway, Next.js web explorer (`apps/web`)
**Severity gates:** P0 = before TestFlight · P1 = before public launch · P2 = later

---

## Verdict table

| Finding | Stale claim | Verdict on `34402f2` |
|---|---|---|
| **P0-1** pothole_magnitude / is_pothole unbounded on ingest | unbounded, single batch → fake pothole on public map | **STILL-VALID** (slightly worse: pothole tiles now render from z≥8, was z≥13) |
| **P1-1** no device attestation, Sybil-forgeable `unique_contributors` | client-minted UUID device tokens | **STILL-VALID** |
| **P1-2** potholes published with zero corroboration | `status='active'` is the only gate | **STILL-VALID** (new client-trusted speed≥45 gate doesn't help) |
| **P1-3** intra-day `unique_contributors` inflation | per-batch counts summed in UPSERT | **STILL-VALID** |
| **P1-4** coverage tiles route to wrong edge function | Supabase slug routing sends `/tiles/coverage/...` to `tiles` | **FIXED-ON-LATEST** — production gateway explicitly routes coverage before quality; stale premise (slug routing) doesn't apply |
| **P1-5** province-wide potholes report always empty | 7°×4° bbox vs 10 km cap | **FIXED-ON-LATEST** — report replaced by `/top-potholes` endpoint, no bbox |
| **P1-6** missing CORS on JSON endpoints | segment drawer dead cross-origin | **FIXED-ON-LATEST** — CORS + OPTIONS handled at both gateway and Cloudflare proxy |
| **P1-7** photo reject deletes storage after committing | orphaned image on delete failure | **CHANGED** — bug still in code, but photo endpoints are not mounted on the production gateway (unreachable); downgraded to latent P2. See NEW-2. |
| P2-1 UPSERT deadlock risk | — | **STILL-VALID** |
| P2-2 missed partition cron → hard insert failures | — | **CHANGED** (much mitigated: daily idempotent in-process job; still no DEFAULT partition, log-only failures) |
| P2-3 no alerting on recompute failure | — | **STILL-VALID** (moved: in-process scheduler logs and swallows errors) |
| P2-4 ingest KNN vs rematch matcher inconsistency | — | **STILL-VALID** (details changed: tiered radius, top-5 candidates) |
| P2-5 single `confirm_present` keeps fake pothole alive | — | **STILL-VALID** |
| P2-6 resolved potholes dropped by anon RLS | — | **FIXED-ON-LATEST** — segments now reads via direct Postgres pool, RLS not in path |
| P2-7 ungated `/segments/{id}` detail | — | **STILL-VALID** |
| P2-8 unverified `content_sha256`, stale `pending_upload` rows | — | **CHANGED** — code unchanged but endpoints unmounted in production (moot until photo flow ships) |
| P2-9 IP rate-limit shared-bucket papercut | — | **CHANGED** (partially improved: robust public-IP extraction; `"unknown"` fallback bucket and 10/hr cap remain) |

**Counts:** 8 STILL-VALID (1 P0, 3 P1, 4 P2) · 4 FIXED-ON-LATEST · 5 CHANGED · plus 2 new findings below.

### Follow-up task chips spawned by the stale review

- **P1-4 chip (web coverage tile routing): DISMISS — not warranted.** Production routing is `server.ts`, which registers `route("/functions/v1/tiles/coverage/:z/:x/:y.mvt", …)` *before* the quality-tile route, and `_shared/routes.ts` dispatch is first-match-wins. A passing unit test ("dispatch picks the more specific route declared first", `supabase/functions/server_test.ts`) covers exactly this. Only residual quirk: under a local `supabase functions serve` stack, slug routing would still misroute `/tiles/coverage/...` to the `tiles` function — a local-dev papercut, not a launch bug.
- **P1-5 chip (potholes report bbox): DISMISS — not warranted.** `apps/web/app/reports/potholes/page.tsx` is now just `redirect("/?mode=potholes")`; `apps/web/app/page.tsx:17-20` loads `getTopPotholes(100)` server-side via `/top-potholes` (`get_top_potholes` RPC, province-wide, LIMIT ≤ 100 — `supabase/migrations/20260425004500_top_potholes_report.sql`). The bbox-capped `/potholes` endpoint is only used by the in-drawer nearby list, guarded client-side by `isPotholeBboxWithinLookupCap` (`apps/web/lib/api/client.ts:222-225`, `components/map/segment-drawer.tsx:176`).

---

## Active findings (validated against `34402f2`)

### P0-1 — `pothole_magnitude` / `is_pothole` fully client-trusted on ingest; one forged batch places a max-severity fake pothole on the public map — STILL-VALID

**Where (latest):**
- Edge validator: `supabase/functions/upload-readings/handler.ts:130-135` — `is_pothole` only checked as boolean, `pothole_magnitude` only as finite number. No range.
- Ingest SQL (current definition): `supabase/migrations/20260505130000_tiered_segment_match_radius.sql:84-88` — the `low_quality` rejection bounds `roughness_rms` (0–15) but **not** `pothole_magnitude`; lines 100-101 take `is_pothole`/`pothole_magnitude` verbatim from the client payload.
- Pothole creation: `fold_pothole_candidates` (current definition `supabase/migrations/20260506193000_filter_bike_pothole_reports.sql:9-103`) inserts an **`active`** report from a single device's batch (`confirmation_count = COUNT(*)` of that batch's own readings, line 97).
- Public render: `get_tile` potholes branch (`20260506193000_filter_bike_pothole_reports.sql:161-178`) gates only `status='active' AND z >= 8`. The zoom floor was **lowered from 13 to 8** ("regional pothole mode"), so a forged pothole is now visible at province-overview zooms. `get_potholes_in_bbox` (`20260418193015_public_read_models.sql:51`) and the new homepage top-potholes list (`supabase/functions/top-potholes/pgRuntime.ts:23`, `WHERE status='active'` ordered by `confirmation_count DESC, magnitude DESC`) have the same status-only gate — a forged batch of N readings on one spot can also push the fake to the top of the "most-reported" panel.

**What changed since the stale review:** `fold_pothole_candidates` now requires `speed_kmh >= 45` (line 25) before a sensor pothole goes public — but `speed_kmh` is also client-supplied, so a forger just sets it. Magnitude is cast `NUMERIC(4,2)` (line 19), capping the forgeable value at 99.99 — far above any plausible scale. Telling contrast: the *manual* report path clamps sensor-backed magnitude to 0–8 (`20260425221500_sensor_backed_pothole_actions.sql:41-45`); the bulk-ingest path has no equivalent.

**Fix sketch (unchanged in spirit):** clamp `pothole_magnitude` (e.g. 0–8, matching the manual path) in both the edge validator and the `low_quality` branch; require corroboration (`unique_reporters >= 2` or distinct-device `confirmation_count >= 2`) before a pothole appears in `get_tile`, `get_potholes_in_bbox`, and `get_top_potholes` (pairs with P1-2).

Fixed 2026-06-12 (commit 8e0c381) — NOTE: requires migration deploy + Railway redeploy to take effect. Gateway validator now bounds `speed_kmh` (0–220) and `pothole_magnitude` (0–8 G), rejects `is_pothole=true` below the detector's 1.0 G spike threshold or without a magnitude, and caps pothole-flagged readings per batch at max(5, 25%); migration `20260612090000_clamp_pothole_ingest_bounds.sql` redefines `fold_pothole_candidates` to exclude out-of-bounds magnitude/speed rows and clamp folded magnitude to [0, 8]. Corroboration gating remains tracked under P1-2.

### P1-1 — No device attestation; `device_token` rotation is free → Sybil-forgeable trust signals — STILL-VALID

**Where (latest):** `supabase/functions/upload-readings/handler.ts:78` (`device_token` validated only as UUIDv4), hashed with a pepper at `upload-readings/runtime.ts:66-68`. Rate limits unchanged: device 50 batches/UTC-day, IP 10/hour (`runtime.ts:94-113`). A repo-wide search for App Attest / DeviceCheck finds nothing. The gateway's `PUBLIC_API_KEY` check (`server.ts`) uses the public anon key baked into the shipped app, so it adds no Sybil resistance. Per-device caps in `nightly_recompute_aggregates` (≤3 readings/device/week/segment + p10–p90 trim, current definition `20260425001500_roughness_calibration.sql:95-135`) still defend only against one prolific device, not many forged ones. `unique_contributors` remains the backbone of tile visibility, confidence, and the worst-roads list, and remains forgeable.

**Fix sketch:** unchanged — App Attest/DeviceCheck-bound, server-issued device tokens at the public-launch milestone; until then treat `unique_contributors` as untrusted and keep public thresholds conservative.

Plan written 2026-06-12 — see `docs/implementation/17-device-attestation-and-trust.md` (B160–B164: App Attest / Play Integrity-bound server-issued tokens, enforcement modes, beta-token grandfathering; B167 trust tiers).

### P1-2 — Potholes have no corroboration gate before going public — STILL-VALID

**Where (latest):** `get_tile` potholes branch (`20260506193000:176-177`, `status='active' AND z>=8`); `get_potholes_in_bbox` (`20260418193015:51`); `get_top_potholes` (`20260425004500`, status-only); manual creation still inserts `active` with `confirmation_count=1, unique_reporters=1` (`20260425221500_sensor_backed_pothole_actions.sql:126-150`). Segment heatmap still requires `unique_contributors>=3 AND confidence!='low'`; potholes require one report from one device. The new `speed_kmh >= 45` requirement for sensor potholes and the one-off bike-data cleanup (`20260506193000` DO block) are honest-mistake filters, not abuse resistance — both rely on client-supplied fields.

**Fix sketch:** unchanged — require ≥2 distinct devices for public visibility; keep single-report potholes in a candidate state.

Plan written 2026-06-12 — see `docs/implementation/17-device-attestation-and-trust.md` (B165: `candidate` status + distinct-device promotion to `active`; tightens to attested-only devices once B164 enforces).

Fixed 2026-06-12 (commit cc9bcbe) — NOTE: requires migration deploy + Railway redeploy to take effect. Migrations `20260612181000` + `20260612182000` add the non-public `candidate` status and `pothole_reporter_marks`: `fold_pothole_candidates` and `apply_pothole_action` now insert new potholes as `candidate` and promote to `active` only at ≥ 2 distinct device-token hashes within 15 m / 90 days (sensor and manual paths corroborate each other). `status='active'` stays the single public gate in `get_tile`/`get_potholes_in_bbox`/`get_top_potholes`/`public_stats_mv`/anon RLS, so candidates are invisible with no Deno changes. Existing single-reporter actives grandfathered per doc 15's decision; pgTAP suite `018_pothole_corroboration_gate.sql`. Distinct *physical* devices still wait on B164 attestation (P1-1).

### P1-3 — Intra-day `unique_contributors` inflation by a single device — STILL-VALID

**Where (latest):** `update_segment_aggregates_from_batch`, current definition `supabase/migrations/20260425001500_roughness_calibration.sql:54` — `unique_contributors = segment_aggregates.unique_contributors + EXCLUDED.unique_contributors`, where `EXCLUDED.unique_contributors` is per-batch `COUNT(DISTINCT device_token_hash)` (line 35, = 1 for one device). Confidence flips to `medium` at ≥3 in the same statement (lines 59-73). One device sending 3 batches still fabricates a "medium-confidence" tile-visible segment until the nightly recompute corrects it; tiles cache for 1h (`supabase/functions/tiles/handler.ts:2`, `max-age=3600`). Note the in-process scheduler runs `nightly_recompute_aggregates()` on a `DAY` interval anchored to process start (`supabase/functions/_shared/scheduler.ts:36-44`), so the correction window can be nearly a full day.

**Fix sketch:** unchanged — don't let the incremental path raise confidence/visibility, or recompute true `COUNT(DISTINCT)` for touched segments.

Plan written 2026-06-12 — see `docs/implementation/17-device-attestation-and-trust.md` (B166: exact dedupe via `segment_contributor_marks`; the incremental path can no longer raise confidence on one device's batches).

Fixed 2026-06-12 (commit fca1dc2) — NOTE: requires migration deploy + Railway redeploy to take effect. Migration `20260612180000` adds `segment_contributor_marks` (backfilled from the 6-month readings window): `update_segment_aggregates_from_batch` increments `unique_contributors` only by marks actually inserted and derives confidence from the corrected value, so one device's N batches stay 1/`low` through the incremental path; `nightly_recompute_aggregates` seeds marks for every device it counts; daily GC sweep matches reading retention (cron registration + `_shared/scheduler.ts` job). pgTAP suite `017_segment_contributor_marks.sql` reproduces P1-3. Many-device Sybil forgery remains P1-1 (B160–B164).

### P2-1 — `ON CONFLICT` deadlock risk in incremental aggregate UPSERT — STILL-VALID

Current definition `20260425001500_roughness_calibration.sql:21-57`: per-segment UPSERT with `GROUP BY r.segment_id`, no `ORDER BY` on the conflicting insert → concurrent batches touching overlapping segments can lock rows in opposite orders. Transient 502s under load; replay path makes retries safe. Fix: `ORDER BY segment_id`.

### P2-2 — Missed partition creation → hard insert failures — CHANGED (mitigated)

pg_cron is stubbed out on Railway; an in-process scheduler (`supabase/functions/_shared/scheduler.ts:36-44`) now runs `create_next_readings_partition()` **daily** and at process start (idempotent, multi-replica safe). Residual risk: still no `DEFAULT` partition and job failures are only logged (`runOnce`, lines 75-85) — a persistently failing job across a month boundary still hard-fails inserts, just far less likely than the old monthly cron. Fix: add a DEFAULT partition; alert on repeated job failure.

### P2-3 — No alerting when scheduled jobs fail — STILL-VALID (moved)

All seven background jobs (MV refreshes, partition roll, nightly recompute, pothole expiry, rate-limit GC) run via `scheduler.ts` and swallow errors with a `console.log` (`runOnce`, lines 75-85). A repeatedly failing `nightly-aggregate-recompute` means the P1-3 correction and freshness all silently stall. Fix: alert on consecutive failures (Railway log alerts or a health-check row).

### P2-4 — Ingest KNN matcher inconsistent with rematch matcher — STILL-VALID (details changed)

Ingest (current, `20260505130000:106-145`) selects the top-5 nearest segments filtered only by `is_parking_aisle=FALSE`, applies road-class-tiered radii (45/25/20 m) + heading, picks nearest, then rejects post-hoc if unpaved (line 164). Rematch (`20260418123010:31`) still pre-filters to paved surfaces. A reading nearest an unpaved road but within range of a slightly-farther paved one is dropped at ingest yet would match on rematch. Fix: align candidate filters.

### P2-5 — Single `confirm_present` keeps a fake pothole alive indefinitely — STILL-VALID

`apply_pothole_action` (current, `20260425221500:161-174`) resets `last_confirmed_at` on any `confirm_present`/`manual_report`; `expire_unconfirmed_potholes` fires at 90 days (`20260418165013:203-213`). One device confirming every 89 days keeps an uncorroborated pothole active forever. The new `confirm_fixed` quorum (2 distinct devices in 30 days, `20260425221500:213-228`) helps removal but not retention abuse. Fix: distinct-device confirmations to extend life.

### P2-7 — Direct `/segments/{id}` exposes ungated aggregates — STILL-VALID

`supabase/functions/segments/pgRuntime.ts:43-78` returns full aggregate detail (score, contributors, confidence) for any segment id with no confidence/contributor floor, unlike tiles and the worst-roads MV. Fix: gate or label unverified segments.

### P2-9 — IP rate-limit shared-bucket papercut — CHANGED (partially improved)

`_shared/clientIp.ts` now does careful public-IP extraction (rejects private/CGNAT ranges, walks `x-forwarded-for` right-to-left), but the final fallback is still the literal `"unknown"` shared bucket, and the 10 batches/hour/IP cap is unchanged (`upload-readings/runtime.ts:109-113`). Same recommendation: rely on the device/day cap as primary once attestation lands. Note: the Cloudflare proxy strips `cf-connecting-ip` before forwarding (`cloudflare/api-proxy/src/worker.js:86`), so the gateway depends on Railway's `x-forwarded-for` being trustworthy.

### Latent (unreachable in production today)

- **P1-7 → latent P2 — photo reject orphans storage on delete failure.** `supabase/functions/pothole-photo-moderation/handler.ts:201-207` still commits `status='rejected'` via RPC *before* `deleteObject(...)`, with no compensation (the approve path does roll back its move). Currently unreachable: no photo route is mounted on the production gateway (see NEW-2). Fix before the photo flow ships.
- **P2-8 → latent — client-claimed `content_sha256` never verified; `pending_upload` rows never expire.** `supabase/functions/pothole-photos/handler.ts` unchanged. Same condition: fix before the photo flow ships.

---

## New findings on latest (not in the stale review)

### NEW-1 (P2, regression) — `unmatched_readings` holding flow silently dropped by a later migration

`20260428001647_unmatched_readings_holding_table.sql` created the `unmatched_readings` holding table and rewrote `ingest_reading_batch` so `no_segment_match` rejections are preserved for replay (`INSERT INTO unmatched_readings ... WHERE final_rejection_reason = 'no_segment_match'`, lines 225-251), plus a `replay_unmatched_readings(...)` RPC (line 313). The later `20260505130000_tiered_segment_match_radius.sql` redefined `ingest_reading_batch` **without** that insert — its migration comment only discusses radius tiers, so this looks like an accidental rebase-from-older-body. Net effect on latest: unmatched readings are silently dropped again (the table and replay RPC exist but receive nothing; no scheduler job calls replay either). Fix: re-apply the holding-table insert to the current ingest body and decide whether replay should be a scheduled job.

Fixed 2026-06-12 (commit 7a8a28d) — migration `20260612120000_restore_unmatched_readings_holding_insert.sql` re-creates the current (20260505130000 tiered-radius) ingest body with the 20260428001647 holding insert, `held_for_retry` counter, and response key restored verbatim; requires migration deploy. Whether `replay_unmatched_readings` should be a scheduled job remains open.

### NEW-2 (P1 if photos are a launch feature) — photo endpoints not mounted on the production gateway, but iOS still calls them

The Railway gateway (`supabase/functions/server.ts`, ROUTES array) mounts health, upload-readings, pothole-actions, feedback, stats, segments-worst, segments/:id, potholes, top-potholes, and both tile routes — but **none of** `pothole-photos`, `pothole-photo-moderation`, `pothole-photo-image`. iOS still builds `POST {API_BASE_URL}/functions/v1/pothole-photos` (`ios/Sources/RoadSenseNSBootstrap/Network/Endpoints.swift:19`) against `api.nsroadsense.ca` (`ios/Config/RoadSenseNS.Production.xcconfig:3`), which the proxy passes through to the gateway → 404 `not_found`. Either the photo feature is intentionally deferred (then the iOS entry point should be disabled/flagged off) or the routes need mounting — note the photo flow also depends on Supabase Storage, which the Railway architecture may not provide. Needs an owner decision before TestFlight users can hit a dead endpoint. (If mounted, fix latent P1-7/P2-8 first.)

Fixed 2026-06-12 (commits ed4890d gateway, d4d0090 iOS) — photo uploads now cleanly disabled pending R2. Field impact confirmed before the fix: `UploadPolicy` treats 404 as a transient missing route, so every captured photo sat in `pendingMetadata` forever, re-POSTing the dead endpoint on a backoff capped at 1 hour (never `failedPermanent`; Settings showed "Photo uploads waiting" indefinitely). The gateway now mounts all three photo routes behind `photoUploadsGate` (`supabase/functions/_shared/photoUploads.ts`), answering `503` `photos_disabled` + `Retry-After: 21600` (documented in `docs/implementation/03-api-contracts.md`); iOS flips production `ENABLE_POTHOLE_PHOTOS` to NO, shows "Photos coming soon" at photo-button tap time, and honors the 503 Retry-After so photos queued by older builds probe ~4×/day. Enable for real via: provision the R2 bucket, set `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET` on the Railway service, port the three handlers off supabase-js Storage to an R2 S3 client (fix latent P1-7/P2-8 first), pass the real handler factories to `photoUploadsGate` in `server.ts`, then flip `ENABLE_POTHOLE_PHOTOS` back to YES in `ios/Config/RoadSenseNS.Production.xcconfig` + `.github/workflows/ios-testflight.yml`.

### Other picture-changers verified (not problems)

- **Architecture:** production = single Deno service (`server.ts`) on Railway behind `cloudflare/api-proxy` (auth shim: `?apikey=` → header; tile edge-caching; CORS), domains `api.nsroadsense.ca` / `tiles.nsroadsense.ca` (`cloudflare/api-proxy/wrangler.toml`, `apps/web/wrangler.jsonc`). All JSON handlers now reach Postgres via a direct pool (`supabase/functions/db.ts`), not supabase-js + anon key — which is also what fixed P2-6.
- **`20260427015111_feedback_submissions.sql` + `feedback` function:** new web/iOS feedback endpoint, mounted on the gateway, IP rate-limited, validated server-side. No issues found at review depth.
- **`20260426093000_ingest_cross_batch_dedupe.sql`:** cross-batch duplicate-reading rejection (same device + timestamp + ≤0.5 m) carried into the current ingest body (`20260505130000:156-162`) — closes a replay-ish gap the stale review hadn't flagged.
- The stale review's "verified safe" notes (raw readings not anon-readable, ingest replay protection, health endpoint contents, internal-auth on moderation endpoints, tile cost bounds, aggregate math) were re-checked at lighter depth and still hold, with the caveat that the privacy/RLS posture now matters less because production reads go through the service's own DB role; the public surface is the gateway's route allowlist + `PUBLIC_API_KEY`.

---

## Tests run (in the read-only worktree, 2026-06-12)

- **Deno function/gateway contract tests** (`deno test -A` over all 18 `*_test.ts`): **141 passed, 0 failed, 1 ignored.** Includes `server_test.ts` coverage of route dispatch order (coverage-before-quality), OPTIONS/CORS on all responses, and apikey gating — direct evidence for the P1-4/P1-6 FIXED verdicts.
- **Web `tsc --noEmit`:** clean.
- **Web vitest:** **90 passed / 0 failed** (11 files).
- pgTAP / `supabase test db` and the seeded API smoke scripts were **not run** (require a local Supabase Docker stack). The P0-1/P1-2/P1-3 SQL findings are from reading the latest function definitions (last-write-wins across migrations), not from execution.
- No tracked files in the worktree were modified (`git status` clean; web `node_modules` is gitignored).
