# RoadSense NS Tasks

Source of truth for RoadSense NS project work. Keep this public-safe: no secrets, credentials, private tester details, or unpublished personal context.

## Worktree Coordination

- Source of truth: this task file on the repo's `main` branch.
- In worktrees, update this file in the worktree you are using; do not edit another checkout's copy.
- Commit task updates with the code/docs change that changes task status.
- Pull or rebase from `origin/main` before long-running work and resolve task-file conflicts explicitly.
- For public repos, keep this file free of secrets, credentials, private customer details, and unpublished personal context.

## Active

- [ ] Reconcile the historical implementation backlog in `docs/implementation/08-implementation-backlog.md` with the current beta/live-web state.
- [ ] Keep deployment docs and workflows aligned with the current Railway Postgres/PostGIS + Cloudflare/OpenNext stack.
- [ ] Track beta/TestFlight issues here once external testers start reporting problems.
- [ ] Run the stress-test pass in `docs/implementation/14-stress-test-runbook.md` before each TestFlight cycle, after any new SQL migration, and after changes to scheduler / db.ts / pgRpc.ts. File CRITICAL/HIGH findings here as Active items.
- [ ] Promote the Deno service connection from the postgres superuser to a least-privilege app role with explicit GRANTs (carry-over from P15 review).
- [ ] Replace the hardcoded `as` casts in `supabase/functions/server.ts` handler/runtime alignment by converging on a single canonical RateLimitResult shape per handler (carry-over from P15 review).
- [ ] Follow-up public web performance pass: test a lighter Mapbox style and/or a non-interactive map preview while Mapbox hydrates, with mobile Lighthouse/WebPageTest checks before shipping.
- [ ] Replace the temporary pothole speed guard with trip-level drive classification: use overall session duration, speed distribution, sustained-speed windows, CoreMotion automotive confidence, and route context so low-speed car driving can still publish potholes while bike rides are filtered.
- [ ] Android real-device beta validation: run at least one Pixel-class and one Samsung-class drive, confirm upload acceptance on the public map, record foreground-service survivability, capture 30-minute battery drain, and exercise Settings → Delete local data + manual pothole + feedback flows before wider tester distribution.
- [ ] Android native Mapbox vector-tile + pothole overlay rendering — **code landed, provisioning blocked.** The Compose `MapHost` calls into a `MapboxBridge` whose Mapbox-typed implementation lives in `android/app/src/mapboxMain/kotlin/` and is compiled in automatically whenever `MAPBOX_DOWNLOADS_TOKEN` is exported at sync time (env var or `~/.gradle/gradle.properties`). The bridge registers the same `segment_aggregates` + `potholes` source-layers iOS uses, points at the configured `/tiles/{z}/{x}/{y}.mvt?apikey=…` endpoint, and re-applies the `RoadQualityStyle` ramp/opacity/width expressions ported line-for-line from `RoadQualityMapView.swift`. The no-Mapbox build keeps falling back to a WebView pointing at the public web map. Remaining: (1) provision `MAPBOX_DOWNLOADS_TOKEN` on the release machine + CI publisher runner, (2) put a real `MAPBOX_ACCESS_TOKEN` into each env's `*.env.secrets.properties`, (3) eyes-on a Pixel device that potholes + segments render at the expected zooms.
- [ ] Android Play Console + signing onboarding: register the developer account, create the upload keystore offline, populate `ANDROID_UPLOAD_KEYSTORE` + `ANDROID_UPLOAD_KEYSTORE_PASSWORD` + `ANDROID_UPLOAD_KEY_ALIAS` + `ANDROID_UPLOAD_KEY_PASSWORD` + `GOOGLE_PLAY_JSON_KEY` GitHub secrets, then run `.github/workflows/android-internal.yml` once with `ANDROID_PUBLISH_ENABLED=false` to confirm the AAB before flipping the publish flag.
- [ ] Android pothole photo capture (CameraX + photo upload). Pothole *action* flow + queue ships in beta; the photo upgrade is the iOS-parity follow-up once the action flow has produced field evidence.

## Done

- [x] Created project task source of truth.
- [x] Path C migration shipped to staging: Railway PostGIS + Deno service + Vercel web. See `docs/implementation/13-railway-deno-migration.md`. Commits `5887962`, `e32eacb`.
- [x] First two stress-test passes (P14 + P15) — fixed silent partition-rollover outage, /health DoS surface, tile-zoom 500, SSL hostname spoof, pgRpc SQL-injection footgun. Process documented in `docs/implementation/14-stress-test-runbook.md`.
- [x] Recovered Android implementation from archived worktree state and wired internal-beta collection/upload path, launcher control shell, JVM CI, fixture parity check, and Google Play readiness doc.
- [x] Replaced the launcher beta shell with a production Compose Material 3 Android shell — Map / Stats / Settings tabs, drive controls, manual pothole flow with 8s undo window, in-app feedback queue, status surface, Settings → Delete local data, privacy + permissions explainers, Material You dynamic colors.
- [x] Wire-format parity tests for `pothole-actions` and `feedback` endpoints — Android JSON matches the iOS `UploadAPIModels.swift` shape so the same Edge Functions accept both clients.
- [x] Persistent feedback queue + drainer mirroring iOS `FeedbackQueue` / `FeedbackQueueDrainer`: Room-backed entries survive process death and drain on the unified `UploadDrainWorker` heartbeat with per-result handling for accepted / validation-failed / rate-limited / server-error / network-error.
- [x] Pothole action repository + coordinator mirroring iOS `PotholeActionStore` / `PotholeActionUploader`: PENDING_UNDO state during the 8s undo window, automatic promotion to PENDING_UPLOAD, retry/backoff parity with the existing `UploadPolicy`.
- [x] Production permission ladder for Android 13/14+ via `PermissionState`: foreground bundle (fine location, activity recognition, notifications) requested first, background-location requested only after foreground is granted, API 30+ background routed to Settings (per Play Store policy).
- [x] Optional release signing wired purely from `ANDROID_UPLOAD_*` env vars — release builds fall back to the debug keystore when the env vars are absent so CI stays green; supplying the four vars on a release machine produces a Play-acceptable AAB without committing a keystore.
- [x] `.github/workflows/android-internal.yml` placeholder workflow that builds the production-flavor AAB and (when `ANDROID_PUBLISH_ENABLED=true`) pushes it to Google Play Internal Testing via the Play Developer API; staging release AAB now also runs in `android-ci.yml` to catch signing-config regressions early.
