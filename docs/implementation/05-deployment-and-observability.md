# 05 — Deployment & Observability

*Last updated: 2026-04-28*

Covers: environments, CI/CD, secrets, logging, metrics, alerting, and the "what to do when something breaks at 11pm" playbook.

## Environments

| Env | Purpose | Backend host | iOS scheme | Maps key |
|---|---|---|---|---|
| `local` | Local dev (`supabase start`) | local Supabase | `RoadSenseNS-Local` | personal dev key |
| `staging` | TestFlight + Vercel preview | Railway PostGIS + Deno | `RoadSenseNS-Staging` | staging key |
| `production` | Real users (App Store) | Railway PostGIS + Deno (separate project) | `RoadSenseNS` | production key |

Staging and production are physically separate Railway projects so the blast radius of a bad migration is contained. Local development still uses local Supabase via the CLI.

### Staging endpoints (current)

- API: `https://api-production-075e9.up.railway.app/functions/v1`
- Web: `https://roadsense-web.vercel.app`
- DB (admin): Railway proxy URL — see `.railway-secrets.local` (gitignored) for current values.

## Railway runbook

### Provision a new environment

```bash
# 1) Create the project + DB (PostGIS template)
railway link  # or: railway init <project-name>
railway add --database postgres  # then add the PostGIS image manually if not the template

# 2) Generate secrets
openssl rand -base64 48 | tr -d '/+='   # PUBLIC_API_KEY
openssl rand -base64 32 | tr -d '/+='   # TOKEN_PEPPER

# 3) Apply migrations (needs psql; uses proxy URL for connectivity)
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
DATABASE_URL=<railway-proxy-url> PGCONNECT_TIMEOUT=10 ./scripts/migrate-railway.sh

# 4) Seed road network (NS-wide)
./scripts/load-municipalities.sh   # StatCan boundaries
./scripts/osm-import.sh            # OSM ways → road_segments

# 5) Create the api service + set env vars + deploy
railway add --service api
railway link --service api
railway variables --set DATABASE_URL=<internal-railway.internal-url> \
                  --set PUBLIC_API_KEY=<from-step-2> \
                  --set TOKEN_PEPPER=<from-step-2> \
                  --set PG_POOL_MAX=10 --set PORT=8000
railway up --service api --ci

# 6) Generate public domain
railway domain
```

### Deploy a code change to existing Railway env

```bash
railway link  # if not already linked
railway up --service api --ci
```

Health: `curl <api-url>/functions/v1/health` (no apikey required).

### Verify schema on Railway DB

```bash
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
DATABASE_URL=<proxy-url> PGCONNECT_TIMEOUT=10 ./scripts/migrate-railway.sh   # idempotent; safe to re-run
```

`migrate-railway.sh` parses `DATABASE_URL` into libpq `PG*` environment variables before invoking `psql`, so credentials do not appear in child process arguments. Keep using that script for replay instead of `psql "$DATABASE_URL"`.

After replay, run the API smoke against the deployed Deno service:

```bash
FUNCTIONS_BASE_URL=<api-url>/functions/v1 \
PUBLIC_API_KEY=<public-api-key> \
./scripts/api-smoke.sh
```

Expected checks:
- `/health` and `/health/deep` return healthy responses.
- `/stats` returns the public materialized-view shape.
- `/top-potholes?limit=5` returns `{ "potholes": [...] }`; this catches accidental fallback to removed PostgREST RPC paths.
- `/upload-readings` accepts a fresh batch and duplicate replay.

For local smoke against the Railway public TCP proxy, Deno may reject the proxy certificate with `UnknownIssuer` even though `psql` connects. Prefer smoking the deployed Railway service. If you must run `supabase/functions/server.ts` locally against the proxy, scope Deno's temporary certificate bypass to that proxy host:

```bash
deno run --unsafely-ignore-certificate-errors=<railway-proxy-host> \
  --allow-all supabase/functions/server.ts
```

Do not use that flag in Railway; the deployed service should use the internal `*.railway.internal` database URL and does not need TLS.

If maps look empty after a migration replay, verify the tile function was updated rather than assuming the API service needs a redeploy:

```sql
SELECT length(get_tile(14, 5460, 5961)) AS tile_bytes;
```

The Halifax staging fixture should return a non-zero byte count once `20260426203000_quality_corridor_tiles.sql` is applied.

### Scheduled jobs on Railway (no pg_cron)

Railway's stock PostGIS template doesn't include pg_cron. The `migrate-railway.sh` preflight installs no-op stubs so migrations apply cleanly. The Deno service then runs an in-process scheduler (`supabase/functions/_shared/scheduler.ts`) that fires the same jobs pg_cron would have:

| Job | Cadence | What it does |
|---|---|---|
| `refresh-public-stats-mv` | every 5 min | Refreshes `public_stats_mv` so `/stats` isn't stale |
| `refresh-public-worst-segments-mv` | every 15 min | Refreshes the worst-segments materialised view |
| `create-next-readings-partition` | every 24h | Pre-creates next month's `readings_YYYY_MM` partition before the calendar rolls over (otherwise inserts would fail with "no partition of relation found for row") |
| `nightly-aggregate-recompute` | every 24h | Full aggregate recompute |
| `pothole-expiry` | every 24h | Marks unconfirmed potholes as expired |
| `rate-limit-gc` | every 24h | Trims old rate-limit rows |
| `drop-old-readings-partitions` | every 24h | Drops partitions older than 6 months |

The scheduler activates when `RAILWAY_ENVIRONMENT` env var is set (i.e. running on Railway), or when `ENABLE_SCHEDULER=true` is set explicitly. It stays off during local dev and tests so the logs are quiet.

Each job is idempotent (REFRESH CONCURRENTLY, CREATE TABLE IF NOT EXISTS) so multiple replicas all running the scheduler is safe — wasteful, but safe.

The cron stub is replay-safe: `cron.schedule(job_name, ...)` upserts by `jobname`, and `cron.unschedule(jobid)` removes every row for that job name. If an older replay left duplicates behind, re-run `migrate-railway.sh`; its preflight dedupes `cron.job` before applying migrations.

To force a refresh manually:

```sql
REFRESH MATERIALIZED VIEW public_stats_mv;
REFRESH MATERIALIZED VIEW public_worst_segments_mv;
SELECT create_next_readings_partition();
```

## Secrets Management

### Backend

- Supabase secrets via `supabase secrets set` — one command per env
- `TOKEN_PEPPER` (64-char random string, per-env) — used to hash device tokens
- `OSM_SNAPSHOT_URL` — pinned quarterly
- `SENTRY_DSN` — backend error reporting
- Keys rotated: pepper every 12 months (only affects forward contributor linkage, no data migration needed)

### iOS

- API URL + Mapbox public key in a build-time `.xcconfig` file, one per scheme:
  - `RoadSenseNS.Local.xcconfig`
  - `RoadSenseNS.Staging.xcconfig`
  - `RoadSenseNS.Production.xcconfig`
- Base `.xcconfig` files are committed in `ios/Config/` with non-secret defaults so `xcodegen generate` works from a clean checkout
- Developer-specific or CI-injected overrides belong in optional ignored files:
  - `RoadSenseNS.Local.secrets.xcconfig`
  - `RoadSenseNS.Staging.secrets.xcconfig`
  - `RoadSenseNS.Production.secrets.xcconfig`
- Copy/reference templates still live in `ios/Config/Templates/`
- In CI, `.xcconfig` files written from GitHub Actions secrets at build time
- No Mapbox **secret** token is shipped to the device in MVP. If post-MVP private Mapbox downloads are ever needed, proxy them through a backend-controlled flow; do not stash a secret on-device.

### GitHub Actions

Stored in repo settings:

- `APPLE_ASC_API_KEY_ID`, `APPLE_ASC_API_ISSUER_ID`, `APPLE_ASC_API_PRIVATE_KEY` — App Store Connect API for TestFlight uploads
- `MATCH_PASSWORD` + `MATCH_GIT_URL` — fastlane match for signing certs (if we go that route)
- `SUPABASE_ACCESS_TOKEN` — for deploying migrations + functions
- `SENTRY_AUTH_TOKEN` — symbolication upload
- `MAPBOX_DOWNLOAD_TOKEN` — SDK dependency fetch

## Repo Layout

```
roadsense-ns/
├── docs/
├── apps/
│   └── web/                     # Phase-2 public dashboard (Next.js)
├── ios/                         # Xcode project + Swift source
├── supabase/
│   ├── migrations/              # timestamped .sql files
│   ├── functions/               # Edge Functions (TypeScript/Deno)
│   │   ├── upload-readings/
│   │   ├── tiles/
│   │   ├── tiles-coverage/
│   │   ├── segments/
│   │   ├── segments-worst/
│   │   ├── potholes/
│   │   ├── stats/
│   │   └── health/
│   ├── tests/                   # pgTAP
│   └── seed.sql                 # staging-only seed data
├── scripts/
│   ├── osm-import.sh
│   ├── osm2pgsql-style.lua
│   ├── segmentize.sql
│   ├── tag-municipalities.sql
│   └── tag-features.sql
├── .github/
│   └── workflows/
│       ├── ios-ci.yml
│       ├── backend-ci.yml
│       ├── web-ci.yml           # Phase-2
│       ├── deploy-staging.yml
│       ├── deploy-production.yml
│       └── ...
└── README.md
```

## CI/CD Pipelines

### `ios-ci.yml` (manual-only for now)

```
1. Checkout
2. Verify committed iOS scaffold + base `.xcconfig` files exist
3. Run `swift test` in `ios/` to validate bootstrap seams
4. Install XcodeGen
5. Run `xcodegen generate`
6. `xcodebuild test` for the full `RoadSenseNS` scheme on iPhone simulator
```

Runs on `macos-14` runners. Target: < 15 min.

Current repo note:

- Automatic iOS CI is intentionally disabled for now to avoid burning macOS minutes before Apple approval and signed-device testing make those failures actionable.
- When we re-enable it, the right trigger is internal TestFlight readiness/shared testing, not "first production deploy."

### `backend-ci.yml` (manual-only for now)

```
1. Checkout
2. Write local Edge Function `.env` with CI-only `TOKEN_PEPPER`
3. supabase start (boots Postgres + Deno locally)
4. supabase db reset (applies migrations)
5. supabase test db (pgTAP)
6. For each function: deno test
7. Run `./scripts/api-smoke.sh`
8. Run `./scripts/seeded-e2e-smoke.sh`
```

Runs on `ubuntu-22.04`. Target: < 10 min.

Current repo note:

- Automatic backend CI is intentionally disabled for now to conserve Actions minutes while local Supabase + local verification remain the primary loop.

### `web-ci.yml` (Phase 2, manual-only for now)

```text
1. Checkout
2. Install Node dependencies
3. `npx tsc --noEmit`
4. Vitest (unit + integration)
5. `next build`
6. Lighthouse trust-page checks
7. Playwright smoke tests against mocked APIs
```

Runs on `ubuntu-22.04`. Target: < 10 min. Add preview-URL Playwright smoke only after Vercel previews are live.

### `deploy-staging.yml` (manual dispatch, when staging exists)

```
1. Use the `staging` GitHub Environment and require:
   - `SUPABASE_ACCESS_TOKEN`
   - `SUPABASE_PROJECT_REF`
   - `SUPABASE_DB_PASSWORD`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_TOKEN_PEPPER`
   - optional `SENTRY_DSN`
   - optional `OSM_SNAPSHOT_URL`
2. `supabase link --project-ref "$SUPABASE_PROJECT_REF" -p "$SUPABASE_DB_PASSWORD"`
3. `supabase db push`
4. `supabase secrets set` for function-only secrets
5. deploy every function under `supabase/functions/` except `_shared`
6. run `./scripts/api-smoke.sh`
7. run `./scripts/seeded-e2e-smoke.sh`
```

If the required environment secrets are absent, the workflow should skip rather than fail. This is intentional while staging is deferred.

### OSM Re-import

Not part of the normal deploy. Triggered manually (`workflow_dispatch`) or quarterly via scheduled workflow. Runs on a self-hosted runner or ephemeral Fly.io machine with PG access:

```
1. Download pinned OSM snapshot (OSM_SNAPSHOT_URL)
2. osm2pgsql --style scripts/osm2pgsql-style.lua → osm.osm_ways
3. TRUNCATE road_segments_staging; run scripts/segmentize.sql against staging, not `road_segments`
4. Validate row count within ±5% of prior import (guard against bad snapshot)
5. Run `apply_road_segment_refresh()` to upsert staging → primary while preserving existing `road_segments.id` values on `(osm_way_id, segment_index)`
6. Run `rematch_readings_after_segment_refresh()` for retained raw readings (last 6 months) and capture the touched segment IDs
7. Call `nightly_recompute_aggregates(<touched_segment_ids>)` to rebuild only the impacted aggregates
```

Once staging exists, it runs on schedule to catch drift early; production runs only after staging passes a manual smoke test.

### `deploy-production.yml` (manual dispatch only)

Uses the `production` GitHub Environment with the same secret names as staging. Requires an explicit GitHub Environment approval before it runs. Same steps as staging but against prod once real users exist. Always preceded by:

1. Manual smoke test on staging if staging exists; otherwise do not use production yet
2. Tag the commit `prod-<date>`
3. Dispatch workflow

### TestFlight release automation

GitHub Actions now owns the repeatable TestFlight path in `.github/workflows/ios-testflight.yml`. It builds `Staging Release` by default, can switch to `Production Release`, and can run with upload disabled for signing dry runs.

Required repository secrets:

- `APPLE_ASC_API_KEY_ID`
- `APPLE_ASC_API_ISSUER_ID`
- `APPLE_ASC_API_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `MAPBOX_ACCESS_TOKEN`

The workflow still needs valid Apple distribution signing material for CI. If App Store Connect API authentication cannot provision/sign automatically on a clean runner, use `fastlane match` or manually import an Apple Distribution certificate plus App Store provisioning profile before `build_app`.

## Observability Verification Checklist

Before inviting wider testers, run this checklist once against a signed build and once against whichever backend environment is actually shared by testers (`staging` if it exists, otherwise the first hosted env you use).

### iOS

- confirm Sentry initializes only outside XCTest / simulator test bootstrap
- force one handled error and one non-fatal upload failure in a controlled environment
- verify events arrive in Sentry with:
  - app version
  - environment
  - request ID if present
  - no raw latitude / longitude
  - no photo storage paths or signed upload URLs
  - no raw device token
  - no IP address
  - no free-form user-entered text
- confirm `os_log` lines use coarse counters / IDs only

### Backend

- confirm `upload-readings` logs include:
  - `batch_id`
  - accepted / rejected counts
  - duration
  - app version if present
- confirm backend logs do **not** include:
  - raw `device_token`
  - full `device_token_hash`
  - IP address
  - exact coordinates
  - signed photo upload URLs
  - full request payload dumps
- confirm at least one forced 5xx reaches backend Sentry
- confirm rate-limit events still avoid raw token/IP leakage

### Web

- confirm no browser analytics or session replay is enabled
- confirm browser errors, if captured later, redact query text and route-state values that could encode sensitive places

Use [09-internal-field-test-pack.md](09-internal-field-test-pack.md) as the human execution layer on top of this observability checklist.

## TestFlight Distribution Tiers

Two distinct modes — pick based on what you need, not reflexively go for external.

### Internal Testing (Apple Dev account needed — no App Store Review)

- Up to 100 internal testers, all must be added to App Store Connect under your dev team (as users, not just emails)
- Each tester installs TestFlight app, accepts invite — ready to run build within minutes of upload
- **No Beta App Review** — builds are available immediately after processing (~5–15 min)
- Use this for: immediate family/close friends, the first 2–3 weeks of field testing, tight iteration
- Build expires 90 days after upload; uploading a new build extends
- This is how we run weeks 5–7

### External Testing (requires Apple Beta App Review)

- Up to 10,000 testers via link or email
- Requires one-time Beta App Review per build (typically 24–48h, can be longer)
- Test Information screen (what to test, contact email, privacy policy URL) required before submission
- Use this for: broader beta wave (week 8+), friends-of-friends, any tester you don't have a formal relationship with
- Subsequent builds within the same major version usually get expedited review (few hours)

### TestFlight Workflow

Week 1: enrol in Apple Developer Program ($99 USD/yr) — **do this day 1** since paperwork can take 48h. Create app record in App Store Connect with bundle ID `ca.roadsense.ios`.

Week 5: upload first TestFlight build, add 5–10 internal testers (family + self on 2 devices).

Week 7: expand to ~30 internal testers (friends, willing neighbours).

Week 8: submit for Beta App Review to unlock external testing. Prepare:
- Test Information: describe the app's purpose, test focus (driving scenarios), how to report bugs
- Privacy policy URL (required — host at `https://roadsense.ca/privacy` to match 06; do not ship with two different domains across the app and the privacy policy link)
- Contact email (graham.mann14@gmail.com OK for MVP)
- Demo credentials: N/A (no account required, mention this in notes)

## Migration Deployment Discipline

- Migrations **run as a unit** — if one fails mid-deploy, the deploy fails and manual intervention is required
- Every migration has a documented rollback in its header comment:

```sql
-- Migration: 20260415_add_trend_column
-- Purpose: add trend column to segment_aggregates
-- Rollback: ALTER TABLE segment_aggregates DROP COLUMN trend;
```

- Data migrations (backfills) that exceed 30s go in **separate PR after** the schema migration:
  1. PR 1: add column nullable, deploy
  2. PR 2: backfill via scheduled job or one-off script
  3. PR 3: make column NOT NULL + add constraint
- Partition additions are automated via cron, but we also pre-create 3 months ahead manually to tolerate cron failure

### iOS Local Store Migrations

- Treat SwiftData schema changes with the same discipline as backend migrations
- Every schema bump ships with:
  - a `VersionedSchema`
  - a `SchemaMigrationPlan`
  - a fixture store created by the prior schema and opened in CI by the new schema
- Post-MVP additive migrations are expected in this order:
  1. add `PotholeReportRecord`
  2. add `DriveSessionRecord`
  3. add optional `ReadingRecord.drive` relationship
- Never ship a build that both changes the schema and silently deletes the prior local store as the fallback path

## Logging

### iOS

- `os.Logger` with subsystem `ca.roadsense.ios`
- Log level overrides via a hidden dev menu (triple-tap version number in Settings)
- Logs NEVER written to disk by the app — Apple's unified logging system owns lifetime
- `Logger.debug(...)` is stripped in production builds via conditional compilation

### Backend

- Railway Deno service uses `console.log` / `console.error`; inspect with `railway logs --service api`. Local Supabase functions still use Supabase's function logs.
- Structured JSON logs for anything ingestion-related (one object per batch):

```json
{
    "ts": "2026-04-17T14:30:00Z",
    "event": "batch_processed",
    "batch_id": "...",
    "device_token_hash_prefix": "ab12",  // first 4 hex of hash, for grouping w/o identifying
    "accepted": 48,
    "rejected": 2,
    "duration_ms": 1341,
    "client_app_version": "0.1.3 (42)"
}
```

- Never log full `device_token_hash` or IP addresses in analytics logs. Include only the prefix for grouping.
- Stored procedure logs via `RAISE NOTICE` are captured by Supabase and tagged with the procedure name.

## Metrics

For MVP, Supabase's built-in dashboards cover most of what we need. Supplement with:

### Sentry (errors + crashes)

- iOS: Sentry Cocoa SDK, capture uncaught exceptions and `NSError` from critical paths (sensor pipeline, upload, permissions)
- Backend: Sentry for Edge Functions (Deno SDK) — capture 5xx from every function
- Sample rate: 100% for errors, 10% for transactions
- **PII scrubbing enabled** — default Sentry PII stripping + custom rule to strip lat/lng from breadcrumbs

### Custom metrics (Postgres)

One table for simple counters we want to dashboard without a third-party tool:

```sql
CREATE TABLE ops_metrics (
    metric TEXT NOT NULL,
    bucket TIMESTAMPTZ NOT NULL,    -- truncated to hour
    value BIGINT NOT NULL,
    PRIMARY KEY (metric, bucket)
);
```

Increment via `INSERT ... ON CONFLICT DO UPDATE SET value = value + 1` from the Edge Function post-processing. Dashboard via a simple Metabase or Supabase Studio SQL tab:

- `batch.accepted`
- `batch.rejected`
- `batch.duplicate`
- `reading.no_segment_match`
- `rate_limit.hit.device`
- `rate_limit.hit.ip`
- `tile.served`
- `tile.error`

### What we track but don't dashboard weekly

- Unique contributors (weekly)
- Readings per segment distribution (monthly)
- Coverage % per municipality (monthly)
- Score category distribution (monthly)

## Alerts

Prefer fewer, louder alerts over noise. MVP alerts:

| Alert | Trigger | Channel | Action |
|---|---|---|---|
| Backend error rate high | Sentry: > 10 errors/hour from backend AND ≥ 50 requests/hour (floor to suppress quiet-hour flaps) | Email to graham.mann14@gmail.com | Investigate within 4h |
| iOS crash rate high | Sentry: crash-free-rate < 99% for 30+ minutes AND ≥ 20 sessions in the window (percentages are meaningless on small denominators) | Email | Hotfix evaluation |
| Supabase DB unhealthy | Supabase built-in alerts: CPU > 80% for 15min, storage > 80% | Email + Supabase dashboard | Upgrade instance |
| Ingestion latency spike | Custom: p95 `/upload-readings` > 5s for 10min AND ≥ 20 batches in the window | Email | Check DB, check Edge Function logs |
| Tile 5xx rate | Custom: > 1% 5xx for 10min AND ≥ 100 tile requests in the window | Email | Check Edge Function logs |

**Why the floors:** at MVP scale we'll have quiet hours with 0–2 requests. A single 500 becomes "100% error rate" and pages at 3 a.m. for nothing. Every rate-based alert needs a minimum-volume gate set just above typical off-peak traffic. Tune floors after the first week of production data.

Pager-style alerts (SMS/phone) are overkill for MVP. Email + checking in once a day is enough at TestFlight scale.

## Health Check Strategy

- `GET /health` is a lightweight unauthenticated liveness endpoint and does not touch the DB.
- `GET /health/deep` verifies DB connectivity and requires the public API key.
- External uptime monitor pings `/health` every 5 minutes (UptimeRobot free tier or similar)
- Alert on 3+ consecutive failures (15 min down)

## Deploy Playbook — Normal Day

1. Before shared hosted environments exist: rely on CI + local Supabase + signed-device smoke
2. Once staging exists: engineer manually dispatches `deploy-staging.yml`
3. Engineer manually smoke-tests staging (drive, check data arrives, check map)
4. Engineer manually dispatches `deploy-production.yml`
5. Engineer tags `prod-<date>`, posts summary in GitHub Discussions/wherever

## Deploy Playbook — Incident

**Step 1: Triage** — what's broken, for whom, how bad?

- DB down → Supabase console, their status page, restore from backup if needed
- Edge Function down → check function logs, roll back last deploy via git revert + redeploy
- Data corruption → **STOP WRITES** by disabling the Edge Function route, investigate

**Step 2: Rollback criteria**

Roll back if:
- Crash-free rate drops below 97% post-deploy
- Error rate > 100/hour post-deploy
- Any data-integrity issue (wrong segment assignment, lost readings)

**Rollback mechanism:**
- iOS: TestFlight users download the prior build (TestFlight auto-provides previous build)
- Backend: git revert + redeploy (migrations are additive only; never reverted without an explicit data-loss plan)

**Step 3: Communicate** — post in the beta tester channel (Slack/Discord/GitHub) if tester-facing.

**Step 4: Postmortem** — document in `docs/incidents/YYYY-MM-DD-short-title.md`. Blameless, specific root cause, specific corrective actions. Mandatory within 48h.

## Backup & Disaster Recovery

- Railway Postgres backups/PITR must be enabled per environment before external TestFlight. Confirm the current Railway plan's retention window during environment provisioning and document it next to the project link.
- Monthly manual export of `road_segments` (static-ish) + `segment_aggregates` (derived) to S3 or similar cold storage — defense against provider outage
- `readings` raw data is NOT backed up externally — it's ingestable but also regeneratable from app uploads if the window is short. 6-month retention cap means we only carry ~1TB worst case.

## Offline / Degraded Backend Behavior (iOS)

- If backend is unreachable, uploads queue locally (SwiftData)
- Tile requests fall back to Mapbox-cached tiles (previously viewed)
- Map UI shows an "offline" chip but remains functional
- Data collection continues normally

## Monitoring Dashboard (Supabase Studio + Metabase)

Set up one dashboard with:

1. Ingestion: batches/hour, accepted/rejected ratio, p50/p95 latency
2. Tile serving: requests/hour, cache hit ratio, p95 latency
3. Data: readings/day, unique contributors (weekly), segments-with-data count
4. Errors: 4xx/5xx counts, top error codes, top client app versions hitting errors
5. Coverage: % of HRM segments with ≥ 3 contributors

Link it in the project README so anyone on the team (future-you included) can check health in 30s.

## Phase 2 Web Dashboard Deployment (Vercel)

When the public web dashboard in [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md) is built, deploy it separately from the Supabase backend.

### Hosting model

- **Frontend:** Vercel
- **API / tiles:** existing Supabase Edge Functions
- **Domain:** same public site domain as the privacy policy once the domain decision in 00 is locked

Recommended production shape:

- apex or primary public domain serves the web dashboard and content pages
- `/privacy` and `/methodology` live in the web app, not as orphaned static pages elsewhere
- Supabase Edge Functions stay on their own function URLs or a dedicated API subdomain

### Web env vars

Expose only browser-safe values:

- `NEXT_PUBLIC_MAPBOX_TOKEN`
- `NEXT_PUBLIC_MAPBOX_STYLE_ID` or style URL
- `NEXT_PUBLIC_API_BASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SITE_URL`

Rules:

- no service-role key in any Vercel project
- no session-replay or ad-tech env vars
- if future municipal-auth features need privileged reads, keep those secrets server-only and out of `NEXT_PUBLIC_*`

### Vercel environments

- **Preview:** every PR to the future web app
- **Production:** merges to `main` after the web dashboard is in active development

Preview deploy checks:

1. page shell loads
2. map renders
3. `/reports/worst-roads` renders with real data
4. `/methodology` and `/privacy` have no broken links

### Web smoke test after deploy

Run these on both preview and production:

1. open `/`
2. switch between quality, potholes, and coverage
3. select a segment and load the drawer
4. open `/municipality/halifax`
5. open `/reports/worst-roads`
6. verify `/privacy` and `/methodology`

### Web observability

Minimum viable web observability:

- Vercel request logs
- Playwright smoke run in CI against preview URL
- backend endpoint logs still remain the source of truth for tiles and JSON read-path failures

Avoid in W1 web:

- product analytics suites
- session replay
- invasive browser telemetry

If frontend error monitoring is added later, keep it to error capture only. No DOM capture, no replay, no raw query-string logging if it can contain location-like search text.

## Operations Policy Decisions

- **No structured frontend analytics in MVP or initial web launch.** Privacy-first positioning and limited product scope do not justify PostHog, Mixpanel, or similar tools.
- **Keep Supabase logs at the default 7-day retention.** Extract durable signals into `ops_metrics` instead of paying for longer raw-log retention early.
- **Alert escalation stays simple.** Email-only during MVP and early beta; formal on-call rotation only if the project grows beyond a single maintainer.
