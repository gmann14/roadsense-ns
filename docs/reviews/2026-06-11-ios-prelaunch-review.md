# iOS Pre-Launch Review — 2026-06-11 (REVISED 2026-06-12)

> ## ⚠️ REVISION NOTICE — original review ran against a stale branch
>
> The 2026-06-11 review was accidentally executed against `codex/testflight-build`
> (merge-base `f889c9d`, 2026-04-24) — **131 commits behind** the code that actually
> ships to TestFlight. The owner's field testing correctly showed background
> collection working; the review's headline P0 was an artifact of the stale checkout.
>
> **This revision re-validates every finding against the true latest code:**
> `codex/testflight-signing-secrets` @ `34402f2` (2026-05-29, main + 22 commits),
> checked out read-only at the time of review. All file:line references below are
> validated against that commit. `swift test` for the Bootstrap package was re-run
> against it (see Verification).
>
> Key context: the two worst stale findings (P0-1 background collection, P0-5
> endpoint trimming) were fixed on the mainline on **2026-04-24** (`7fffe1b`,
> `8b0f97d`) — the same day the stale branch diverged and **before any TestFlight
> build existed** (release workflow added 2026-05-13). They were never true of
> shipping code.

Priorities: **P0** = fix before wider TestFlight distribution, **P1** = fix before
public release, **P2** = later. All paths relative to repo root.

---

## Verdict table

| ID | Original finding | Verdict | Notes |
|----|------------------|---------|-------|
| P0-1 | Background collection dead (`allowsBackgroundLocationUpdates` never set) | **STALE-ARTIFACT** | Set since `7fffe1b` (2026-04-24): `LocationService.swift:39`, plus SLC monitoring `:69-71`. See "How background collection actually works" below. |
| P0-2 | Pause→resume permanently kills sensor streams | **STILL-VALID** | Streams still created once in `init`; `stopMonitoring()` still cancels consumers. Remains **P0**. |
| P0-3 | Checkpoint restore sets `isCollecting=true` without starting sensors | **CHANGED** | Core bug fixed (restore now resumes via real `startCollection()`). Residual: `stopCollection()` still never clears the checkpoint → spurious resume. Downgraded to **P2**. |
| P0-4 | Privacy-zone randomized offset never applied | **STILL-VALID** | `PrivacyZoneFactory.makeZone` still dead code; `saveZone()` stores the raw coordinate. Remains **P0** (privacy-spec violation, trivial fix). |
| P0-5 | Endpoint trimming not implemented | **STALE-ARTIFACT** | Fully implemented since `8b0f97d` (2026-04-24): `DriveEndpointTrimmer` + drive sessions + upload gating + fragment repair, with tests. |
| P0-6 | Upload retry goes `failedPermanent` after 5 attempts; offline drains burn attempts; no network gating | **STILL-VALID** | Policy unchanged; `UploadEligibilityPolicy` still dead code; no `NWPathMonitor`. Failure is now *visible* with a retry button, but stranding is still automatic. Remains **P0**. |
| P1-1 | No driving-detection hysteresis (flaps at red lights) | **CHANGED** | 60s stop-grace period + GPS-speed bootstrap added. Confidence still ignored; `DrivingHeuristic` still dead code. Residual downgraded to **P2**. |
| P1-2 | Thermal throttling rejects data but keeps 50Hz sensors running | **STILL-VALID** | Unchanged. **P1**. |
| P1-3 | Exact in-zone GPS breadcrumbs persisted locally forever; checkpoint survives "Delete local data" | **STILL-VALID** | Raw in-zone fixes still persisted; checkpoint still contains in-zone coords and is not cleared on delete. Per-drive delete + counts now surfaced (partial mitigation). **P1**. |
| P1-4 | Invalid GPS course mapped to heading 0° | **STILL-VALID** | `LocationService.swift:108` unchanged. **P1**. |
| P1-5 | Retention/nightly cleanup never scheduled; O(N) full-store scans | **STILL-VALID (escalated)** | Nightly cleanup still a no-op and never submitted; `RetentionPolicy` dead. New: full-store scans now run on *every location sample* via `stateDidChange` → `refreshCollectionStats()`. **P1**. |
| P1-6 | Drives under 100 pending readings may not upload for a long time | **STILL-VALID** | Same ≥100 gate on backgrounding. **P1** (field-test visibility). |
| P2-1 | Pre-window motion accumulation pollutes first window after GPS gap | **STILL-VALID** | Same `isEmpty` branch. **P2**. |
| P2-2 | Mixed clock bases (motion = boot time, location = epoch) | **STILL-VALID** | **P2**. |
| P2-3 | `HighPassBiquad` implemented but unused | **FIXED-ON-LATEST** | Wired into `RoughnessScorer.swift:27` (`makeButterworth`). |
| P2-4 | 200-with-unparseable-body treated as network error | **STILL-VALID** | `UploadResponseParser.parse` throws on bad 200 body (`UploadResponseParser.swift:17-20`); `Uploader` catch-all counts an attempt. **P2**. |
| P2-5 | 50Hz pipeline + checkpoint encoding on the main actor | **STILL-VALID** | `SensorCoordinator` still `@MainActor`; checkpoint JSON-encoded on main. **P2**. |
| P2-6 | Queued readings not re-filtered when a zone is added later | **STILL-VALID** | `refreshPrivacyZones()` only updates the live filter. **P2**. |
| P2-7 | Misc (always-upgrade one-shot, BG expiration race, radius doc mismatch, …) | **CHANGED** | Always-upgrade now polls then deep-links to Settings (fixed, `AppModel.swift:272-292`). BG `expirationHandler` race and 250/300 vs 500m radius doc mismatch remain. **P2**. |
| Fix-1 | `ReadingBuilder` motion buffer unbounded during GPS outages (cap applied to stale branch as uncommitted change) | **STILL-VALID on latest** | Latest `ReadingBuilder.addMotionSample` is an uncapped append. **PORT the uncommitted fix** (see "Uncommitted fix disposition"). **P1**. |

**Counts:** 2 STALE-ARTIFACT · 1 FIXED-ON-LATEST · 14 STILL-VALID · 3 CHANGED (20 findings total).

---

## How background collection actually works on latest (P0-1 post-mortem)

For the record, since the stale review claimed the opposite — the full flow on
`34402f2`:

1. **Entitlement & manager config** — `ios/RoadSenseNS/Resources/Info.plist:74-78`
   declares `UIBackgroundModes: location, processing, fetch`.
   `ios/RoadSenseNS/Sensors/LocationService.swift:38-42` configures the
   `CLLocationManager` in `init`: `allowsBackgroundLocationUpdates = true`,
   `pausesLocationUpdatesAutomatically = false`, `activityType = .automotiveNavigation`,
   `distanceFilter = 5`.
2. **Continuous keep-alive** — `startPassiveMonitoring()` (`LocationService.swift:67-74`)
   runs `startUpdatingLocation()` *continuously* while monitoring is enabled (not just
   while collecting), plus `startMonitoringSignificantLocationChanges()` (`:69-71`).
   The continuous updates keep the process alive in the background; with `.always`
   authorization this survives lock/app-switch indefinitely
   (`CollectionReadiness.evaluate` reports `.enabled` only for `.always`; `.whenInUse`
   surfaces `upgradeRequired`).
3. **Relaunch after jetsam/reboot** — an SLC event relaunches the app; `RoadSenseNSApp.init`
   → `AppContainer.bootstrap` → `ContentView.init` constructs `AppModel`
   (`ios/RoadSenseNS/App/ContentView.swift:17-26`), whose `init` calls
   `syncPassiveMonitoringState()` (`AppModel.swift:136`, `:609-621`) →
   `SensorCoordinator.startMonitoring()` — no foreground interaction required.
4. **Collection restart** — `startMonitoring()` restores a fresh checkpoint
   (`SensorCoordinator.swift:418-443`); if it recorded `wasCollecting`, collection
   resumes via a real `startCollection()` (`:179-184`, `:262-279`). Independently,
   a **GPS-speed bootstrap** starts collection when a sample arrives at ≥45 km/h with
   ≤50m accuracy (`SensorCoordinator.swift:31-32`, `:312-318`) — covering CMMotionActivity
   latency/unavailability in background relaunches — and the activity stream
   (`drivingTask`, `:166-177`) starts it on the next `automotive` event.
5. Note: `BackgroundCollectionPolicy` in the Bootstrap package is *still* unreferenced
   from the app target — the behavior it models is hardcoded in `LocationService`.
   Harmless, but worth deleting or wiring to avoid future stale-review confusion.

---

## Active findings

### P0 — fix before wider TestFlight distribution

### P0-2. Pause→resume permanently kills all sensor streams (single-use `AsyncStream`) — STILL-VALID

> **Fixed 2026-06-12 (commit ef0ce7f):** services now vend a fresh stream per consumer via `makeSampleStream()`; start→stop→start regression test added.
- `ios/RoadSenseNS/Sensors/LocationService.swift:29-35`,
  `ios/RoadSenseNS/Sensors/MotionService.swift:24-28`,
  `ios/RoadSenseNS/Sensors/DrivingDetector.swift:17-23` — each service still creates its
  `AsyncStream` **once in `init`**.
- `ios/RoadSenseNS/Pipeline/SensorCoordinator.swift:189-206` — `stopMonitoring()` cancels
  `drivingTask`/`locationTask`/`motionTask` (`:193-195`). Cancelling the iterating task
  terminates an `AsyncStream`; the new `for await` loops created by the next
  `startMonitoring()` (`:152-177`) complete immediately and all subsequent `yield`s are
  dropped.
- Reachable from: Settings pause toggle
  (`ios/RoadSenseNS/Features/Settings/SettingsView.swift:99-101` →
  `AppModel.stopPassiveMonitoring()` / `startPassiveMonitoring()`,
  `ios/RoadSenseNS/App/AppModel.swift:254-270`) and from
  `syncPassiveMonitoringState()` (`AppModel.swift:609-621`) whenever readiness flaps
  (permission revoked and re-granted).
- Note the GPS-speed bootstrap does **not** rescue this: it lives inside
  `handleLocationSample`, which is fed by the dead location stream.

**Field impact:** tester toggles "pause collection" off and on and the app silently never
collects again until force-quit. UI still reports monitoring on (`isMonitoring = true`),
so diagnostics look healthy.

**Fix sketch:** create a fresh stream per `start()` (e.g. `AsyncStream.makeStream(of:)`
behind `func makeSamples() -> AsyncStream<...>`), or never cancel the consumer tasks and
gate with `isMonitoring`.

### P0-4. Privacy-zone randomized offset is never applied — zone center is the user's exact home — STILL-VALID

> **Fixed 2026-06-12 (commit ef0ce7f):** offset applied in `PrivacyZoneStore.save` via `PrivacyZoneFactory.makeZone`, plus a guarded one-time migration re-offsetting legacy raw zone centers on launch.
- `ios/RoadSenseNS/Features/PrivacyZones/PrivacyZonesView.swift:402-410` — `saveZone()`
  stores the raw map-reticle coordinate (`draftCenter`) directly via
  `PrivacyZoneStore.save(...)` (`ios/RoadSenseNS/Persistence/PrivacyZoneStore.swift:32-43`).
- `ios/Sources/RoadSenseNSBootstrap/Privacy/PrivacyZone.swift:20` —
  `PrivacyZoneFactory.makeZone(...)` (grid snap + 50–100m random offset) is tested and
  **never called from production code** (only `distanceMeters` / `boundaryCoordinates`
  helpers are used, `PrivacyZonesView.swift:440`, `:547`).
- Violates the project's own spec: `docs/implementation/01-ios-implementation.md:899-900`
  ("We store ONLY the offset coordinates"), `:604`, and the launch checklist
  `docs/implementation/06-security-and-privacy.md:210`.

**Re-assessment vs stale review:** endpoint trimming now exists and removes the
60s/300m around trip endpoints, which blunts the worst home-endpoint exposure. But the
upload filter still drops a circle centered *exactly* on home
(`PrivacyZoneFilter`), so through-traffic disappearance points on roads crossing the
zone still triangulate the exact center, and the local store carries the user's exact
home coordinate in plaintext SwiftData. Kept **P0** because it breaks a documented
privacy commitment and the fix is one call at the save site.

**Fix sketch:** route `saveZone()` (better: `PrivacyZoneStore.save`) through
`PrivacyZoneFactory.makeZone(tappedLatitude:longitude:requestedRadiusMeters:randomAngleRadians:randomDistanceMeters:)`
with `Double.random` inputs, and persist only the offset center. Document residual risk:
offset is per-zone at creation, so the *offset* center is still recoverable; home stays
within ~170m (matches "neighborhood-level" intent — soften any "defeats triangulation"
claim).

### P0-6. Upload retry policy permanently fails batches after ~31s of cumulative backoff; offline drains burn attempts — STILL-VALID

> **Fixed 2026-06-12 (commit ef0ce7f):** transport/5xx/404 failures retry with capped backoff (max 1h) instead of `failedPermanent`; only 4xx rejection strands. Drains gated on new `NetworkPathMonitor`, with requeue on connectivity restore.
- `ios/Sources/RoadSenseNSBootstrap/Network/UploadPolicy.swift:35-51` — unchanged: 5xx,
  404 and network errors get `retry(2^(n-1) s)` for attempts 1–5 (1,2,4,8,16s), then
  `failedPermanent` at attempt 6. No jitter, no long backoff.
- `ios/RoadSenseNS/Network/Uploader.swift:104-116` — plain connectivity failures
  (airplane mode, rural dead zone, server down) still map to
  `UploadAttemptResult.networkError` and count toward the same 5-attempt cap (same
  pattern for pothole actions `:162-175` and photos `:217-230`).
- Still no network gating: `UploadEligibilityPolicy` / `NetworkPathSnapshot`
  (`ios/Sources/RoadSenseNSBootstrap/Network/UploadEligibilityPolicy.swift:18-39`) remain
  **dead code**; no `NWPathMonitor` anywhere in the app target (verified by grep).
- Stranding mechanics unchanged: `UploadQueueCore.prepareNextBatch` skips
  `failedPermanent` batches and only picks readings with `uploadBatchID == nil`
  (`ios/Sources/RoadSenseNSBootstrap/Persistence/UploadQueueCore.swift:127-132`).
- Foreground drains throttled to one per 30s (`ios/RoadSenseNS/App/ContentView.swift:117-131`),
  so the 1–16s `nextAttemptAt` has always elapsed — five offline app-opens permanently
  fail the batch.

**What improved on latest (why it's borderline P0/P1 now):** the failure is no longer
invisible — `failedPermanentBatchCount > 0` surfaces a banner on the map screen
(`ios/RoadSenseNS/Features/Map/MapScreenRedesign.swift:501`) and a retry action in
Settings (`SettingsView.swift:239-241`, `:570`); `UploadQueueStore.retryFailedBatches()`
(`ios/RoadSenseNS/Persistence/UploadQueueStore.swift:154-172`) resets them, and
`ReadingStore.markAllReadingsForRequeue` (`ios/RoadSenseNS/Persistence/ReadingStore.swift:531-559`)
exists as a field-test recovery tool. Kept **P0** because rural-NS offline driving is the
core use case and data still goes permanent automatically with only manual recovery —
this contradicts `docs/implementation/01-ios-implementation.md:809` ("429/5xx do not
'poison' later drains").

**Fix sketch:** (a) check `NWPathMonitor.currentPath.status` before draining and skip
silently when unsatisfied (don't count an attempt); (b) capped exponential backoff that
never goes permanent for 5xx/network (e.g. 60s · 2^n capped at 6h, ±20% jitter),
reserving `failedPermanent` for 4xx; (c) auto-retry failed-permanent batches on next
foreground instead of requiring a button press.

---

### P1 — fix before public release

### P1-2. Thermal throttling rejects data but never stops the sensors — STILL-VALID
- `ios/Sources/RoadSenseNSBootstrap/Pipeline/QualityFilter.swift:57-59` rejects windows
  at `.serious`/`.critical`, but `SensorCoordinator` keeps 50Hz motion + GPS running —
  a hot dash-mounted phone burns max battery producing 100% rejected windows. Docs
  require "drop the window, **stop collection**"
  (`docs/implementation/01-ios-implementation.md:345`).
- `ios/RoadSenseNS/Sensors/ThermalMonitor.swift:9-13` is still a synchronous poll;
  thermal state is only sampled at window close (`SensorCoordinator.swift:344-347`).

**Fix sketch:** observe `ProcessInfo.thermalStateDidChangeNotification` in
`ThermalMonitor`; `SensorCoordinator` calls `stopCollection()` on `.serious`/`.critical`
and resumes on recovery.

### P1-3. Exact in-zone coordinates persisted locally indefinitely; checkpoint file survives "Delete local data" — STILL-VALID
- `ios/RoadSenseNS/Persistence/ReadingStore.swift:404-424` —
  `savePrivacyFilteredSample` still writes the **raw lat/lng of every in-zone GPS fix**
  (~one per 5m of travel) as a `ReadingRecord(droppedByPrivacyZone: true)`, retained
  indefinitely (no retention job — see P1-5).
- `ios/RoadSenseNS/Pipeline/SensorCoordinator.swift:324` assigns `latestLocation`
  **before** the zone check at `:327`, then force-persists a checkpoint at `:336` — so
  `SensorCheckpoint.json` (unprotected Application Support file,
  `ios/RoadSenseNS/Persistence/SensorCheckpointStore.swift:37-45`, no
  `.completeFileProtection`) contains exact in-zone coordinates.
- `AppModel.deleteLocalContributionData()` (`ios/RoadSenseNS/App/AppModel.swift:294-299`)
  deletes SwiftData rows but still **not** `SensorCheckpoint.json`.
- Partial mitigations on latest: per-drive privacy-filtered counts are surfaced
  (`DrivesListView.swift:145-149`) and per-drive delete removes those rows
  (`DrivesListView.swift:249` → `ReadingStore.deleteDriveSession:618-632`).

**Fix sketch:** store an aggregate count (or coarse geohash) instead of raw in-zone
fixes; clear/null `latestLocation` on zone-dropped samples before checkpointing; add
`checkpointStore.clear()` to `deleteLocalContributionData()`; set
`.completeFileProtection` on the checkpoint file.

### P1-4. Invalid GPS course becomes "heading 0° (north)" and corrupts windows — STILL-VALID
- `ios/RoadSenseNS/Sensors/LocationService.swift:108` —
  `let heading = location.course >= 0 ? location.course : 0` unchanged. `course == -1`
  (unknown heading at low speed / poor fix) becomes due-north:
  - poisons the speed-weighted mean heading and the variance gate
    (`ios/Sources/RoadSenseNSBootstrap/Pipeline/ReadingBuilder.swift:142-145`,
    `:250-274`): driving south, one invalid-course fix reads as a 180° swing → spurious
    window aborts (silent data loss);
  - uploads `heading: 0` to the server matcher for affected windows.

**Fix sketch:** carry the last valid course forward, or make heading optional and
exclude unknown-heading samples from mean/variance.

### P1-5. Retention/cleanup never runs; full-store scans now fire on every location sample — STILL-VALID, escalated
- Nightly cleanup is still a registered **no-op** that just logs
  (`ios/RoadSenseNS/App/BackgroundTaskRegistrar.swift:51-54`) and is never scheduled
  (no `BGTaskScheduler.submit` for `nightly-cleanup`; only the upload-drain
  `BGAppRefreshTaskRequest` is ever submitted, `:82-100`).
  `ios/Sources/RoadSenseNSBootstrap/Persistence/RetentionPolicy.swift` remains dead code.
- O(N) scans, now worse than on the stale branch:
  - `UploadQueueStore.persist` still fetches **every `ReadingRecord`**
    (`ios/RoadSenseNS/Persistence/UploadQueueStore.swift:227`);
  - `pendingReadingCount` / `statusSummary` fetch all un-uploaded readings and all
    batches, filtering in memory (`UploadQueueStore.swift:26-32`, `:126-152`);
  - **new:** `SensorCoordinator.stateDidChange` fires on *every location sample*
    (`SensorCoordinator.swift:309-310`) and is wired to
    `AppModel.refreshCollectionStats()` (`AppModel.swift:133-135`, `:483-514`), which
    performs ~8 store fetches (status summary, pending counts, overlay points, stats…)
    on the main actor — i.e. continuous full-store scans while driving, growing with DB
    size forever (compounded by P1-3's per-fix in-zone rows).

**Fix sketch:** schedule a `BGProcessingTaskRequest` for nightly-cleanup; in its handler
apply `RetentionPolicy` (30-day prune of uploaded readings, terminal batches,
privacy-filtered rows); replace all-rows fetches with predicate/count fetches; debounce
`stateDidChange` → stats refresh (e.g. 1/s max, or only on collection state transitions).

### P1-6. Drives under 100 pending readings may not upload for a long time — STILL-VALID
- `ios/RoadSenseNS/App/AppModel.swift:242-252` — on backgrounding, a BG drain is only
  scheduled when `pendingUploadCount >= 100` (~5km of driving). Shorter drives rely on
  (a) the post-drive +15 min BG refresh scheduled by `stopCollection`
  (`SensorCoordinator.swift:290` → `AppContainer.swift:81-86`), which iOS may defer for
  hours/days, or (b) the next manual foreground. Consider scheduling whenever
  `pendingUploadCount > 0` and documenting expected latency in the field-test pack.

### P1-7. `ReadingBuilder` motion buffer unbounded during GPS outages — STILL-VALID on latest (port the existing fix)
- `ios/Sources/RoadSenseNSBootstrap/Pipeline/ReadingBuilder.swift:119-121` —
  `addMotionSample` is an uncapped append. If GPS fixes stop (tunnel, CoreLocation
  stall, revoked permission) while motion runs at 50Hz, the buffer grows without bound
  and the **entire buffer is JSON-encoded into `SensorCheckpoint.json` every 60s**
  (`ReadingBuilder.swift:174-184`, `SensorCoordinator.swift:445-466`).
- A cap fix (2,000-sample bound + trim-on-restore, with 2 tests) exists as
  **uncommitted changes** in the primary checkout — written against the stale branch.
  See "Uncommitted fix disposition" below: **port it** to the latest branch.

---

### P2 — later

### P2-1. Pre-window motion accumulation can pollute the first window after GPS acquisition
`ReadingBuilder.addLocationSample`'s `isEmpty` branch still keeps previously accumulated
motion samples (`ios/Sources/RoadSenseNSBootstrap/Pipeline/ReadingBuilder.swift:129-132`).
After a no-GPS stretch, off-window accel is attributed to the first 40m window. Porting
the P1-7 cap bounds the damage; full fix is timestamp-trimming motion to the window span
(requires unifying clock bases — P2-2).

### P2-2. Mixed clock bases between motion and location samples
`MotionSample.timestamp` is boot-relative (`ios/RoadSenseNS/Sensors/MotionService.swift:55`);
`LocationSample.timestamp` is Unix epoch (`LocationService.swift:110`). Currently
harmless but a footgun for P2-1-style fixes and confusing in checkpoints that survive a
reboot.

### P2-3 (residual of old P0-3). `stopCollection()` never clears/rewrites the checkpoint
The original "next drive silently lost" bug is fixed: restore sets `isCollecting = false`
and resumes via a real `startCollection()`
(`ios/RoadSenseNS/Pipeline/SensorCoordinator.swift:430-431`, `:179-184`). But
`stopCollection()` → `stopServicesAndReset()` (`:281-306`) still leaves the on-disk
checkpoint saying `wasCollecting: true` (cleared only in `stopMonitoring()`, `:204`), so
any app relaunch within 30 minutes of a drive (`checkpointStore.load(maxAge: 30*60)`,
`:420`) spuriously restarts sensors for ~1–2 minutes (until the driving detector's 60s
grace stops them) and restores stale end-of-drive builder samples. Write a
`wasCollecting: false` checkpoint (or clear) in `stopCollection()`.

### P2-4 (residual of old P1-1). Driving detection: no confidence gating; >60s stops still discard the window
Largely mitigated on latest: a 60-second stop-grace period debounces red lights
(`SensorCoordinator.swift:80`, `scheduleStopCollectionIfNeeded` `:520-543`, cancelled on
resume `:170-171`), and a GPS-speed bootstrap (≥45 km/h, ≤50m accuracy, `:31-32`,
`:312-318`) covers slow/absent CMMotionActivity. Remaining: `DrivingDetector.swift:32`
still ignores `activity.confidence` (low-confidence flaps start collection); stops longer
than 60s (long lights, drive-thrus) still tear down and discard the in-progress window;
the tested `DrivingHeuristic` (15 km/h sustained) remains dead code — devices without
activity data only collect at ≥45 km/h. Consider confidence ≥ `.medium` to start, a
90–120s grace, and wiring `DrivingHeuristic` as the no-activity fallback.

### P2-5. 200-with-unparseable-body is treated as a network error
`UploadResponseParser.parse` throws on a 200 response whose body fails to decode
(`ios/Sources/RoadSenseNSBootstrap/Network/UploadResponseParser.swift:17-20`); the
`Uploader` catch-all counts it as `networkError` (`Uploader.swift:104-116` via
`APIClient.swift:106`) → with P0-6, five malformed-but-accepted responses permanently
fail a batch the server already has. Map 2xx decode failures to a distinct disposition.

### P2-6. 50Hz pipeline + checkpoint encoding run on the main actor
`SensorCoordinator` is `@MainActor` (`SensorCoordinator.swift:28`); every motion sample
hops to the main thread and the 60s checkpoint JSON-encode runs synchronously
(`:445-466`). Compounded by the per-sample stats refresh (P1-5). Move the pipeline to a
dedicated actor and encode checkpoints off-main.

### P2-7. Readings already queued are not re-filtered when a privacy zone is added later
Zones only gate at collection time (`SensorCoordinator.swift:327`);
`AppModel.refreshPrivacyZones()` (`AppModel.swift:176-183`) only refreshes the live
filter. On zone create, delete (or mark `droppedByPrivacyZone`) pending readings inside
the new zone.

### P2-8. Misc
- ~~`requestAlwaysAuthorization` one-shot dead-end~~ — **fixed on latest**:
  `requestAlwaysLocationUpgrade` polls then deep-links to Settings
  (`AppModel.swift:272-292`).
- BGTask `expirationHandler` still assigned after the drain task starts
  (`BackgroundTaskRegistrar.swift:62-75`) — tiny race; assign before kicking off work.
- Privacy zone radius defaults still diverge from docs: docs say 500m default
  (`docs/product-spec.md:766`); app uses 250m floor / 300m default
  (`PrivacyZoneStore.swift:38`, `PrivacyZonesView.swift:13`). Align docs or code.
- `BackgroundCollectionPolicy` (Bootstrap) is dead code whose behavior is hardcoded in
  `LocationService` — delete or wire it to prevent future review confusion.
- Batch idempotency remains sound (stable batch ID across retries, 5-min in-flight
  timeout `UploadQueueCore.swift:121-126`, `duplicate: true` handled
  `Uploader.swift:119-131`), now reinforced by server-side cross-batch dedupe noted at
  `ReadingStore.swift:514-529`.

---

## Uncommitted fix disposition (ReadingBuilder motion cap)

The stale-branch review applied one fix as uncommitted changes in the primary checkout
(`ios/Sources/RoadSenseNSBootstrap/Pipeline/ReadingBuilder.swift` +
`ios/Tests/RoadSenseNSBootstrapTests/ReadingBuilderTests.swift`): a
`maxBufferedMotionSamples = 2_000` cap, trimmed on append and on checkpoint-snapshot
restore, plus 2 tests.

**Recommendation: PORT.** The latest branch still has the unbounded buffer
(`ReadingBuilder.swift:119-121` on `34402f2`) and the same 60s checkpoint-encode
amplification. The patch will **not** apply cleanly via `git apply` (latest
`ReadingBuilder` gained a `roughnessScorer` property in the patch's context lines), but
the port is mechanical: copy the cap property, the `trimMotionSamplesIfNeeded()` helper,
its two call sites, and both tests onto `codex/testflight-signing-secrets`. Do not land
the stale-branch working-tree diff as-is.

---

## Verification

- Re-validated against `codex/testflight-signing-secrets` @ `34402f2` (2026-05-29) in a
  read-only worktree.
- `swift test` (RoadSenseNSBootstrap package, macOS host, run with
  `--scratch-path /tmp/rs-swift-scratch` so nothing was written into the read-only
  worktree): **107/107 tests pass in 29 suites** — up from 79/24 on the stale branch,
  including the suites covering the since-landed fixes
  (`DriveEndpointTrimmerTests`, `BackgroundCollectionPolicyTests`,
  `DrivingHeuristicTests`, `RetentionPolicyTests`, `SensorCheckpointTests`).
- App-target tests (`xcodebuild test`) were **not** re-run for this correction pass.

## Original review (2026-06-11, stale branch) — superseded

The original review text ran against `codex/testflight-build` and is superseded by the
verdict table and active findings above. Its P0-1 and P0-5 were artifacts of the stale
checkout and were never true of any TestFlight build.
