# RoadSense NS

iOS and Android apps that passively collect road quality data from the phone's accelerometer while you drive. The data is aggregated into a public map of road roughness scores and pothole locations at [nsroadsense.ca](https://nsroadsense.ca).

**Status:** Beta hardening. The apps, the Railway-hosted backend and the Cloudflare web explorer are live.

Start here:

- [docs/product-spec.md](docs/product-spec.md) — product scope and goals
- [docs/implementation/README.md](docs/implementation/README.md) — implementation spec index
- [docs/implementation/05-deployment-and-observability.md](docs/implementation/05-deployment-and-observability.md) — how production is deployed, monitored and backed up

## Architecture

```
iOS / Android app ──┐
                    ├─► Cloudflare Worker (cloudflare/api-proxy)      api.nsroadsense.ca, tiles.nsroadsense.ca
Web (apps/web) ─────┘        │  adds the origin secret and client IP
                             ▼
                    Railway "api" service (Dockerfile → supabase/functions/server.ts, Deno)
                             │  in-process scheduler for the jobs pg_cron would run
                             ▼
                    Railway "postgis" service (Postgres 16 + PostGIS)
                    spatial matching, aggregates and vector tiles (ST_AsMVT) in SQL
```

- Clients upload point readings; the server assigns them to road segments. Privacy zones are filtered on the device.
- The web dashboard is Next.js on Cloudflare Workers via OpenNext.
- Local development uses `supabase start`, which runs the same migrations and handlers.

## Repo layout

- `ios/` — Xcode project (XcodeGen), Swift app, Swift package tests
- `android/` — Kotlin app (Gradle)
- `supabase/` — migrations, Deno handlers (`functions/`), pgTAP tests (`tests/`)
- `apps/web/` — Next.js public dashboard
- `cloudflare/api-proxy/` — Worker in front of the Railway API
- `scripts/` — migration, import, smoke and report scripts ([scripts/README.md](scripts/README.md))
- `.github/workflows/` — PR CI, release and deploy workflows

## Tests

| Area | Command | CI |
|---|---|---|
| API handlers | `deno test -A $(find supabase/functions -name '*_test.ts')` | `backend-ci.yml` |
| Cloudflare Worker | `deno test -A cloudflare/api-proxy` | `backend-ci.yml` |
| Database (pgTAP) | `supabase start && supabase db reset && supabase test db` | `backend-ci.yml` |
| Scripts | `scripts/tests/run.sh` (bash, fake `psql`) | `backend-ci.yml` |
| Smoke against a running API | `FUNCTIONS_BASE_URL=... PUBLIC_API_KEY=... scripts/api-smoke.sh` | `backend-ci.yml`, deploys |
| Web | `cd apps/web && npm ci && npx tsc --noEmit && npm test && npm run build` | `web-ci.yml` |
| iOS package | `cd ios && xcrun swift test` | `ios-ci.yml` |
| Android | `cd android && ./gradlew test` | `android-ci.yml` |
| Workflows | `actionlint .github/workflows/*.yml` | — |

PR CI runs on pull requests and pushes to `main`, filtered by path.

## Deploying

Production is deployed by hand, in a fixed order: database snapshot, migrations (`supabase db push`), Cloudflare Worker (`wrangler deploy`), API (`railway up`), smoke, web (`npm run deploy:cloudflare`), then the mobile builds. The commands, the `deploy-production.yml` workflow and the required secrets are in [docs/implementation/05-deployment-and-observability.md](docs/implementation/05-deployment-and-observability.md#production-deploy).
