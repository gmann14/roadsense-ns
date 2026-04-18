# Scripts

Operational and import scripts for backend maintenance live here.

Current B011 pipeline:

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
