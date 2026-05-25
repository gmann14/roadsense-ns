# Data pipeline triage — 2026-04-30

Investigation into anomalies surfaced by `scripts/pull-device-store.sh` after a 3-day calibration drive. Pulled from Graham's iPhone (iPhone 14 Pro), bundle `ca.roadsense.ios.localdebug`.

## Headline numbers

| Metric | Value |
|---|---|
| Road samples uploaded | 6,574 |
| Server-accepted | 798 (12%) |
| Server-rejected | **5,776 (88%)** |
| Manual pothole marks | 41 |
| Reported as "pending upload" | 37 |
| Actually pending upload | **0** |
| `failed_permanent` marks | 4 |

Plus two map UX gaps the user surfaced during the same drive.

---

## Issue 1 — 88% of road samples rejected as `no_segment_match`

### Evidence

`ZUPLOADBATCH.ZREJECTEDREASONSJSON` aggregated across 29 batches:

| Reason | Samples |
|---|---|
| `no_segment_match` | 5,748 (99.5% of rejections) |
| `duplicate_reading` | 112 |
| `unpaved` | 28 |

### Active migration

The doc previously cited `20260426093000_ingest_cross_batch_dedupe.sql`. The active definition of `ingest_reading_batch` is in **`supabase/migrations/20260428001647_unmatched_readings_holding_table.sql:138-167`** (which redefines the function and adds the `unmatched_readings` holding table — important, see "Recovery" below). Logic line numbers below refer to that file.

### Server matching logic

```sql
-- 138-167 (lateral subquery)
FROM road_segments rs
WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 25)   -- 25 m envelope
  AND rs.is_parking_aisle = FALSE
ORDER BY rs.geom::geography <-> t.geom::geography
LIMIT 3                                                          -- ← only 3 candidates
) candidates
WHERE candidates.distance_m <= 20                                -- final 20 m cutoff
  AND (candidates.heading_diff <= 45 OR candidates.heading_diff >= 135)
ORDER BY candidates.distance_m
LIMIT 1
```

`heading_diff` (line 153-154) is computed from the reading's heading minus the segment's `bearing_degrees`. Designed-in safety valve: if the reading's heading is NULL, `COALESCE(t.heading, rs.bearing_degrees)` makes `heading_diff = 0` so the heading check effectively no-ops.

### Root cause — verified by inspecting the live local DB

After running the verification queries against the local Supabase (`docker exec supabase_db_roadsense-ns psql ...`), the picture is clearer:

| Diagnostic | Result | Verdict |
|---|---|---|
| `SELECT COUNT(*) FROM unmatched_readings` | **3,217** | rows present and recoverable |
| `SELECT COUNT(*) FROM road_segments` | **7** | almost no roads loaded |
| `SELECT * FROM road_segments` | 7 rows named `Coverage None Road`, `Pothole Action Road`, `Replay Coverage Road`, etc. | these are **seed-data fixtures**, not OSM data |
| `SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'osm')` | schema exists, no `osm.ways` table | osm2pgsql never ran |
| Distance bucket of unmatched rows to nearest segment | **all 3,217 are >200 m from any segment** | confirms coverage gap |
| `heading_degrees = 0` rows | **3 of 3,217** (0.1%) | iOS heading bug is *not* the dominant cause for this dataset |
| Heading distribution among unmatched | well-distributed across NE/NW/SE/SW quadrants | course was generally valid during the drive |

**Real root cause for this drive: `osm-import.sh` was never run on this database.** The 7 segments are test fixtures from `supabase/seed.sql`. Driving anywhere outside Halifax produced 100% rejections because no real road network exists locally.

The other two bugs identified earlier (iOS heading=0, LIMIT 3) are still real, just not the dominant factor for this dataset:

#### Bug A (most likely dominant) — iOS sends `0`, not NULL, when GPS course is unknown

`ios/RoadSenseNS/Sensors/LocationService.swift:108`:

```swift
let heading = location.course >= 0 ? location.course : 0
```

`CLLocation.course` returns `-1` when the GPS hasn't established course yet (slow start, urban canyon, multipath, brief stops in traffic). The client coerces that to `0` (due north) and uploads it as a numeric value. The SQL `COALESCE(t.heading, rs.bearing_degrees)` safety valve is therefore **never triggered** — `t.heading` is never NULL.

Effect: a reading with a synthetic `0` heading on an east-west road (`bearing_degrees ≈ 90` or `270`) computes `heading_diff = 90`, which is > 45 and < 135 → **rejected as `no_segment_match`** even though the reading is sitting directly on the segment.

This systematically biases rejections toward roads that aren't aligned within 45° of N-S. In Halifax, that's most of the peninsula's grid.

**Fix:** Change `LocationService.swift:108` to send `nil` (encoded as JSON null / omitted field) when course is invalid. Server already handles NULL correctly via the COALESCE.

```swift
// before
let heading = location.course >= 0 ? location.course : 0
// after
let heading: Double? = location.course >= 0 ? location.course : nil
```

The `LocationSample.headingDegrees` and `Uploader` payload model need to make this field optional and omit it from JSON when nil. Check that the SQL JSON cast `(r->>'heading')::NUMERIC` returns NULL for missing keys (it does).

#### Bug B — `LIMIT 3` candidate cap is too tight in dense road networks

The lateral subquery picks the 3 nearest segments by planar `<->` distance, *then* filters by heading. At intersections, divided highways, or near parking-lot perimeters there can easily be 4+ segments within the 25m envelope:

- **Intersections:** the cross-street segments (perpendicular to travel direction) often beat the correct segment on planar distance, especially for readings recorded mid-intersection.
- **Divided highways:** opposing-direction carriageway segments + a service road + cross-street can fill all three slots before the right-direction segment shows up.
- **Parking lots adjacent to roads:** parking-aisle perimeter segments would fill candidates, except `is_parking_aisle = FALSE` filters them — good. Still, parking-lot driveway segments survive.

Effect: the right segment exists, is within 25m, and matches heading — but it's the 4th-nearest, so it's discarded.

**Fix:** raise `LIMIT 3` to e.g. `LIMIT 10`, *or* push the heading filter into the inner query so only heading-compatible candidates compete for the 3 slots:

```sql
-- preferred: pre-filter by heading inside the inner query
FROM road_segments rs
WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 25)
  AND rs.is_parking_aisle = FALSE
  AND (
    t.heading IS NULL
    OR ABS(((t.heading - rs.bearing_degrees + 540)::INT % 360) - 180) <= 45
    OR ABS(((t.heading - rs.bearing_degrees + 540)::INT % 360) - 180) >= 135
  )
ORDER BY rs.geom::geography <-> t.geom::geography
LIMIT 3
```

Then drop the redundant heading filter on the outer query. This also lets PostGIS use the GIST index more aggressively because heading-misaligned segments never enter the candidate set.

#### Bug C — possible OSM coverage gaps (least likely, but check)

`scripts/osm-import.sh` already imports the entire province (default `nova-scotia`) via Geofabrik — there's no bbox to expand in the original "fix A". So coverage gaps would have to mean either (a) the import was never run on this local Supabase instance, (b) the segmentize step truncated something, or (c) the user drove outside Nova Scotia. Worth verifying but not the first hypothesis.

### Verification before deploying any fix

Run these against the local Supabase to find which bug dominates. If the data is actually in `unmatched_readings` (see "Recovery" below), the queries get easy:

```sql
-- 1. Are rejected readings landing near road segments at all? (Bug C check)
SELECT
  width_bucket(
    (SELECT MIN(ST_Distance(rs.geom::geography, ur.location::geography))
     FROM road_segments rs
     WHERE ST_DWithin(rs.geom::geography, ur.location::geography, 200)),
    0, 200, 10
  ) AS dist_bucket_m,
  COUNT(*)
FROM unmatched_readings ur
GROUP BY 1 ORDER BY 1;
-- expectation: if Bug A or B dominate, most rows have a segment within 0-20m.
-- if Bug C dominates, most rows are 50m+ from any segment.

-- 2. For rejected readings within 20 m of a segment, what's the heading_diff distribution? (Bug A check)
WITH nearest AS (
  SELECT ur.id, ur.heading_degrees,
    (SELECT rs.bearing_degrees
     FROM road_segments rs
     WHERE ST_DWithin(rs.geom::geography, ur.location::geography, 25)
       AND rs.is_parking_aisle = FALSE
     ORDER BY rs.geom::geography <-> ur.location LIMIT 1) AS bearing
  FROM unmatched_readings ur
)
SELECT
  ur.heading_degrees = 0 AS client_sent_zero_heading,
  ABS(((heading_degrees - bearing + 540)::INT % 360) - 180) BETWEEN 46 AND 134 AS heading_blocks_match,
  COUNT(*)
FROM nearest
GROUP BY 1, 2;
-- expectation: if Bug A dominates, you'll see a pile of `client_sent_zero_heading=true,
-- heading_blocks_match=true` rows.

-- 3. For rejected readings within 20 m, was the correct segment outside the LIMIT 3? (Bug B check)
SELECT COUNT(*) FROM unmatched_readings ur
WHERE EXISTS (
  SELECT 1 FROM (
    SELECT rs.id, ROW_NUMBER() OVER (ORDER BY rs.geom::geography <-> ur.location) AS rk,
           ABS(((ur.heading_degrees - rs.bearing_degrees + 540)::INT % 360) - 180) AS hdiff
    FROM road_segments rs
    WHERE ST_DWithin(rs.geom::geography, ur.location::geography, 25)
      AND rs.is_parking_aisle = FALSE
  ) c
  WHERE c.rk > 3 AND (c.hdiff <= 45 OR c.hdiff >= 135)
);
-- expectation: if Bug B dominates, this count is large.
```

### Recovery status — DONE

`unmatched_readings` retained 3,217 rows from this drive (90-day TTL). `replay_unmatched_readings()` was extended (migration `20260430120000_segment_match_heading_prefilter.sql`) with:

- New strict-match logic mirroring the fixed `ingest_reading_batch` (heading prefilter inside ST_DWithin, LIMIT 5).
- A second-pass "single dominant candidate" matcher for legacy rows.

Recovery sequence executed 2026-04-30:

1. `scripts/osm-import.sh` (cached pbf was corrupt on disk; redownloaded). 86 s for osm2pgsql, ~30 s for segmentize/tag passes. Result: **1,744,628 road segments** for Nova Scotia.
2. `SELECT replay_unmatched_readings(50000, 0);` →

```json
{
  "promoted": 3199,
  "promoted_strict": 3199,
  "promoted_fallback": 0,
  "still_unmatched": 18,
  "purged_expired": 0,
  "affected_batches": [16 UUIDs]
}
```

**3,199 of 3,217 rows recovered (99.4%).** 18 still unmatched — probably parking lot, unpaved, or genuinely off-road captures that the matcher correctly rejects. Strict-match alone covered everything; the fallback "single dominant candidate" pass wasn't needed for this dataset (which makes sense given heading=0 was 0.1% of the corpus).

`readings` table grew from a few hundred to **7,602 rows**. `update_segment_aggregates_from_batch` was called for each of the 16 affected batches inside the replay function, so segment aggregates are up to date.

### Suggested fixes — revised

**A. Fix iOS heading null-handling (Bug A)** — make `LocationSample.headingDegrees` optional, send NULL when `location.course < 0`. ~30 lines across `LocationSample`, `Uploader` payload, and `LocationService`. Add a unit test that builds a `CLLocation` with `course = -1` and asserts the encoded JSON omits `heading`.

**B. Pre-filter candidates by heading inside the inner query (Bug B)** — pushes the heading constraint into the GIST-indexed scan and removes the LIMIT-3-too-tight failure mode in one change. New migration. ~10 lines of SQL.

**C. Replay holding table** — once A + B are deployed and migrations applied, `SELECT replay_unmatched_readings(50000, 0);` should reclaim the bulk of the 5,748. Then re-check rejection rate on subsequent drives.

**D. Verify OSM coverage (Bug C)** — only worth doing if the verification queries above show readings 50m+ from any segment. If they do, follow up with a fresh `scripts/osm-import.sh` run.

**Recommendation (post-verification):** Bugs A and B were fixed pre-emptively for future drives — they're real, just not the dominant cause of this specific dataset. The dominant cause is **D** (no OSM data). To recover the 3,217 lost rows: run `osm-import.sh`, then `SELECT replay_unmatched_readings(50000, 0);`.

### Implementation status (2026-04-30)

| Fix | Status | Notes |
|---|---|---|
| Bug A — iOS heading null | ✅ Implemented | `LocationService.swift:108`, `UploadReadingPayload.heading: Double?`, `Uploader.swift:81-94`, `ReadingBuilder.weightedHeading/headingVarianceDegrees` skip negative samples. New test in `UploadRequestFactoryTests.omitsHeadingKeyWhenNil`. |
| Bug B — SQL heading prefilter | ✅ Implemented | Migration `20260430120000_segment_match_heading_prefilter.sql`. Applied to local DB. Pushes heading filter into ST_DWithin, bumps LIMIT 3 → 5 in both `ingest_reading_batch` and `replay_unmatched_readings`. Adds "single dominant candidate" recovery pass. |
| Bug C — replay against fixed logic | ✅ Run | 3,199 of 3,217 promoted (99.4%) after OSM was loaded. |
| Bug D — OSM coverage (local) | ✅ Fixed | `osm-import.sh` re-run with fresh pbf download. 1,744,628 segments now in local `road_segments`. |
| Production migration | ✅ Applied | `20260430120000_segment_match_heading_prefilter.sql` applied to Railway prod via `psql`. Prod already had full OSM (1,744,421 segments). Pre-existing prod unmatched_readings count: 4 (all at the same Halifax coord 25.5 m from Barrington Street — appear to be test fixtures, correctly held by 20 m cutoff). |
| iOS app build verification | ✅ Built | `xcodebuild -scheme RoadSenseNS -configuration "Local Debug" -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED. |
| Setup ergonomics | ✅ Improved | `local-backend-up.sh` now warns when `road_segments < 100` and offers `WITH_OSM_IMPORT=1` to run the import inline. `osm-import.sh` verifies cached pbf against Geofabrik's `.md5` (with size-fallback) before reusing it. |
| Still-unmatched audit (local) | ✅ Inspected | 18 rows: 3 seed fixtures + 13 on `Holder Road` (residential unpaved, correctly excluded by surface filter) + 1 service road tagged `is_parking_aisle = TRUE` + 1 motorway-link 25m away. No hidden bugs. |

---

## Issue 2 — Manual pothole upload state is misreported

### Evidence

Splitting `ZPOTHOLEACTIONRECORD` by `ZUPLOADEDAT` presence:

| State | uploadedAt? | Count | Actual meaning |
|---|---|---|---|
| `pending_upload` | **set** | 37 | Successfully uploaded |
| `failed_permanent` | null | 4 | Genuinely failed |

### Root cause

`PotholeActionUploadState` enum (`ios/RoadSenseNS/Persistence/Models/PotholeActionRecord.swift:10-14`) has no terminal "uploaded" case. On success, `applyUploadSuccess` only sets `uploadedAt = now` (intentionally — see ADR comment about `reconcileManualReportStats` needing the row preserved). The local report at `scripts/local-ios-quality-report.sh:146` filters by `ZUPLOADSTATERAWVALUE = 'pending_upload'` without also checking `ZUPLOADEDAT IS NULL`.

### Suggested fix

One-line script change in `local-ios-quality-report.sh:146`:

```sql
-- before
CAST(COUNT(*) FILTER (WHERE ZUPLOADSTATERAWVALUE = 'pending_upload') AS TEXT)
-- after
CAST(COUNT(*) FILTER (
    WHERE ZUPLOADSTATERAWVALUE = 'pending_upload'
      AND ZUPLOADEDAT IS NULL
) AS TEXT)
```

Apply the same filter to the `since-last-report` block (search for `manual_marks_pending_upload` upstream).

**Effort:** trivial. **Risk:** none — script-only.

---

## Issue 3 — 4 manual pothole marks failed permanently due to off-WiFi network errors

### Evidence

The 4 `failed_permanent` rows all have:

- `ZLASTHTTPSTATUSCODE = NULL` (no server response)
- `ZLASTREQUESTID = NULL` (request never reached the server)
- `ZUPLOADATTEMPTCOUNT = 6` (hit the retry ceiling)

### Root cause

Local debug build is hardcoded to a hostname only resolvable on home WiFi:

```
# ios/Config/RoadSenseNS.Local.secrets.xcconfig:2
API_BASE_URL = http:/$()/Grahams-MacBook-Air.local:54321
```

(The `$()` is an xcconfig-comment escape — `//` would otherwise start a line comment. Effective value is `http://Grahams-MacBook-Air.local:54321`.)

`UploadPolicy.evaluate` (`ios/Sources/RoadSenseNSBootstrap/Network/UploadPolicy.swift:43-51`) treats network errors the same as recoverable HTTP failures: 5 retries with exponential backoff (1+2+4+8+16 = 31s of cumulative inter-retry delay) before flipping to `failedPermanent`. When the phone is off home WiFi for the duration of a drain attempt sequence, marks die.

The recovery hook `PotholeActionStore.recoverRecoverableFailures` (line 234, gated by `isRecoverableFailureStatus` at line 288) explicitly only re-queues marks where `lastHTTPStatusCode` is one of {404, 408, 429, 5xx} — **it skips network errors** (NULL status). It is invoked from `AppModel.handleAppDidBecomeActive` (`ios/RoadSenseNS/App/AppModel.swift:235`), so it does run on each foreground transition, but a NULL-status row is never resurrected by it. Once back on WiFi, dead marks stay dead unless the user manually triggers `retryFailedActions` from Settings.

### Suggested fixes

**A. Treat `lastHTTPStatusCode IS NULL` (network error) as recoverable** in `recoverRecoverableFailures`. Five lines. Off-WiFi failures will auto-retry next time the drain runs on WiFi.

**B. Add a recovery trigger on connectivity restoration** — call `recoverRecoverableFailures` from a `NWPathMonitor` `.satisfied` transition, not just on app launch / drain. Requires plumbing a network monitor into the app shell if one doesn't exist.

**C. Bump retry budget for network errors specifically** — e.g. infinite retries with capped backoff instead of 5+permanent. Simpler than B but still requires app to be foregrounded to drain.

**D. ~~UI surface for failed marks~~ (already shipped).** `SettingsView.swift:254-288` already renders a "Retry failed pothole marks" button gated on `model.potholeActionStatusSummary.failedPermanentCount > 0`, plus a per-row failed-action list (line 284). It calls `AppModel.retryFailedPotholeActions` → `potholeActionStore.retryFailedActions(ids:)`. Verify `failedPermanentCount` is being populated correctly so the button surfaces during the failure mode observed here; no new UI work is needed.

**Recommendation:** A. B is overkill for the failure mode here; C masks the real fix (proper network awareness). D is already in place — confirm `failedPermanentCount` plumbing instead of building net-new UI.

**Note:** This bug is partially self-inflicted by the local-debug URL choice. Production builds use a real hostname over the public internet and won't hit this as often. But the underlying retry-budget issue exists in production too — any drive through a cellular dead zone >31s will burn marks.

---

## Issue 4 — Map stops following user dot after manual pan

### Evidence

`ios/RoadSenseNS/Features/Map/RoadQualityMapView.swift:15`:

```swift
@State private var viewport: Viewport = .followPuck(zoom: 13.8, bearing: .constant(0))
```

The Mapbox SDK automatically switches `viewport` from `.followPuck` to `.camera` mode when the user pans/zooms. RoadQualityMapView has:

- No `.onCameraChanged` listener to detect the switch.
- No recenter button (Mapbox default compass/scale ornaments are explicitly hidden at line 68-71).
- No timer to auto-resume follow.

Result: once you nudge the map, follow is lost permanently for that session.

### Suggested fix

Add a recenter FAB shown only when the viewport is not in follow mode:

1. Add `.onCameraChanged { event in lastUserInteractionAt = Date() }` to the Map.
2. Track `@State private var isFollowing: Bool = true` and flip false when a user gesture is detected (`event.timing == .userInteraction` if the SDK exposes that, otherwise compare viewport state).
3. Render an SF-Symbol button (`location.fill` / `location.north.fill`) bottom-trailing when `!isFollowing`. Tap action: `viewport = .followPuck(zoom: currentZoom, bearing: .constant(0))`.

Optional: add a 30-second timer after the last user gesture to auto-resume follow. I'd skip this initially — Google Maps doesn't do it and explicit user control is clearer.

**Effort:** ~30 min. **Risk:** low — additive UI change.

---

## Issue 5 — Road quality colors are invisible despite being implemented

### What exists today

The full overlay pipeline is already wired up:

- **Server tiles:** `supabase/functions/server.ts:127` → `get_tile()` (`supabase/migrations/20260426170000_show_scored_roads_at_default_zoom.sql`) returns ST_AsMVT with `segment_aggregates` and `potholes` layers.
- **iOS consumes them:** `RoadQualityMapView.swift:311-344` (`VectorSource(id: "roadsense-quality-source")`) at zoom 10-16.
- **Color styling:** `RoadQualityMapView.swift:346-360` matches `category` to design tokens (smooth=green, fair=yellow, rough=orange, very_rough=red, unpaved=warning).
- **On-device overlay:** `LocalDriveOverlayStyleContent` at line 173 colors un-uploaded readings as a dashed line.
- **Pothole markers:** `RoadQualityMapView.swift:332-343` renders red circles from the `potholes` source layer at zoom 13+.

### Why the user sees little/no color

Three compounding reasons:

1. **Server tiles unreachable off-WiFi** — same `Grahams-MacBook-Air.local:54321` issue as Issue 3. When driving, tile requests time out and the segment layer is empty.
2. **Server only returns ACCEPTED segments** — and 88% of readings are rejected (Issue 1), so even on WiFi the server-side coverage of *user-driven* roads is thin.
3. **On-device drive overlay only shows un-uploaded, un-trimmed readings** — `ReadingStore.localDriveOverlayPoints()` (line 457) filters `uploadedAt == nil AND droppedByPrivacyZone == false AND endpointTrimmedAt == nil` with a 500-point cap. Once a reading uploads (even if rejected!) or gets trimmed as a trip endpoint, it disappears from the user's map. Net effect: user can never see their *historical* drives, only their current pending-upload trail — and even that gets clipped at trip endpoints.

### Suggested fix

**A. Add a "my drives" on-device overlay** that does NOT filter on `uploadedAt`. Show all (or last N thousand) readings as colored line segments, regardless of upload state. This gives the user a persistent, offline-first view of the roads they've personally driven and how rough each was.

Implementation sketch:
- New method `ReadingStore.allDriveOverlayPoints(limit:)` that drops the `uploadedAt == nil` filter. Decide explicitly whether to keep `endpointTrimmedAt == nil` (trim cleans up GPS noise at park-up; probably keep) and `droppedByPrivacyZone == false` (must keep — privacy contract).
- New `MyDrivesOverlayStyleContent` MapStyleContent (parallel to `LocalDriveOverlayStyleContent`) using a solid line at lower opacity to distinguish from the bright dashed "current drive" overlay.
- Toggle in map settings to show/hide.
- 500-point cap is too small for "historical drives" — pick a larger limit (e.g. 50k) and verify Mapbox GeoJSON source can handle it without main-thread jank, or switch to vector-tiling on-device.

**B. Cache server tiles** — Mapbox SDK has built-in tile caching, but the cache may not survive offline trips. Verify; consider pre-fetching tiles for the user's home region.

**C. Tap-to-show details on potholes** — currently only segments are tappable. Add a `TapInteraction(.layer(potholeLayerID))` that shows a small detail card.

**Recommendation:** A is the clearest user-facing win and works offline. B is plumbing only worth doing once A ships. C is nice-to-have.

---

## Suggested execution order

| # | Fix | Effort | Risk | User-visible? |
|---|---|---|---|---|
| 1 | Map recenter button (Issue 4) | 30 min | Low | Yes |
| 2 | "My drives" overlay (Issue 5A) | 1 h | Low | Yes |
| 3 | Quality report filter (Issue 2) | 5 min | None | Internal |
| 4 | Network-error recovery for marks (Issue 3A) | 30 min | Low | Indirect |
| 5 | Verify `failedPermanentCount` surfaces the existing retry button (Issue 3D) | 15 min | None | Yes |
| 6 | Verification queries on `unmatched_readings` (Issue 1) | 15 min | None | No (diagnostic) |
| 7 | iOS heading NULL fix (Issue 1A) | 45 min | Low | Yes (more accepted samples) |
| 8 | Pre-filter candidates by heading in SQL (Issue 1B) | 30 min | Low — additive migration | Yes |
| 9 | `SELECT replay_unmatched_readings(50000, 0)` (Issue 1C) | 5 min | Low — idempotent | Yes (recovers ~5,748 rows) |
| 10 | OSM coverage refresh (Issue 1D) | 1-2 h | Med | Conditional on query #1 |

Items 1-5 are within scope for one session. Item 6 (queries) gates 7-10. Items 7-9 are tightly coupled — ship A+B in one PR, then trigger replay. Item 10 only if query #1 says coverage gaps exist.

---

## Files and lines referenced

- `ios/RoadSenseNS/Persistence/Models/PotholeActionRecord.swift:10-14, 39`
- `ios/RoadSenseNS/Persistence/PotholeActionStore.swift:213` (`retryFailedActions`), `:234-253` (`recoverRecoverableFailures`), `:288-298` (`isRecoverableFailureStatus`), `:394-405` (`applyUploadSuccess`)
- `ios/RoadSenseNS/App/AppModel.swift:214-222, 233-239`
- `ios/RoadSenseNS/Features/Settings/SettingsView.swift:254-288`
- `ios/RoadSenseNS/Persistence/ReadingStore.swift:457-476`
- `ios/RoadSenseNS/Network/Uploader.swift:146-199`
- `ios/Sources/RoadSenseNSBootstrap/Network/UploadPolicy.swift:43-51`
- `ios/RoadSenseNS/Features/Map/RoadQualityMapView.swift:15, 68-72, 311-360`
- `ios/Config/RoadSenseNS.Local.secrets.xcconfig:2`
- `supabase/migrations/20260428001647_unmatched_readings_holding_table.sql:138-167` (active `ingest_reading_batch`), `:225-251` (`unmatched_readings` insert), `:313+` (`replay_unmatched_readings`)
- `supabase/migrations/20260426093000_ingest_cross_batch_dedupe.sql` *(superseded by the 28th's migration; do not edit — kept for migration history)*
- `supabase/migrations/20260426170000_show_scored_roads_at_default_zoom.sql`
- `supabase/functions/server.ts:127`
- `ios/RoadSenseNS/Sensors/LocationService.swift:104-121`
- `scripts/local-ios-quality-report.sh:146`
