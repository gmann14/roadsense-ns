# Scripts

Operational and import scripts for backend maintenance live here.

Current B011 pipeline:

- `api-smoke.sh` — contract smoke for `/health`, `/stats`, and duplicate-safe `/upload-readings` against local or staging Edge Functions
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
