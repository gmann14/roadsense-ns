# Review — Pothole Photo Reporting Workflow

**Commit:** `6e21a47` — *feat: complete pothole photo reporting workflow*
**Branch:** `gmann14/design-audit`
**Reviewer:** Claude (Opus 4.7), 2026-04-23
**Scope:** Combined code + design/UX review of the end-to-end pothole photo feature (iOS capture → backend prepare → storage PUT → cron promote → moderation → approve/reject).

---

## Findings (by severity)

### High

#### H1. Camera `fullScreenCover` conflicts with active segment `.sheet`
- **Where:** `ios/RoadSenseNS/Features/Map/MapScreen.swift` (segment sheet + `isShowingCamera` cover on the same root).
- **Problem:** "Add photo" in SegmentDetailSheet flips `isShowingCamera = true` on the parent, but the parent's `.fullScreenCover(isPresented: $isShowingCamera)` is attached to a view already covered by the sheet. SwiftUI cannot reliably present a fullScreenCover from behind a sheet — camera may fail to appear or race sheet dismissal.
- **Fix:** Dismiss the sheet first (set `selectedSegment = nil`), then present the camera on the next run loop; OR attach the `fullScreenCover` inside the sheet content.

#### H2. Image processing runs on MainActor
- **Where:** `PotholePhotoProcessor.prepareCapturedPhoto` called from `AppModel.submitPotholePhoto` on `@MainActor`.
- **Problem:** JPEG re-encode (1600 px, quality 0.8) + SHA256 + atomic file write blocks the main thread 100–400 ms on older devices, precisely when the "Uploading…" banner should animate in.
- **Fix:** `Task.detached(priority: .userInitiated)` or a dedicated background actor.

#### H3. Follow-up prompt banner hidden behind segment sheet
- **Where:** `MapScreen.swift` overlays the follow-up banner at the map level; the prompt is enqueued inside `loadSegment` while the sheet is open.
- **Problem:** User never sees the banner until after they dismiss the sheet — by that point the action is stale.
- **Fix:** Surface the prompt inside SegmentDetailSheet, or defer firing until `onDismiss`.

#### H4. Photo file deleted before SwiftData save
- **Where:** `PotholePhotoStore.applyUploadSuccess`.
- **Problem:** File removed from AppSupport *before* `context.save()`. If save throws, record stays `pending_metadata` but the JPEG is gone — next drain reads a missing file and fails permanently.
- **Fix:** Save first, then delete. Log (don't throw on) delete failure.

#### H5. `discard(id:)` races with in-flight upload
- **Where:** `PotholeActionStore.discard(id:)` deletes unconditionally.
- **Problem:** After undo-window promotion, Uploader may be mid-flight. Concurrent `discard` deletes the row; subsequent `applyUploadSuccess` lookup no-ops silently.
- **Fix:** Guard on `state == .pendingUndo`; otherwise mark `.discarded` and let the drain skip.

#### H6. Camera authorization not re-checked after Settings return
- **Where:** `PotholeCameraFlowView.swift`.
- **Problem:** Denied state instructs user to open Settings, but the view never re-queries `AVCaptureDevice.authorizationStatus` when the scene returns to `.active`.
- **Fix:** Observe `@Environment(\.scenePhase)` and re-check on `.active`.

#### H7. `Content-SHA256` header is not verified by Supabase Storage
- **Where:** `APIClient.uploadPotholePhotoFile` sets `Content-SHA256`; docs imply server verification.
- **Problem:** Supabase Storage ignores the header. There is no server-side guarantee that bytes at rest match the hash declared in `prepareUpload`.
- **Fix:** Either (a) read bytes in the promote Edge Function, recompute SHA256, compare against `pothole_photos.content_sha256`, reject on mismatch; or (b) correct the docs to drop the integrity claim.

---

### Medium

#### M1. Client never passes `segment_id` to `pothole-photos` prepare
- **Where:** iOS `APIClient.beginPotholePhotoUpload` → Edge Function `pothole-photos/index.ts` insert.
- **Problem:** Column and FK exist; inserts leave it NULL. Moderation queue cannot scope by segment; approve path re-derives from `geom` only.
- **Fix:** Accept and persist `segment_id` — iOS already has `scopedPhotoSegmentID`.

#### M2. "Add photo" visibility gate is inverted
- **Where:** `SegmentDetailSheet.swift` renders the button only when `segment.potholes` is non-empty.
- **Problem:** User on a rough-but-unlisted segment cannot attach a photo of a new pothole.
- **Fix:** Always show the button (subject to the stopped-location gate); or hoist CTA to MapScreen.

#### M3. Still-there / Looks-fixed buttons shown for resolved potholes
- **Where:** `SegmentDetailSheet.swift` pothole row UI.
- **Problem:** No `status != "resolved"` guard, though follow-up candidate filter does check this.
- **Fix:** Hide or disable both buttons when `pothole.status == "resolved"`.

#### M4. Deprecated `isHighResolutionCaptureEnabled`
- **Where:** `PotholeCameraFlowView.swift`.
- **Fix:** Migrate to `maxPhotoDimensions` (iOS 16+).

#### M5. No Nova-Scotia bounds check on photo submission
- **Where:** `AppModel.submitPotholePhoto`.
- **Problem:** Privacy zones are checked; NS bounds (enforced for readings) are not.
- **Fix:** Reuse existing NS bounds check before queuing a photo.

#### M6. No UI surface for `failed_permanent` photo reports
- **Where:** `PotholePhotoStore` stores the state; nothing in Settings exposes it.
- **Problem:** Silent failures; user has no way to see, retry, or dismiss.
- **Fix:** Add a "My reports" row with per-report status + retry/delete.

#### M7. Storage + DB not transactional on approve
- **Where:** `pothole-photo-moderation/index.ts`.
- **Problem:** `moveObject(pending → published)` then RPC. If RPC fails, object is in `published/` with no approved row — no compensation.
- **Fix:** `try/catch` the RPC and move-back on failure; or reorder (RPC first, move second) with a background reconcile.

#### M8. Moderation queue view lacks `security_invoker`
- **Where:** `20260423162500_pothole_photo_moderation.sql`.
- **Problem:** Service-role grant works today, but view runs as owner; any future leak to `authenticated` bypasses RLS.
- **Fix:** `CREATE VIEW … WITH (security_invoker = true)`.

---

### Low

#### L1. `retryAfter` `Int` branch unreachable
- **Where:** `APIClient.swift`. `allHeaderFields` always yields `String`. Dead code.

#### L2. Hardcoded `.bottom, 156` padding on banners
- **Where:** `MapScreen.swift`. Will collide with dynamic bottom safe-area on smaller devices.

#### L3. Whole-file PUT via `Data(contentsOf:)`
- **Where:** `APIClient.uploadPotholePhotoFile`. Fine at 1.5 MB cap but a pattern trap.

#### L4. `pendingCount` only counts `pending_metadata`
- **Where:** `PotholePhotoStore`. Misleads UI when photos are waiting on cron promotion.

#### L5. Undo banner says 5s — aggressive for drivers
- Consider 8–10s.

#### L6. Docs softened EXIF stripping to "source-camera metadata"
- The `CGImageDestination` path *does* strip EXIF in practice. Either re-assert with a unit test or keep the softer phrasing consistently.

---

### Migration / reset correctness

- `pothole_photo_status` enum creation is guarded — fresh-reset safe. ✓
- `pg_cron` assumed installed from `20260418165013_nightly_recompute_and_cron.sql`. ✓
- `storage.buckets` upsert OK. ✓
- Unschedule-before-schedule cron pattern OK. ✓
- `promote_uploaded_pothole_photos()` has `SET search_path`. ✓
- `pothole_reports.has_photo` default backfill cheap. ✓

---

## Open questions / assumptions

- `pg_cron` extension live in the target Supabase project (migration does not `CREATE EXTENSION`).
- `pothole_reports.geom` exists and is indexed (used by `approve_pothole_photo` nearby lookup).
- `pothole-photo-moderation` is internal-only — `verify_jwt = false` plus `isAuthorizedInternalRequest` is safe *only* if the endpoint is never exposed to a browser.
- Intended TTL of the 60-second signed read URL on `pothole-photo-image`; any rate-limiting on moderator preview fetches?
- Offline photo UX — is there a visible "queued" state beyond the transient banner?

---

## Design / product UX review

- **Single-button mark is good.** Stopped-only photo gate is the right call; copy should explain *why* ("For safety we only accept photos when stopped") rather than just *what*.
- **Segment detail is doing too much.** Sparkline + trust card + pothole list + still-there/fixed + add-photo is a lot for a glance-while-stopped surface. Collapse sparkline behind a "Details" disclosure.
- **Follow-up prompt timing is risky.** Beyond Finding H3, the candidate filter (≤35 m + fresh-stopped-location) fires mostly in parking lots. Consider firing on *next* drive start near the segment.
- **Photo CTA discoverability is poor.** Gating on `!segment.potholes.isEmpty` (M2) makes new-pothole-with-photo unreachable from segment flow. Add a top-level map CTA when stopped.
- **Moderation has no user-visible audit trail.** Approved/rejected never reaches the reporting device. Even a silent "Thanks — your photo was approved" push closes the loop.
- **Privacy posture is strong:** on-device privacy zones, EXIF strip on re-encode, no `segment_id` leak today (arguably a bug — see M1), private bucket. Weakest seam: false implication of server-side hash verification (H7).
- **Copy nit:** "Looks fixed" is ambiguous right after hitting one. Prefer "This is gone now" / "Still here."

---

## Readiness summary

**Not ready to ship as-is.** H1–H6 are user-visible or data-integrity bugs in the core photo flow. H7 is a docs-vs-reality gap worth closing before the first external audit. Backend is in better shape; migrations are clean, RPCs well-scoped, pgTAP tests present — but the non-transactional approve path (M7) and missing `segment_id` wiring (M1) should land before moderation goes live.

**Recommend a follow-up commit addressing H1–H6 + M1 + doc correction for H7 before merging to `main`.**

---

## Red/Green TDD fix plan

For each finding: (1) a **red** failing test that asserts the desired behavior, (2) the **green** minimal change to make it pass. Use this order — land tests first in one commit, then the fix, so the regression is locked.

### H1 — Camera cover vs sheet

- **Red — iOS UI test** (`ios/RoadSenseNSUITests/PhotoFlowUITests.swift`):
  - Given a segment sheet is open, tap "Add photo".
  - Assert `cameraScreen` identifier becomes hittable within 2 s.
  - This fails today because the fullScreenCover is behind the sheet.
- **Green:** In `SegmentDetailSheet` "Add photo" action, call `onRequestPhoto` which on MapScreen does `selectedSegment = nil` then schedules `DispatchQueue.main.async { isShowingCamera = true }`. Add a snapshot test that the cover's body renders non-nil for a known context.

### H2 — Main-thread image processing

- **Red — unit test** (`PotholePhotoProcessorTests.swift`):
  - Assert `prepareCapturedPhoto` is annotated/runs off-main: use a wrapper `processor.prepare(...)` that returns a `Task`; in the test, `XCTAssertFalse(Thread.isMainThread)` is captured inside the closure via an injected probe.
- **Green:** Make `prepareCapturedPhoto` `nonisolated` and move call site to `Task.detached(priority: .userInitiated)`; propagate result back on MainActor.

### H3 — Follow-up prompt hidden behind sheet

- **Red — AppModel test**:
  - Arrange a segment with a pothole in range; simulate `loadSegment` while `isSegmentSheetPresented == true`.
  - Assert `followUpPrompt` is *not* surfaced until `onSheetDismiss()` fires.
- **Green:** AppModel stores `pendingFollowUp`; surfaces only when `segmentSheetDismissed()` is called. Wire `.onDisappear` / `sheet(onDismiss:)` in MapScreen.

### H4 — File deleted before save

- **Red — `PotholePhotoStoreTests`**:
  - Inject a `FailingModelContext` where `save()` throws.
  - Call `applyUploadSuccess`.
  - Assert file at `photoFilePath` *still exists* (or record is unchanged + file intact).
- **Green:** Reorder `applyUploadSuccess`: mutate record → `try context.save()` → best-effort `try? fileManager.removeItem`. If save throws, do not delete.

### H5 — discard/upload race

- **Red — `PotholeActionStoreTests`**:
  - Create a record in `.pendingUpload` (past undo window).
  - Call `discard(id:)`.
  - Assert the record is still present and `state == .pendingUpload` (or `.discarded` if chosen) — not deleted.
- **Green:** `discard(id:)` guards `guard record.state == .pendingUndo else { return }`. Optionally add `.discarded` state + skip path in Uploader.

### H6 — Camera auth re-check

- **Red — UI test**:
  - Stub `AVCaptureDevice.authorizationStatus` via a dependency (wrap it in a `CameraAuthorizing` protocol).
  - Start flow in `.denied`; observe `scenePhase` active transition; flip stub to `.authorized`.
  - Assert view transitions from denied state to live preview.
- **Green:** Inject `CameraAuthorizing` into `PotholeCameraFlowView`. `onChange(of: scenePhase)` → re-query status, update `@State authStatus`.

### H7 — Server-side SHA verification

- **Red — Deno test** (`supabase/functions/pothole-photos/promote_test.ts` or a new `verify_test.ts`):
  - Insert a `pothole_photos` row with `content_sha256 = X`.
  - Upload storage object with bytes whose hash ≠ X.
  - Invoke the promote function (or a new `verify_pothole_photo_hash` helper).
  - Assert status moved to `rejected` with reason `content_sha_mismatch`, object removed.
- **Green (option A):** Extend `promote_uploaded_pothole_photos` or add an Edge Function that streams object bytes, computes SHA256, and updates status accordingly.
- **Green (option B):** Correct `docs/implementation/03-api-contracts.md` to state integrity is advisory; remove the header send from iOS.

### M1 — Missing `segment_id`

- **Red — Deno handler test** (`pothole-photos/handler_test.ts`):
  - POST prepare with `segment_id: "<uuid>"`.
  - Assert inserted row has `segment_id = "<uuid>"`.
- **Green:** Accept `segment_id` in request schema, pass through to insert. iOS `beginPotholePhotoUpload` already has the value.

### M2 — Inverted "Add photo" gate

- **Red — SegmentDetailSheet snapshot test:**
  - Render with `segment.potholes == []`.
  - Assert "Add photo" button is hittable.
- **Green:** Remove the `!potholes.isEmpty` guard.

### M3 — Buttons shown for resolved potholes

- **Red — snapshot test:** Row with `status == "resolved"` hides still-there/looks-fixed buttons.
- **Green:** Wrap buttons in `if pothole.status != "resolved"`.

### M4 — Deprecated API

- **Red — compilation warning promoted to error** in CI (`-warnings-as-errors` for the affected file).
- **Green:** Switch to `maxPhotoDimensions`.

### M5 — NS bounds check for photos

- **Red — AppModelTests:**
  - Submit photo at a coord outside NS → assert photo record is not queued and user sees a rejection reason.
- **Green:** Reuse existing `NovaScotiaBounds.contains(_:)` before queuing.

### M6 — Failed photo UI

- **Red — Settings snapshot test:** When a `failed_permanent` record exists, a row with retry/delete controls renders.
- **Green:** Add "My reports" section; bind to `PotholePhotoStore.failedReports`.

### M7 — Non-transactional approve

- **Red — Deno test:**
  - Stub RPC to throw after successful move.
  - Call approve.
  - Assert object is moved back to `pending/` (or original path).
- **Green:** `try { await moveObject(...); try { await rpc(...) } catch { await moveObject(toPath, fromPath); throw } }`.

### M8 — `security_invoker` on moderation view

- **Red — pgTAP test:**
  - Create a non-service-role test user; `SET ROLE` to them; `SELECT FROM moderation_pothole_photo_queue`; expect zero rows (or permission denied).
- **Green:** Recreate view with `WITH (security_invoker = true)`.
