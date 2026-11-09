# 05 — Deployment & Observability

*Last updated: 2026-11-08*

Covers: environments, the production deploy order, CI/CD, secrets, logging, metrics, alerting, backups, and the "what to do when something breaks at 11pm" playbook.

## Environments

| Env | Purpose | Backend host | iOS scheme | Maps key |
|---|---|---|---|---|
| `local` | Local dev (`supabase start`) | local Supabase | `RoadSenseNS-Local` | personal dev key |
| `staging` | Not provisioned yet | none (the Railway project has only `production`) | `RoadSenseNS-Staging` | staging key |
| `production` | Real users | Railway PostGIS + Deno API behind the Cloudflare Worker | `RoadSenseNS` | production key |

There is no staging backend today. The staging iOS xcconfig and the Android staging flavor point at production, so "staging" builds write real data. When staging is provisioned it should be a separate Railway environment (or project) with its own database, so a bad migration cannot reach production.

### Current public endpoints

- API: `https://api.nsroadsense.ca/functions/v1` (Cloudflare Worker `nsroadsense-api-proxy` → Railway)
- Tiles: `https://tiles.nsroadsense.ca` (same Worker)
- API origin: `https://api-production-075e9.up.railway.app/functions/v1` (reachable, but with `REQUIRE_ORIGIN_AUTH=true` it answers only `/health`; never smoke it directly)
- Web: `https://nsroadsense.ca` (Cloudflare Workers via OpenNext, `apps/web/wrangler.jsonc`)
- DB (admin): Railway TCP proxy URL (`*.proxy.rlwy.net`); see `.railway-secrets.local` (gitignored). The API uses the private `postgis.railway.internal` host.

## Production deploy

Production is deployed **by hand** from a laptop, or with the `deploy-production.yml` workflow for the database + API part. Nothing deploys on push.

### Safe deploy order

Run the steps in this order. Each one assumes the previous one finished.

1. **Snapshot the database.** Railway → `postgis` service → Backups → *Create backup*. Note the backup time.
2. **Count the rows the next partition drop removes.** The nightly `drop-old-readings-partitions` job drops `readings_YYYY_MM` partitions older than 6 months, and a dropped partition cannot be recovered except from a backup.
   ```bash
   export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
   DATABASE_URL=<railway-proxy-url> scripts/report-expiring-partitions.sh --fail-if-rows
   ```
   Exit code 3 means rows would be dropped. Export them or accept the loss before going on.
3. **Apply migrations with `supabase db push`.** Never run `scripts/migrate-railway.sh` against production unless the ledger is baselined (see [Migration ledger baseline](#migration-ledger-baseline)). The Supabase CLI and the script share the same ledger table.
   ```bash
   supabase db push --db-url "$DATABASE_URL" --dry-run   # read the list of pending files
   supabase db push --db-url "$DATABASE_URL"
   ```
   If the dry run lists every migration, stop: the ledger is empty, and a push would replay all of them.
   **Disk headroom.** The production volume is 5 GB and the database uses about 3.4 GB (2026-11). A migration that rewrites a large table (`road_segments` has 1.74M rows; `readings` partitions are bigger) needs roughly a second copy of the table plus WAL. That filled the disk on 2026-11-09 and the database refused connections until it was restarted. Before pushing such a migration, run the rewrite in committed batches with `VACUUM (PARALLEL 0)` between them, so the migration's own statement matches nothing. Plain `VACUUM` without `PARALLEL 0` fails in this container, because `/dev/shm` is too small for parallel workers.
4. **Deploy the Cloudflare Worker** (`cloudflare/api-proxy`) with the origin secret:
   ```bash
   cd cloudflare/api-proxy
   npx wrangler secret put ORIGIN_SHARED_SECRET      # paste the value; same value as the Railway variable below
   npx wrangler deploy
   ```
5. **Deploy the API on Railway.**
   ```bash
   railway variable set "ORIGIN_SHARED_SECRET=<same value>" --service api --environment production --skip-deploys
   railway variable set "GIT_COMMIT_SHA=$(git rev-parse HEAD)" "GIT_SHA=$(git rev-parse HEAD)" \
     --service api --environment production --skip-deploys
   railway up --service api --environment production --ci --message "deploy $(git rev-parse --short HEAD)"
   scripts/wait-for-deploy.sh "$(git rev-parse HEAD)" 900
   ```
   `railway up` uploads the working tree, so Railway does not know the commit. `/health` reports the first of `RAILWAY_GIT_COMMIT_SHA` (set only by GitHub-triggered Railway deploys), `GIT_COMMIT_SHA` and `GIT_SHA`, and `wait-for-deploy.sh` polls `/health` until it matches. Run from a clean checkout of the commit you mean to ship.

   Only after the Worker from step 4 is live and sending the secret, turn on enforcement:
   ```bash
   railway variable set REQUIRE_ORIGIN_AUTH=true --service api --environment production
   ```
   Setting it before the Worker sends the header makes every proxied request fail. Shipping the API before the Worker leaves `x-client-ip` spoofable through the proxy. Once enforcement is on, the `*.up.railway.app` origin answers 403 to everything except `/health`, so every smoke, monitor and deploy check targets `https://api.nsroadsense.ca/functions/v1`.
6. **Smoke the API.** `api-smoke.sh` is the only smoke allowed against production; it leaves no public rows.
   ```bash
   FUNCTIONS_BASE_URL=https://api.nsroadsense.ca/functions/v1 PUBLIC_API_KEY=<key> \
     EXPECTED_COMMIT="$(git rev-parse HEAD)" scripts/api-smoke.sh
   ```
   Never run `scripts/seeded-e2e-smoke.sh` against production. It inserts a synthetic segment, and it refuses production hosts.

   Right after a deploy `/health/deep` may answer 503 `degraded` while the new process has not run its jobs yet; `api-smoke.sh` re-polls for up to `DEEP_HEALTH_WAIT_SECONDS` (default 180) and passes only when every non-`ok` job is `pending`. A `stale` or `failing` job fails the smoke.
7. **Deploy the web app.**
   ```bash
   cd apps/web
   npm ci
   npm run deploy:cloudflare      # opennextjs-cloudflare build + deploy
   ```
   `apps/web/wrangler.jsonc` still has a placeholder KV namespace id (`REPLACE_WITH_REAL_KV_NAMESPACE_ID`). Create the namespace (`npx wrangler kv namespace create NEXT_INC_CACHE_KV`) and put the real id in before the first web deploy.
8. **Mobile.** Dispatch `ios-testflight.yml` and `android-internal.yml` (each needs approval in its GitHub Environment).

### `deploy-production.yml`

The workflow runs steps 2, 3, 5 (without `REQUIRE_ORIGIN_AUTH`) and 6. It is `workflow_dispatch` only, runs only from `main`, and uses the `production` GitHub Environment. It:

1. checks every secret and variable, plus three inputs (`db_snapshot_taken`, `worker_deployed_first`, `allow_partition_drop`), before it changes anything;
2. refuses to run if `supabase_migrations.schema_migrations` is missing or empty;
3. runs `report-expiring-partitions.sh --fail-if-rows` unless `allow_partition_drop` is ticked;
4. runs `supabase db push --dry-run`, then `supabase db push --yes`;
5. sets `GIT_COMMIT_SHA`/`GIT_SHA` on the Railway service and runs `railway up --ci`;
6. waits up to 15 minutes for `/health` to report `github.sha`, then runs `api-smoke.sh` with `EXPECTED_COMMIT`.

If the migration step succeeds and the API step fails, the database is ahead of the code. Migrations are additive, so the old API keeps working; fix forward and re-run.

Environment `production`:

| Kind | Name | Value |
|---|---|---|
| secret | `DATABASE_URL` | Railway TCP proxy URL of the production database |
| secret | `RAILWAY_TOKEN` | Railway **project** token scoped to the `production` environment |
| secret | `PUBLIC_API_KEY` | public API key (sent as `apikey`) |
| variable | `FUNCTIONS_BASE_URL` | optional; default `https://api.nsroadsense.ca/functions/v1` |
| variable | `RAILWAY_SERVICE` | optional; default `api` |

`deploy-staging.yml` is the same pipeline for a future staging environment. It refuses production API hosts and the `production` Railway environment, and can also run `seeded-e2e-smoke.sh --allow-remote-non-production`.

### Migration ledger baseline

Before 2026-11 `migrate-railway.sh` kept no ledger, so the production database probably has no rows in `supabase_migrations.schema_migrations`. On such a database `supabase db push` would try to replay every migration. Baseline it once, after a snapshot:

1. Find the newest migration that is really applied. These objects arrive with the listed migrations:
   ```sql
   SELECT '20260612180000' AS version, to_regclass('public.segment_contributor_marks') IS NOT NULL AS present
   UNION ALL SELECT '20260612181000', EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                                              WHERE t.typname = 'pothole_status' AND e.enumlabel = 'candidate')
   UNION ALL SELECT '20260612182000', to_regclass('public.pothole_reporter_marks') IS NOT NULL
   UNION ALL SELECT '20260702150000', to_regprocedure('public.match_reading_to_segment(geometry,double precision,boolean)') IS NOT NULL
   UNION ALL SELECT '20260702160000', to_regclass('public.attested_devices') IS NOT NULL;
   ```
   Every row should be `t` up to the real latest version and `f` after it.
2. Record everything up to that version as applied, without running it:
   ```bash
   DATABASE_URL=<railway-proxy-url> scripts/migrate-railway.sh --dry-run
   DATABASE_URL=<railway-proxy-url> scripts/migrate-railway.sh --baseline-through <version> --i-know-this-is-production
   ```
   `supabase migration repair --status applied <version> ... --db-url "$DATABASE_URL"` does the same thing one version at a time.
3. Check: `supabase db push --db-url "$DATABASE_URL" --dry-run` now lists only the newer files.
4. If the old ledger-less script left an `applied_migrations` table behind, it is informational only and can be dropped.

## Railway runbook

### Provision a new environment

```bash
# 1) Create the project + DB. Use the PostGIS image pinned to a release tag.
railway link  # or: railway init <project-name>
railway add --database postgres  # then set the service image to postgis/postgis:16-3.7

# 2) Generate secrets
openssl rand -base64 48 | tr -d '/+='   # PUBLIC_API_KEY
openssl rand -base64 32 | tr -d '/+='   # TOKEN_PEPPER
openssl rand -base64 32 | tr -d '/+='   # ORIGIN_SHARED_SECRET

# 3) Bootstrap the empty database (needs psql; uses the proxy URL).
#    The script installs role, pg_cron and storage stand-ins, applies every
#    migration once, and records each in the ledger.
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
DATABASE_URL=<railway-proxy-url> scripts/migrate-railway.sh --dry-run
DATABASE_URL=<railway-proxy-url> scripts/migrate-railway.sh --i-know-this-is-production

# 4) Seed road network (NS-wide)
scripts/load-municipalities.sh   # StatCan boundaries
scripts/osm-import.sh            # OSM ways → road_segments (asks for confirmation on remote hosts)

# 5) Create the api service + set env vars + deploy
railway add --service api
railway link --service api
railway variable set DATABASE_URL=<internal-railway.internal-url> \
                     PUBLIC_API_KEY=<from-step-2> \
                     TOKEN_PEPPER=<from-step-2> \
                     ORIGIN_SHARED_SECRET=<from-step-2> \
                     PG_POOL_MAX=10 PORT=8000 --skip-deploys
railway variable set "GIT_COMMIT_SHA=$(git rev-parse HEAD)" --skip-deploys
railway up --service api --ci

# 6) Generate public domain
railway domain
```

After bootstrap, use `supabase db push` for every later migration.

`migrate-railway.sh` parses `DATABASE_URL` into libpq `PG*` variables, so the URL and password never reach `psql`'s argv. It applies each pending file in its own transaction with its ledger row, stops at the first failure, and refuses to write to a non-local host without `--i-know-this-is-production`. `scripts/tests/run.sh` covers it with a fake `psql`.

### Deploy a code change to the existing Railway env

Follow [Safe deploy order](#safe-deploy-order). For an API-only change with no migrations and no Worker change, steps 1, 5 and 6 are enough.

Health: `curl https://api.nsroadsense.ca/functions/v1/health` (no apikey required). It returns `commit`, which must match the commit you shipped.

### Smoke the deployed API

```bash
FUNCTIONS_BASE_URL=<api-url>/functions/v1 \
PUBLIC_API_KEY=<public-api-key> \
EXPECTED_COMMIT=<sha> \
scripts/api-smoke.sh
```

Expected checks:
- `/health` and `/health/deep` return healthy responses, and `/health` reports `EXPECTED_COMMIT`.
- `/stats` returns the public materialized-view shape.
- `/top-potholes?limit=5` returns `{ "potholes": [...] }`; this catches accidental fallback to removed PostgREST RPC paths.
- `/upload-readings` soft-rejects one deliberately low-speed reading (`rejected_reasons.low_quality = 1`, `accepted = 0`) and replays it as a duplicate. The fixed synthetic device token means no new contributor is counted.

For local smoke against the Railway public TCP proxy, Deno may reject the proxy certificate with `UnknownIssuer` even though `psql` connects. Prefer smoking the deployed Railway service. If you must run `supabase/functions/server.ts` locally against the proxy, scope Deno's temporary certificate bypass to that proxy host:

```bash
deno run --unsafely-ignore-certificate-errors=<railway-proxy-host> \
  --allow-all supabase/functions/server.ts
```

Do not use that flag in Railway; the deployed service should use the internal `*.railway.internal` database URL and does not need TLS.

If maps look empty after a migration, verify the tile function was updated rather than assuming the API service needs a redeploy:

```sql
SELECT length(get_tile(14, 5460, 5961)) AS tile_bytes;
```

### Scheduled jobs on Railway (no pg_cron)

Railway's stock PostGIS image doesn't include pg_cron. The `migrate-railway.sh` preflight installs no-op stubs so migrations apply cleanly. The Deno service then runs an in-process scheduler (`supabase/functions/_shared/scheduler.ts`) that fires the same jobs pg_cron would have:

| Job | Cadence | What it does |
|---|---|---|
| `refresh-public-stats-mv` | every 5 min | Refreshes `public_stats_mv` so `/stats` isn't stale |
| `refresh-public-worst-segments-mv` | every 15 min | Refreshes the worst-segments materialised view |
| `create-next-readings-partition` | daily | Pre-creates next month's `readings_YYYY_MM` partition (otherwise inserts fail with "no partition of relation found for row") |
| `purge-expired-readings` | daily | Deletes readings older than 6 months from the partition that straddles the cutoff, then recomputes the touched segments |
| `drop-old-readings-partitions` | daily | Drops partitions older than 6 months (irreversible; see step 2 of the deploy order) |
| `replay-unmatched-readings` | daily | Re-matches readings that had no segment |
| `nightly-aggregate-recompute` | daily | Aggregate recompute from a watermark |
| `pothole-expiry` | daily | Marks unconfirmed potholes as expired |
| `retention-sweeps` | daily | `run_retention_sweeps()`: rate limits, token challenges, feedback IPs, processed batches, pothole actions, reporter and contributor marks, unmatched readings |

The daily jobs are staggered by a few minutes each. The scheduler has its own connection pool without the request pool's 8 s `statement_timeout`, takes a per-job advisory lock so replicas don't double-run, and records each run; `/health/deep` reports a job as `stale` or `failing` from those records. Details: [02-backend-implementation.md → Scheduler (Railway)](02-backend-implementation.md#scheduler-railway).

The scheduler activates when `RAILWAY_ENVIRONMENT` env var is set (i.e. running on Railway), or when `ENABLE_SCHEDULER=true` is set explicitly. It stays off during local dev and tests so the logs are quiet.

To force a refresh manually:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv;
REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv;
SELECT create_next_readings_partition();
```

## Secrets Management

### Backend

- Railway service variables hold runtime secrets per environment
- `DATABASE_URL` — internal Railway Postgres URL for the API service
- `PUBLIC_API_KEY` / `SUPABASE_ANON_KEY` — public API key accepted through `Authorization: Bearer` and `apikey`
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

Release and deploy secrets live in **GitHub Environments**, not repository secrets, so only an approved job can read them (Settings → Environments; add required reviewers to each).

| Environment | Used by | Secrets / variables |
|---|---|---|
| `production` | `deploy-production.yml` | see [`deploy-production.yml`](#deploy-productionyml) |
| `staging` | `deploy-staging.yml` | same names as production, plus required variable `FUNCTIONS_BASE_URL` |
| `testflight` | `ios-testflight.yml` | `APPLE_ASC_API_KEY_ID`, `APPLE_ASC_API_ISSUER_ID`, `APPLE_ASC_API_PRIVATE_KEY`, `APPLE_TEAM_ID`, `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`, `APPLE_PROVISIONING_PROFILE_BASE64`, `MAPBOX_ACCESS_TOKEN`, `ROAD_SENSE_PUBLIC_API_KEY`, `SENTRY_DSN` |
| `android-internal` | `android-internal.yml` | `ANDROID_UPLOAD_KEYSTORE`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD`, `MAPBOX_ACCESS_TOKEN`, `SUPABASE_ANON_KEY_PRODUCTION`, `GOOGLE_PLAY_JSON_KEY`; variable `ANDROID_PUBLISH_ENABLED` |

Repository-level (no environment, because a scheduled job must not wait for approval):

- secret `HEALTH_CHECK_API_KEY` — public API key for `health-monitor.yml`
- variable `HEALTH_CHECK_URL` — optional; default `https://api.nsroadsense.ca/functions/v1/health/deep`
- secret `MAPBOX_DOWNLOADS_TOKEN` — optional; lets `android-ci.yml` compile the Mapbox-typed source set

Every workflow fails before doing anything if a secret it needs is missing. The old `RAILWAY_DEPLOY_HOOK_URL` and `RAILWAY_DATABASE_URL` secrets are no longer read.

## Repo Layout

```
roadsense-ns/
├── docs/
├── apps/
│   └── web/                     # public dashboard (Next.js, Cloudflare via OpenNext)
├── android/                     # Kotlin app (Gradle)
├── ios/                         # Xcode project + Swift source
├── cloudflare/
│   └── api-proxy/               # Worker in front of the Railway API (wrangler)
├── supabase/
│   ├── migrations/              # timestamped .sql files (ledger: supabase_migrations.schema_migrations)
│   ├── functions/               # Deno handlers; server.ts is the Railway entrypoint
│   ├── tests/                   # pgTAP
│   └── seed.sql                 # local seed data
├── scripts/                     # migrate, import, smoke and report scripts
│   ├── lib/pg-env.sh            # DATABASE_URL → PG* env, host checks
│   └── tests/                   # bash tests (run.sh) with a fake psql
├── Dockerfile                   # Railway API image (Deno, non-root)
└── .github/workflows/
```

## CI/CD Pipelines

PR CI runs on `pull_request` and on pushes to `main`, filtered by path, and can also be dispatched by hand. Every workflow has `permissions: contents: read`, checks out with `persist-credentials: false`, and pins third-party actions to full commit SHAs (the version is in a trailing comment). Tool versions: Deno **2.6.6** (same as the Dockerfile), Supabase CLI **2.95.4**, Node **22**.

| Workflow | Trigger paths | Jobs |
|---|---|---|
| `backend-ci.yml` | `supabase/**`, `scripts/**`, `cloudflare/api-proxy/**`, `Dockerfile`, `.dockerignore` | **deno**: `deno check server.ts`, `deno test` (functions), `deno test -A cloudflare/api-proxy` (Worker), `docker build`. **scripts**: `bash -n`, `shellcheck --severity=error`, `scripts/tests/run.sh`. **railway-migrations**: `migrate-railway.sh` on a plain `postgis/postgis:16-3.7`, a re-run that applies nothing, then `supabase db push --dry-run` must report the database up to date. **database**: `supabase start`, `supabase db reset`, `supabase test db` (pgTAP), `api-smoke.sh`, `seeded-e2e-smoke.sh` against the local stack. |
| `web-ci.yml` | `apps/web/**` | **web-check**: `npm ci`, `npx tsc --noEmit`, `npm test` (Vitest), `npm run build`. **web-browser** (dispatch only): OpenNext build, Lighthouse, Playwright. |
| `ios-ci.yml` | `ios/**` | **swift-package**: `xcrun swift test` in `ios/` on macOS. **simulator** (dispatch only): `xcodegen generate` + `xcodebuild test`. |
| `android-ci.yml` | `android/**` | Fixture parity check, `./gradlew test`, staging debug APK and staging release AAB, and (when `MAPBOX_DOWNLOADS_TOKEN` is set) the Mapbox-typed compile. |

Release and deploy workflows (all `workflow_dispatch`, each behind its GitHub Environment):

| Workflow | Does |
|---|---|
| `deploy-production.yml` | Migrations + Railway API + commit wait + `api-smoke.sh` ([details](#deploy-productionyml)) |
| `deploy-staging.yml` | Same against a staging environment; refuses production targets |
| `ios-testflight.yml` | Signed IPA → internal TestFlight ([details](#testflight-release-automation)) |
| `android-internal.yml` | Signed AAB → Play Internal Testing when `ANDROID_PUBLISH_ENABLED=true` |

Scheduled:

| Workflow | Does |
|---|---|
| `health-monitor.yml` | Every 30 minutes, `GET /functions/v1/health/deep` with `HEALTH_CHECK_API_KEY`; three tries 20 s apart; the run fails unless it returns `{"status":"ok","db":"reachable"}`. GitHub emails failures to whoever last edited the schedule. |

Run the same checks locally:

```bash
deno check supabase/functions/server.ts && deno test -A $(find supabase/functions -name '*_test.ts')
deno test -A cloudflare/api-proxy
scripts/tests/run.sh
supabase start && supabase db reset && supabase test db
(cd apps/web && npm ci && npx tsc --noEmit && npm test && npm run build)
(cd ios && xcrun swift test)
(cd android && ./gradlew test)
actionlint .github/workflows/*.yml
```

### OSM Re-import

Not part of the normal deploy, and not automated. Run `scripts/osm-import.sh` by hand with `DATABASE_URL` set; on a non-local host it checks `ROADSENSE_PRODUCTION_REGION_KEY` (default `nova-scotia`) and asks for confirmation.

```
1. Download the Geofabrik snapshot for REGION_KEY
2. osm2pgsql --style scripts/osm2pgsql-style.lua → osm.osm_ways
3. TRUNCATE road_segments_staging; run scripts/segmentize.sql against staging, not `road_segments`
4. Require at least OSM_MIN_TAGGED_PERCENT (default 80) of staged rows to have a municipality
5. In one transaction: `SELECT * FROM apply_road_segment_refresh();` then `SELECT finalize_road_segment_refresh();` (rematch retained readings, recompute every segment with readings or an aggregate, rebuild contributor marks, re-anchor open potholes)
6. REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv and public_worst_segments_mv
```

Take a database snapshot first.

### TestFlight release automation

`.github/workflows/ios-testflight.yml` owns the repeatable TestFlight path. It builds `Staging Release` by default, can switch to `Production Release`, and can run with upload disabled for signing dry runs. The job uses the `macos-26` hosted runner because App Store Connect requires iOS 26 SDK / Xcode 26 or later for uploaded iOS builds.

The job runs in the `testflight` GitHub Environment; the secrets are listed under [GitHub Actions](#github-actions). `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` is a base64-encoded Apple Distribution `.p12` (the legacy typo `APPLE_DISTRIBUTION_SECRET_BASE64` is still accepted), and `APPLE_PROVISIONING_PROFILE_BASE64` is the App Store `.mobileprovision` for `ca.roadsense.ios`. `SENTRY_DSN` is required when `enable_sentry` is on.

The workflow sets `ENABLE_POTHOLE_PHOTOS=NO` until the R2 photo backend ships. CI signing imports a stable Apple Distribution certificate and provisioning profile into a temporary keychain with a random per-run password, and uses manual App Store signing for the app target only; routine TestFlight builds must not create, renew, or revoke Apple signing certificates. On success it keeps the IPA (14 days) and dSYMs (30 days). On failure it uploads build **logs only**, never `ios/build`.

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
- Privacy policy URL (required — use `https://nsroadsense.ca/privacy`; do not ship with two different domains across the app and the privacy policy link)
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

### Changing the PostGIS image (learned 2026-11-09)

- Production runs a pinned image, `postgis/postgis:16-3.7`. Never use a floating tag like `16-master`: that tag shipped a `3.7.0dev` build which has no upgrade path.
- Railway CLI 4.59 `railway environment edit --service-config` reports "No changes to apply" and does nothing. To change the image, call the GraphQL API (`backboard.railway.com/graphql/v2`): first `serviceInstanceUpdate(serviceId, environmentId, input: {source: {image}})`, then `serviceInstanceDeployV2`.
- Take a fresh `pg_dump -Fc` first.
- If the new image changes the Debian release, glibc collations change too. After the switch:
  - `REINDEX` every index on a text/varchar column with the default collation (56 in production);
  - then run `ALTER DATABASE railway REFRESH COLLATION VERSION`.
- After a PostGIS version change, run `SELECT postgis_extensions_upgrade();`, then check that `postgis_full_version()` reports no "procs need upgrade" warning.
- Rewrites on the 5 GB volume: never run one statement that rewrites a large table. Batch by `ctid` range and `VACUUM` between batches (see the 2026-11-09 outage in `.claude/tasks.md`). `max_wal_size` is set to 256MB with `ALTER SYSTEM`, which keeps WAL from filling the volume.

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

- Railway Deno service uses `console.log` / `console.error`; inspect with `railway logs --service api`. Locally, `supabase start` serves the same handlers and shows their logs in the edge runtime container.
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
- Stored procedure `RAISE NOTICE`/`WARNING` output lands in the `postgis` service logs on Railway.

## Metrics

For MVP, Railway's service metrics (CPU, memory, volume) and Cloudflare's Worker analytics cover most of what we need. Supplement with:

### Sentry (errors + crashes)

- iOS: Sentry Cocoa SDK, capture uncaught exceptions and `NSError` from critical paths (sensor pipeline, upload, permissions)
- Backend: not installed yet. Plan: Sentry Deno SDK in `supabase/functions/server.ts`, capturing 5xx from every handler and scheduler job failures
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

Increment via `INSERT ... ON CONFLICT DO UPDATE SET value = value + 1` from the API handlers. Dashboard via a simple Metabase instance or saved `psql` queries:

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

Prefer fewer, louder alerts over noise. What exists today:

| Alert | Trigger | Channel | Action |
|---|---|---|---|
| API or database down | `health-monitor.yml`: `/health/deep` not `{"status":"ok","db":"reachable"}` after 3 tries | GitHub Actions failure email | Check `railway logs --service api`, the `postgis` service, Cloudflare Worker logs |
| iOS crash rate high | Sentry: crash-free-rate < 99% for 30+ minutes AND ≥ 20 sessions in the window (percentages are meaningless on small denominators) | Email | Hotfix evaluation |

Planned, not built yet (the backend and web have no Sentry today):

| Alert | Trigger | Channel | Action |
|---|---|---|---|
| Backend error rate high | > 10 errors/hour from backend AND ≥ 50 requests/hour (floor to suppress quiet-hour flaps) | Email to graham.mann14@gmail.com | Investigate within 4h |
| Database resources | Railway metrics: CPU > 80% for 15 min, volume > 80% full | Railway usage alert / email | Resize the service or volume |
| Ingestion latency spike | p95 `/upload-readings` > 5s for 10min AND ≥ 20 batches in the window | Email | Check DB, check API logs |
| Tile 5xx rate | > 1% 5xx for 10min AND ≥ 100 tile requests in the window | Email | Check API and Worker logs |
| Scheduler job failing | a daily job has not succeeded in 26 h | Email | Check `railway logs --service api` for the job name |

**Why the floors:** at MVP scale we'll have quiet hours with 0–2 requests. A single 500 becomes "100% error rate" and pages at 3 a.m. for nothing. Every rate-based alert needs a minimum-volume gate set just above typical off-peak traffic. Tune floors after the first week of production data.

Pager-style alerts (SMS/phone) are overkill for MVP. Email + checking in once a day is enough at TestFlight scale.

## Health Check Strategy

- `GET /health` is a lightweight unauthenticated liveness endpoint. It does not touch the DB and reports the deployed `commit`.
- `GET /health/deep` verifies DB connectivity and requires the public API key. On a Railway deployment it also reports each scheduler job (`scheduler.jobs.<name>.status`: `ok`, `pending`, `stale` or `failing`) and returns **503 `"status":"degraded"`** when any job is stale or failing, or the job table is unreadable. `pending` (the service has not been up long enough for the job's first run) does not degrade it on its own.
- `health-monitor.yml` calls `/health/deep` every 30 minutes. GitHub may delay scheduled runs at busy times and pauses schedules after 60 days without repository activity; add an external monitor (UptimeRobot or similar on `/health`, 5-minute interval) if that gap matters.
- Deploys wait for `/health` to report the new commit (`scripts/wait-for-deploy.sh`) before smoking.

## Deploy Playbook — Normal Day

1. PR CI green on the change (backend, web, iOS package, Android as the paths require)
2. Merge to `main`
3. Follow [Safe deploy order](#safe-deploy-order), or dispatch `deploy-production.yml` for the database + API part
4. Drive or open the map and check fresh data arrives
5. Tag the commit `prod-<date>`

## Deploy Playbook — Incident

**Step 1: Triage** — what's broken, for whom, how bad?

- DB down → Railway dashboard (`postgis` service logs, volume usage), status.railway.com; restore from backup if needed
- API down → `railway logs --service api`; roll back with `railway redeploy` of the previous deployment in the dashboard, or `git revert` + deploy
- Worker or tiles down → Cloudflare dashboard → Workers → `nsroadsense-api-proxy` logs; `npx wrangler rollback` in `cloudflare/api-proxy`
- Data corruption → **STOP WRITES** by scaling the `api` service to zero (or blocking `/upload-readings` in the Worker), then investigate

**Step 2: Rollback criteria**

Roll back if:
- Crash-free rate drops below 97% post-deploy
- Error rate > 100/hour post-deploy
- Any data-integrity issue (wrong segment assignment, lost readings)

**Rollback mechanism:**
- iOS: TestFlight users download the prior build (TestFlight auto-provides previous build)
- Backend: redeploy the previous Railway deployment, or git revert + deploy (migrations are additive only; never reverted without an explicit data-loss plan)
- Web: `npx wrangler rollback` in `apps/web`

**Step 3: Communicate** — post in the beta tester channel (Slack/Discord/GitHub) if tester-facing.

**Step 4: Postmortem** — document in `docs/incidents/YYYY-MM-DD-short-title.md`. Blameless, specific root cause, specific corrective actions. Mandatory within 48h.

## Backup & Disaster Recovery

Current state: no verified backups and no restore drill. These are owner actions in the Railway dashboard:

1. **Enable scheduled backups** on the `postgis` service volume (Service → Backups → schedule daily and weekly). Railway volume backups are snapshots, not WAL point-in-time recovery; check the retention your plan gives and write it here. If you need PITR, add WAL archiving (for example `wal-g` to R2) or a nightly `pg_dump` to R2.
2. **Take a manual backup before every deploy** that runs migrations (step 1 of the deploy order).
3. **Run a restore drill** once before external testers, then quarterly:
   - restore the latest backup into a new, temporary service (never over production);
   - point `psql` at it and run the [ledger fingerprint query](#migration-ledger-baseline), `SELECT count(*) FROM road_segments;`, `SELECT count(*) FROM readings;` and `SELECT max(version) FROM supabase_migrations.schema_migrations;`;
   - note how long the restore took, then delete the temporary service.
4. **Pin the PostGIS image.** Production runs `postgis/postgis:16-master`, a development snapshot that any database redeploy can replace with untested code. Pin it to a release tag on the same Postgres major:
   - first run `SELECT version(); SELECT postgis_full_version();` and take a backup;
   - in Railway → `postgis` service → Settings → Source, set the image to `postgis/postgis:16-3.7` (or the newest `16-3.x` tag);
   - after the redeploy, re-run both queries and `scripts/api-smoke.sh`. Keep the Postgres major at 16; a major upgrade needs `pg_upgrade` or dump/restore.
5. Monthly manual export of `road_segments` (static-ish) + `segment_aggregates` (derived) to cold storage (R2) as a defence against a provider outage.

`readings` raw data is NOT backed up externally — it is regeneratable from app uploads if the window is short. The 6-month retention cap bounds its size.

## Offline / Degraded Backend Behavior (iOS)

- If backend is unreachable, uploads queue locally (SwiftData)
- Tile requests fall back to Mapbox-cached tiles (previously viewed)
- Map UI shows an "offline" chip but remains functional
- Data collection continues normally

## Monitoring Dashboard

Not built yet. When it is, put one SQL dashboard (Metabase, or saved queries run with `psql` against the proxy URL) over `ops_metrics` and the public views:

1. Ingestion: batches/hour, accepted/rejected ratio, p50/p95 latency
2. Tile serving: requests/hour, cache hit ratio (Cloudflare analytics), p95 latency
3. Data: readings/day, unique contributors (weekly), segments-with-data count
4. Errors: 4xx/5xx counts, top error codes, top client app versions hitting errors
5. Coverage: % of HRM segments with ≥ 3 contributors

Link it in the project README so anyone on the team (future-you included) can check health in 30s.

## Web Dashboard Deployment (Cloudflare via OpenNext)

The public web dashboard in [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md) runs as the Cloudflare Worker `nsroadsense-web` on `nsroadsense.ca` and `www.nsroadsense.ca`, built with `@opennextjs/cloudflare` (`apps/web/wrangler.jsonc`, `apps/web/open-next.config.ts`). It reads the API through `https://api.nsroadsense.ca/functions/v1`.

### Deploy

```bash
cd apps/web
npm ci
npx tsc --noEmit && npm test
npm run build:cloudflare      # optional local check
npm run preview:cloudflare    # optional: serve the Worker build locally
npm run deploy:cloudflare     # build + deploy to Cloudflare
```

Before the first deploy, replace the placeholder KV namespace id in `wrangler.jsonc` (see step 7 of the deploy order).

### Web env vars

Expose only browser-safe values:

- `NEXT_PUBLIC_MAPBOX_TOKEN`
- `NEXT_PUBLIC_MAPBOX_STYLE_ID` or `NEXT_PUBLIC_MAPBOX_STYLE_URL`
- `NEXT_PUBLIC_API_BASE_URL`
- `NEXT_PUBLIC_ROADSENSE_ANON_KEY` (or the legacy `NEXT_PUBLIC_SUPABASE_ANON_KEY`)
- `NEXT_PUBLIC_APP_VERSION`

Rules:

- no service-role key or database URL in the web Worker
- no session-replay or ad-tech env vars
- if future municipal-auth features need privileged reads, keep those secrets server-only and out of `NEXT_PUBLIC_*`

### Web smoke test after deploy

1. open `/`
2. switch between quality, potholes, and coverage
3. select a segment and load the drawer
4. open `/municipality/halifax`
5. open `/reports/worst-roads`
6. verify `/privacy` and `/methodology`

### Web observability

Minimum viable web observability:

- Cloudflare Workers logs for `nsroadsense-web`
- Playwright smoke via the `web-browser` job of `web-ci.yml` (dispatch)
- backend endpoint logs still remain the source of truth for tiles and JSON read-path failures

Avoid in W1 web:

- product analytics suites
- session replay
- invasive browser telemetry

If frontend error monitoring is added later, keep it to error capture only. No DOM capture, no replay, no raw query-string logging if it can contain location-like search text.

## Operations Policy Decisions

- **No structured frontend analytics in MVP or initial web launch.** Privacy-first positioning and limited product scope do not justify PostHog, Mixpanel, or similar tools.
- **Keep Railway and Cloudflare logs at their default retention.** Extract durable signals into `ops_metrics` instead of paying for longer raw-log retention early.
- **Alert escalation stays simple.** Email-only during MVP and early beta; formal on-call rotation only if the project grows beyond a single maintainer.
