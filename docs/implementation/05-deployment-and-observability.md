# 05 — Deployment & Observability

*Last updated: 2026-04-17*

Covers: environments, CI/CD, secrets, logging, metrics, alerting, and the "what to do when something breaks at 11pm" playbook.

## Environments

| Env | Purpose | Supabase project | iOS scheme | Maps key |
|---|---|---|---|---|
| `local` | Local dev (`supabase start`) | auto | `RoadSenseNS-Local` | personal dev key |
| `staging` | Persistent integration env | `roadsense-staging` | `RoadSenseNS-Staging` | staging key |
| `production` | Real users | `roadsense-prod` | `RoadSenseNS` | production key |

`staging` and `production` are **physically separate Supabase projects**. No shared database, no RLS multi-tenancy trickery. Keeps blast radius small.

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
- `.xcconfig` files are `.gitignore`'d — committed templates with placeholders live in `RoadSenseNS/Config/Templates/`
- In CI, `.xcconfig` files written from GitHub Actions secrets at build time
- Mapbox **secret** token (for private tile downloads if ever used) stored in Keychain at first launch; never in the binary

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
├── ios/                         # Xcode project + Swift source
├── supabase/
│   ├── migrations/              # timestamped .sql files
│   ├── functions/               # Edge Functions (TypeScript/Deno)
│   │   ├── upload-readings/
│   │   ├── tiles/
│   │   ├── segments/
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
│       ├── deploy-staging.yml
│       ├── deploy-production.yml
│       └── testflight.yml
└── README.md
```

## CI/CD Pipelines

### `ios-ci.yml` (every PR)

```
1. Checkout
2. Restore SPM cache
3. Lint: SwiftLint (fail on warnings)
4. Write .xcconfig from secrets
5. Build RoadSenseNS-Staging scheme
6. xcodebuild test (unit + sim harness)
7. Upload coverage to Codecov
```

Runs on `macos-14` runners. Target: < 15 min.

### `backend-ci.yml` (every PR)

```
1. Checkout
2. supabase start (boots Postgres + Deno locally)
3. supabase db reset (applies migrations)
4. supabase test db (pgTAP)
5. For each function: deno test
6. Lint migrations: sqlfluff dialect=postgres
```

Runs on `ubuntu-22.04`. Target: < 10 min.

### `deploy-staging.yml` (on merge to `main`)

```
1. supabase db push --project-ref staging-ref
2. supabase functions deploy --project-ref staging-ref
3. If OSM source changed (osm2pgsql-style.lua, segmentize.sql, tag-*.sql): queue the
   OSM re-import job on a separate worker (long-running, ~30-60 min) rather than
   running inline — see §OSM Re-import.
4. Run smoke test: hit /health, /stats, /tiles/10/320/390.mvt
5. Post Slack (if configured) or GitHub comment with deploy summary
```

### OSM Re-import

Not part of the normal deploy. Triggered manually (`workflow_dispatch`) or quarterly via scheduled workflow. Runs on a self-hosted runner or ephemeral Fly.io machine with PG access:

```
1. Download pinned OSM snapshot (OSM_SNAPSHOT_URL)
2. osm2pgsql --style scripts/osm2pgsql-style.lua → osm.osm_ways
3. TRUNCATE road_segments_staging; run scripts/segmentize.sql
4. Validate row count within ±5% of prior import (guard against bad snapshot)
5. Swap road_segments ← road_segments_staging in a single transaction
6. Kick nightly_recompute_aggregates to reassign any orphaned segment_aggregates
```

Staging runs on schedule to catch drift early; production runs only after staging passes a manual smoke test.

### `deploy-production.yml` (manual dispatch only)

Requires an explicit GitHub Environment approval from Graham before it runs. Same steps as staging but against prod. Always preceded by:

1. Manual smoke test on staging
2. Tag the commit `prod-<date>`
3. Dispatch workflow

### `testflight.yml` (manual dispatch or tag push)

```
1. Checkout
2. xcodebuild archive RoadSenseNS scheme (production config)
3. fastlane pilot upload → TestFlight
4. Upload dSYM to Sentry
5. Post release notes to GitHub Releases
```

Target: < 30min end-to-end. Done by the human on release day.

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
- Privacy policy URL (required — once the domain is locked per 00 §Open Questions #6, host at `<domain>/privacy`. Working assumption is `roadsense.ca/privacy` to match 06; do not ship with two different domains across the app and the privacy policy link)
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

## Logging

### iOS

- `os.Logger` with subsystem `ca.roadsense.ios`
- Log level overrides via a hidden dev menu (triple-tap version number in Settings)
- Logs NEVER written to disk by the app — Apple's unified logging system owns lifetime
- `Logger.debug(...)` is stripped in production builds via conditional compilation

### Backend

- Edge Functions use `console.log` / `console.error` — Supabase collects them into a queryable log stream
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

- `GET /health` endpoint verifies DB connectivity + returns deploy metadata
- External uptime monitor pings `/health` every 5 minutes (UptimeRobot free tier or similar)
- Alert on 3+ consecutive failures (15 min down)

## Deploy Playbook — Normal Day

1. PR merged to main → `deploy-staging.yml` auto-runs
2. Engineer manually smoke-tests staging (drive, check data arrives, check map)
3. Engineer manually dispatches `deploy-production.yml`
4. Engineer tags `prod-<date>`, posts summary in GitHub Discussions/wherever

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

- Supabase Pro: automated daily backups, point-in-time recovery for 7 days
- Monthly manual export of `road_segments` (static-ish) + `segment_aggregates` (derived) to S3 or similar cold storage — defense against Supabase outage
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

## Open Questions

- **[OPEN] Do we need structured frontend analytics (event tracking)?** Temptation is to use PostHog or Mixpanel. Recommendation: defer — privacy-first positioning makes analytics awkward; in-app stats + Sentry are enough for MVP.
- **[OPEN] Logs retention period in Supabase?** Supabase default is 7 days. Could extend to 30 days on Pro for an extra fee. Lean: 7 days, extract critical signals into `ops_metrics` for longer retention.
- **[OPEN] Alert escalation?** For MVP, single engineer. When/if team grows, formalize on-call rotation.
