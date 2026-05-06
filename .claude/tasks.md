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

## Done

- [x] Created project task source of truth.
- [x] Path C migration shipped to staging: Railway PostGIS + Deno service + Vercel web. See `docs/implementation/13-railway-deno-migration.md`. Commits `5887962`, `e32eacb`.
- [x] First two stress-test passes (P14 + P15) — fixed silent partition-rollover outage, /health DoS surface, tile-zoom 500, SSL hostname spoof, pgRpc SQL-injection footgun. Process documented in `docs/implementation/14-stress-test-runbook.md`.
