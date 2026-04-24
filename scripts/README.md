# Scripts

Operational and import scripts for backend maintenance live here.

Current B011 pipeline:

- `local-backend-up.sh` — starts local Supabase, revives the edge runtime if it died, and smoke-checks `/functions/v1/health` plus tiles
- `api-smoke.sh` — contract smoke for `/health`, `/stats`, and duplicate-safe `/upload-readings` against local or staging Edge Functions
- `seeded-e2e-smoke.sh` — seeded local/staging smoke that inserts a synthetic paved segment, uploads three matching batches, refreshes stats, and verifies segment detail plus tile emission
- `osm-import.sh` — downloads the Nova Scotia Geofabrik snapshot, runs `osm2pgsql`, segmentizes roads, tags municipalities/features, and applies the staged refresh
- `osm2pgsql-style.lua` — flex-output Lua config that keeps only drivable roads plus the node tags used for speed bumps and rail crossings
- `segmentize.sql` — slices imported OSM ways into ~50m rows in `road_segments_staging`
- `tag-municipalities.sql` — spatially joins staged segments to `ref.municipalities`
- `tag-features.sql` — folds nearby speed-bump and rail-crossing nodes onto staged segments

Prerequisites for `osm-import.sh`:

- `DATABASE_URL` pointing at the target Postgres/PostGIS database
- local `curl`, `osm2pgsql`, and `psql`
- populated `ref.municipalities` table in the target database

The script intentionally fails fast if `ref.municipalities` is missing or empty, because municipality names are part of the public read surface and should not silently degrade to `NULL`.

## Local backend bootstrap

Use `local-backend-up.sh` instead of raw `supabase start` for day-to-day iPhone testing:

```bash
./scripts/local-backend-up.sh
```

What it does:

- runs `supabase start`
- detects and restarts the local `supabase_edge_runtime_*` container if it is stopped
- verifies `GET /functions/v1/health`
- verifies the `tiles` function when `SUPABASE_ANON_KEY` is available from the environment or `ios/Config/RoadSenseNS.Local.secrets.xcconfig`
- prints the `.local` base URL the phone should use on home Wi-Fi

This exists because `supabase start` can report the stack as running even when the edge runtime container has died, which causes the app to show `503 name resolution failed` for tiles and other Edge Function calls.

## API smoke

`api-smoke.sh` verifies the public MVP read/write seam without needing the iOS app:

```bash
export FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1
export SUPABASE_ANON_KEY=...
./scripts/api-smoke.sh
```

What it validates:

- `GET /health` returns `{"status":"ok", ...}`
- `GET /stats` returns the documented public stats shape
- `POST /upload-readings` accepts a valid one-reading payload
- reposting the same payload returns `duplicate: true` with the original summary replayed

This is intentionally shape-focused, not acceptance-focused. On a fresh local DB with no imported `road_segments`, the upload may still be 200 with `rejected_reasons.no_segment_match = 1`, and that still counts as a passing smoke because the contract is functioning.

## Seeded end-to-end smoke

`seeded-e2e-smoke.sh` goes beyond shape validation and proves the backend loop works against a synthetic segment:

```bash
export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
export FUNCTIONS_BASE_URL=http://127.0.0.1:54321/functions/v1
export SUPABASE_ANON_KEY=...
./scripts/seeded-e2e-smoke.sh
```

What it does:

- inserts a synthetic paved segment into `road_segments`
- uploads three one-reading batches from distinct device tokens so `unique_contributors = 3`
- verifies `segment_aggregates` rolls up to `confidence = medium`
- refreshes `public_stats_mv`
- verifies `GET /segments/{id}`, `GET /stats`, and `GET /tiles/{z}/{x}/{y}.mvt`

This is intended for local/staging verification only. It writes synthetic rows into the target database and does not clean them back out after success.
