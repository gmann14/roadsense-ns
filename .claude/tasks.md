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

## Done

- [x] Shipped the two SQL-only pre-launch trust gates from `docs/implementation/15-device-attestation-and-trust.md`: B166 exact unique-contributor dedupe (`segment_contributor_marks`, closes review P1-3) and B165 pothole corroboration gating (`candidate` status + `pothole_reporter_marks`, ≥2 distinct devices to publish, closes review P1-2; TestFlight-era actives grandfathered). Commits `fca1dc2`, `cc9bcbe`. Owner follow-up: deploy migrations + redeploy Railway service; pgTAP suites 017/018 not yet executed locally (Docker stack was down) — run `supabase test db` before deploy.
- [x] Fixed live-beta pothole-photo 404s (pre-launch review NEW-2): gateway now mounts the photo routes as `503 photos_disabled` pending the R2 bucket (`supabase/functions/_shared/photoUploads.ts`), iOS production disables photo capture with a "Photos coming soon" notice and honors the 503 Retry-After for already-queued photos. Commits `ed4890d`, `d4d0090`. Owner follow-up: provision R2 + set `R2_*` env vars + port the photo handlers (fix latent P1-7/P2-8 first) to enable for real.
- [x] Created project task source of truth.
- [x] Path C migration shipped to staging: Railway PostGIS + Deno service + Vercel web. See `docs/implementation/13-railway-deno-migration.md`. Commits `5887962`, `e32eacb`.
- [x] First two stress-test passes (P14 + P15) — fixed silent partition-rollover outage, /health DoS surface, tile-zoom 500, SSL hostname spoof, pgRpc SQL-injection footgun. Process documented in `docs/implementation/14-stress-test-runbook.md`.
