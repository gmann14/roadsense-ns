# 14 — Stress-test Runbook

*Last updated: 2026-11-08*

A reusable process for stress-testing the production pipeline (Railway PostGIS + Deno service behind the Cloudflare Worker + Cloudflare/OpenNext web). Run before every TestFlight cycle, after any migration, and after any change to ingestion / scheduler / connection-pool config.

## When to run

- Before a TestFlight build that opens to new external testers
- After any new SQL migration is merged
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

- **There is no staging environment.** The Railway project has only `production`, and the endpoints that older passes called "staging" are production. Anything that writes, replays migrations, load-tests or rotates secrets runs against a **local stack** (below). Production gets read-only probes and `scripts/api-smoke.sh` only.
- **Never drop tables or run `migrate-railway.sh` against the Railway database.**
- **Don't redeploy** the api service unless applying a fix you've validated.
- **Stop on CRITICAL.** If a finding could cause an outage, surface it before continuing the pass.
- **Cap wall time at 90 minutes.** Leave a punch list if not done.

## The agent prompt

Paste this into a fresh agent (the `general-purpose` agent or any review-flavoured subagent works). Update the endpoint block with current URLs before each run.

Local stack for the write-heavy parts (same image and Postgres major as production):

```bash
docker network create rs-net
docker run -d --name rs-db --network rs-net --network-alias postgis.railway.internal \
  --platform linux/amd64 -e POSTGRES_PASSWORD=testpw -p 55432:5432 postgis/postgis:16-3.7
DATABASE_URL=postgres://postgres:testpw@127.0.0.1:55432/postgres scripts/migrate-railway.sh
docker build -t roadsense-api-local .
docker run -d --name rs-api --network rs-net -p 18080:8000 \
  -e DATABASE_URL=postgres://postgres:testpw@postgis.railway.internal:5432/postgres \
  -e PUBLIC_API_KEY=local-key -e TOKEN_PEPPER=local-pepper-local-pepper \
  -e RAILWAY_ENVIRONMENT=local -e GIT_COMMIT_SHA="$(git rev-parse HEAD)" roadsense-api-local
# API: http://127.0.0.1:18080/functions/v1
```

Tear it down with `docker rm -f rs-api rs-db && docker network rm rs-net`.

```text
You're doing a stress-test pass on the RoadSense NS backend after a migration
from Supabase to a self-hosted stack: Railway PostGIS + a single Deno service
behind a Cloudflare Worker, and a Cloudflare/OpenNext web app. Background reading:
- docs/implementation/13-railway-deno-migration.md (architecture)
- docs/implementation/05-deployment-and-observability.md (runbook)
- docs/implementation/14-stress-test-runbook.md (this process)

Endpoints:
- Local stack (all writes, replays, load and rotation tests):
  API http://127.0.0.1:18080/functions/v1, DB postgres://postgres:testpw@127.0.0.1:55432/postgres
  (setup in docs/implementation/14-stress-test-runbook.md).
- Production (READ-ONLY probes and scripts/api-smoke.sh only; there is no staging):
  API https://api.nsroadsense.ca/functions/v1, web https://nsroadsense.ca.
  The Railway origin answers 403 except /health once REQUIRE_ORIGIN_AUTH=true.

What's already been hardened (don't redo):
- Tile zoom validation (z 0-22, x/y in 2^z grid)
- db.ts SSL hostname check is anchored, not substring
- _shared/pgRpc.ts has an identifier guard before SQL interpolation
- /health is process-only liveness; /health/deep is apikey-gated DB check
- In-process scheduler (_shared/scheduler.ts) runs the jobs pg_cron stubs
  out, with its own pool, per-job advisory locks and recorded runs that
  /health/deep reports (job list in doc 05, "Scheduled jobs on Railway")
- Migration 20260428170000_qualify_partition_function.sql schema-qualifies
  CREATE TABLE in the partition function
- Stub cron.unschedule actually DELETEs from the stub table

Focus on gaps that haven't been covered:

1. Migration replay safety, on the LOCAL database only. Run
   scripts/migrate-railway.sh on a fresh postgis/postgis:16-3.7, run it
   again (must apply nothing), then check `supabase db push --db-url ...
   --dry-run` reports the database up to date. Look for migrations that
   fail on plain PostGIS, function redefinitions with diverging
   signatures, sequence/identity drift, foreign key cycles.

2. The full ingest path under load. Send realistic upload-readings
   batches (10-100 readings, real Halifax-area coords) through the LOCAL
   API (import a road network first with scripts/osm-import.sh). Verify readings land in the current month partition,
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

6. Web -> API integration. Latency from the Cloudflare edge to
   Railway, cache header behaviour (s-maxage=3600 on tiles), CORS
   preflight from nsroadsense.ca, what happens on the web when
   API returns 503, the map renders with 1.74M road segments — does any
   tile request OOM the DB?

7. iOS Staging build. Compiles with the new enablePotholePhotos flag,
   passes AppModelTests with the new .featureDisabled enum case, all 19
   files that grep for PotholePhoto* still type-check.

8. Secret rotation, on the LOCAL stack. Rotate PUBLIC_API_KEY and TOKEN_PEPPER.
   Verify in-flight uploads fail cleanly, iOS app retries don't loop
   forever, TOKEN_PEPPER rotation breaks contributor linkage but doesn't
   corrupt anything, rolling restart picks up new env without dropping
   requests.

9. Disaster recovery (document, don't actually do). How would we restore
   from a Railway DB backup? What's the point-in-time recovery story? If
   the api service dies, what's the rollback procedure? What's the cost
   ceiling if a tester sends 1M readings overnight?

Tools available:
- psql against the local database (read-only queries against the Railway
  proxy URL from .railway-secrets.local are fine)
- curl against the local API, and read-only curl against production
- Railway CLI for reading logs only (`railway logs --service api`)
- Test suites: see README.md "Tests" (deno test, scripts/tests/run.sh,
  supabase test db, npm test in apps/web, swift test in ios,
  ./gradlew test in android)
- scripts/api-smoke.sh for the canonical end-to-end smoke

Reporting format:
For each finding, output: severity (CRITICAL/HIGH/MEDIUM/LOW), file:line if
applicable, the failure mode in one sentence, the reproduction steps, and a
concrete fix. Sort by severity. Include a "What I tried that didn't break
anything" section so future passes don't repeat work.

Hard scope:
- No writes to production. Writes, replays, load and rotation tests go to
  the local stack. Never drop tables or run migrate-railway.sh on Railway.
- Don't redeploy the api service; fixes ship through the normal deploy
  order in docs/implementation/05-deployment-and-observability.md.
- If you find a CRITICAL outage risk, stop and surface it before continuing.
- Cap total wall time at 90 minutes. Leave a punch list if not done.
```

## After the pass

- Commit findings as `P{N+1} — stress-test fixes: <one-line scope>`
- Update `tasks.md` (move completed sweeps to Done, add follow-ups to Active)
- If CRITICAL fixes shipped, run `scripts/seeded-e2e-smoke.sh` against the local stack and link the output in the commit body
- After the fixes are deployed, run `scripts/api-smoke.sh` against `https://api.nsroadsense.ca/functions/v1` as a final gate before TestFlight upload
