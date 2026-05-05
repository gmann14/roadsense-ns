# 14 — Stress-test Runbook

*Last updated: 2026-04-28*

A reusable process for stress-testing the production pipeline (Railway PostGIS + Deno service + Vercel web). Run before every TestFlight cycle, after any migration, and after any change to ingestion / scheduler / connection-pool config.

## When to run

- Before a TestFlight build that opens to new external testers
- After any new SQL migration is shipped to staging
- After changes to `supabase/functions/_shared/scheduler.ts`, `db.ts`, or `pgRpc.ts`
- After any change that adds or modifies an Edge Function handler
- After a Railway-side platform change (postgres version bump, network changes)
- Quarterly as a baseline sweep even if no code changed

## Process

The stress test is run by spawning a fresh agent with the prompt below. The prompt is intentionally self-contained — it reads cold without conversation context, so a future engineer (or agent) can re-run it in isolation.

The agent's deliverable is a severity-sorted findings report. After the agent finishes:

1. File each CRITICAL and HIGH finding as a task under "Active" in `.claude/tasks.md` with a short reproduction note.
2. Apply fixes in a `P{N+1} — stress-test fixes` commit, mirroring the pattern of `e32eacb`.
3. Re-run the agent against the fixed branch to confirm the findings are gone.
4. Update the `Last updated` date at the top of this doc.

The first two passes (P14 / P15 in the migration history) found:
- A silent partition-rollover outage that would have triggered at the next month boundary (`create_next_readings_partition` couldn't write to `pg_catalog`)
- A 500 on `/tiles/coverage/99/0/0.mvt` that would have shown up in Sentry the moment a misconfigured client probed it
- An unauthenticated DoS surface against `PG_POOL_MAX=10` via the old `/health` DB roundtrip
- A substring SSL-disable check that `evil.railway.internal.attacker.com` would have bypassed
- Stub `cron.unschedule` accumulating duplicate rows on every `migrate-railway.sh` re-run

The expected output for each pass is a similar mix of silent-outage prevention plus tightening of edges that haven't yet been pressure-tested under real production load.

## Hard scope

- **Staging only.** Don't touch production user data.
- **Don't redeploy** the api service unless applying a fix you've validated.
- **Stop on CRITICAL.** If a finding could cause an outage, surface it before continuing the pass.
- **Cap wall time at 90 minutes.** Leave a punch list if not done.

## The agent prompt

Paste this into a fresh agent (the `general-purpose` agent or any review-flavoured subagent works). Update the "Live endpoints (staging)" block with current URLs/credentials before each run.

```text
You're doing a stress-test pass on the RoadSense NS backend after a migration
from Supabase to a self-hosted stack: Railway PostGIS + a single Deno service +
Vercel for the web app. Background reading:
- docs/implementation/13-railway-deno-migration.md (architecture)
- docs/implementation/05-deployment-and-observability.md (runbook)
- docs/implementation/14-stress-test-runbook.md (this process)

Live endpoints (staging):
- API: https://api-production-075e9.up.railway.app/functions/v1
- Web: https://roadsense-web.vercel.app
- DB proxy: see .railway-secrets.local (gitignored) for PUBLIC_API_KEY,
  TOKEN_PEPPER, and the proxy DATABASE_URL. The Deno service connects to
  postgis.railway.internal on Railway's private network.

What's already been hardened (don't redo):
- Tile zoom validation (z 0-22, x/y in 2^z grid)
- db.ts SSL hostname check is anchored, not substring
- _shared/pgRpc.ts has an identifier guard before SQL interpolation
- /health is process-only liveness; /health/deep is apikey-gated DB check
- In-process scheduler (_shared/scheduler.ts) fires all 7 jobs pg_cron
  stubs out: stats MV refresh (5 min), worst-segments MV (15 min),
  partition rollover (24h), nightly recompute, pothole expiry, rate-limit
  GC, drop old partitions
- Migration 20260428170000_qualify_partition_function.sql schema-qualifies
  CREATE TABLE in the partition function
- Stub cron.unschedule actually DELETEs from the stub table

Focus on gaps that haven't been covered:

1. Migration replay safety. Drop all the Railway DB tables (or spin up a
   fresh Railway PostGIS) and run scripts/migrate-railway.sh from scratch
   end-to-end. Then run it AGAIN against the same DB. Then a third time.
   Look for non-idempotent steps, stub cron.job row accumulation, function
   redefinitions with diverging signatures, sequence/identity drift,
   foreign key cycles that fail in a specific order.

2. The full ingest path under load. Send realistic upload-readings
   batches (10-100 readings, real Halifax-area coords) through the live
   API. Verify readings land in the current month partition,
   segment_aggregates updates incrementally, the 5-min MV refresh picks
   up new data, the rate limiter trips at the right threshold and
   recovers, tokenHashHex round-trips correctly through decode(hex)::bytea,
   replay protection (duplicate batch_id) returns the original response.

3. Connection pool behaviour. PG_POOL_MAX=10, PG_POOL_IDLE_SECONDS=30.
   Probe 50 concurrent /stats requests (any failures? p99?), a slow query
   on one connection (do other endpoints starve?), an idle connection
   reaped after 30s, what happens when DATABASE_URL drops mid-request.

4. The scheduler's failure modes (in-process setInterval). Two replicas
   running concurrently — REFRESH MATERIALIZED VIEW CONCURRENTLY dogpile?
   What if a job throws — does the next interval still fire? DB
   temporarily unreachable — does the scheduler self-recover? Process
   restart — do jobs run too soon (jitter is 0-30s)? Memory leak from
   accumulated handles?

5. Path C migration vs. Supabase parity. Find any RPC where numeric
   coercion changed (Postgres returns numerics as strings; we Number(...)
   cast — overflow at >2^53?), bytea handling differs (decode(hex)::bytea
   vs Buffer), JSONB serialisation differs, NULL vs undefined parameter
   handling diverges from supabase-js's .rpc().

6. Web -> API integration. Cold-start latency from Vercel edge to
   Railway, cache header behaviour (s-maxage=3600 on tiles), CORS
   preflight from roadsense-web.vercel.app, what happens on the web when
   API returns 503, the map renders with 1.74M road segments — does any
   tile request OOM the DB?

7. iOS Staging build. Compiles with the new enablePotholePhotos flag,
   passes AppModelTests with the new .featureDisabled enum case, all 19
   files that grep for PotholePhoto* still type-check.

8. Secret rotation. Rotate PUBLIC_API_KEY and TOKEN_PEPPER in Railway.
   Verify in-flight uploads fail cleanly, iOS app retries don't loop
   forever, TOKEN_PEPPER rotation breaks contributor linkage but doesn't
   corrupt anything, rolling restart picks up new env without dropping
   requests.

9. Disaster recovery (document, don't actually do). How would we restore
   from a Railway DB backup? What's the point-in-time recovery story? If
   the api service dies, what's the rollback procedure? What's the cost
   ceiling if a tester sends 1M readings overnight?

Tools available:
- psql against the Railway proxy URL
- curl against the live API (apikey from .railway-secrets.local)
- Railway CLI for logs/redeploys (railway link first)
- Test suites: deno test (132 tests), npm test in apps/web (61),
  swift test for iOS bootstrap
- scripts/api-smoke.sh for the canonical end-to-end smoke

Reporting format:
For each finding, output: severity (CRITICAL/HIGH/MEDIUM/LOW), file:line if
applicable, the failure mode in one sentence, the reproduction steps, and a
concrete fix. Sort by severity. Include a "What I tried that didn't break
anything" section so future passes don't repeat work.

Hard scope:
- Staging only. Don't touch production user data.
- Don't redeploy the api service unless applying a validated fix.
- If you find a CRITICAL outage risk, stop and surface it before continuing.
- Cap total wall time at 90 minutes. Leave a punch list if not done.
```

## After the pass

- Commit findings as `P{N+1} — stress-test fixes: <one-line scope>`
- Update `tasks.md` (move completed sweeps to Done, add follow-ups to Active)
- If CRITICAL fixes shipped, regenerate the staging smoke once and link the run in the commit body
- Re-run `scripts/api-smoke.sh` against staging as a final gate before TestFlight upload
