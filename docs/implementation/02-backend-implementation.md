# 02 — Backend Implementation

*Last updated: 2026-04-17*

Covers: Supabase project setup, schema migrations, OSM import, ingestion Edge Function, stored procedures, vector tile endpoint, and nightly aggregation.

Prereqs from [product-spec.md](../product-spec.md) that we don't re-derive: client uploads POINTs; server owns road network and segment assignment; PostGIS + stored procedures; vector tiles via `ST_AsMVT`; monthly partitioning from day one.

## Supabase Project Setup

### Plan

- **Pro tier, $25/month**, `us-east-1` region. Free tier's 500MB DB limit is hit within 2–3 months.
- **Compute add-on:** stay on Small (1GB RAM) for MVP. Upgrade to Medium if spatial queries pin CPU during dogfood.
- **Backups:** daily point-in-time recovery is included on Pro — enable it.
- **Connection pooling:** enable Transaction-mode pooler for Edge Function → Postgres calls (avoids per-request connection setup).

### Environments

| Env | Purpose | Project |
|---|---|---|
| `local` | Dev machines via `supabase start` (Docker) | — |
| `preview` | Per-PR branch via Supabase branching | automatic |
| `staging` | Persistent staging, populated with synthetic data | `roadsense-staging` |
| `prod` | Real user data | `roadsense-prod` |

`local` and `preview` are for every engineer; `staging` and `prod` are two distinct Supabase projects. Don't mingle schemas across environments via RLS tricks — keep them physically separate.

### Extensions

Enable via `supabase/migrations`:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- fuzzy road name search (Phase 2)
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid, digest for SHA-256
CREATE EXTENSION IF NOT EXISTS pg_cron;       -- nightly aggregate job
```

Do NOT enable `postgis_topology` or `postgis_raster` — we don't need them, and they add ~100MB.

## Schema Migrations

Structured under `supabase/migrations/YYYYMMDDHHMMSS_description.sql`. All migrations idempotent (use `IF NOT EXISTS` / `IF EXISTS`).

### Migration 001 — Extensions & enums

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE TYPE roughness_category AS ENUM (
    'smooth', 'fair', 'rough', 'very_rough', 'unpaved', 'unscored'
);
CREATE TYPE confidence_level AS ENUM ('low', 'medium', 'high');
CREATE TYPE pothole_status AS ENUM ('active', 'expired', 'resolved');
CREATE TYPE trend_direction AS ENUM ('improving', 'stable', 'worsening');
```

### Migration 002 — `road_segments`

```sql
CREATE TABLE road_segments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    osm_way_id BIGINT NOT NULL,
    segment_index INTEGER NOT NULL,
    geom GEOMETRY(LINESTRING, 4326) NOT NULL,
    length_m NUMERIC(8,1) NOT NULL,
    road_name TEXT,
    road_type TEXT NOT NULL,          -- motorway, primary, secondary, tertiary, residential, service, track, ...
    surface_type TEXT,                -- paved, asphalt, concrete, gravel, unpaved, ...
    municipality TEXT,
    has_speed_bump BOOLEAN DEFAULT FALSE,
    has_rail_crossing BOOLEAN DEFAULT FALSE,
    is_parking_aisle BOOLEAN DEFAULT FALSE,
    bearing_degrees NUMERIC(5,2),     -- segment's forward direction (0-360)
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(osm_way_id, segment_index)
);

CREATE INDEX idx_segments_geom ON road_segments USING GIST (geom);

-- Geography index for KNN / ST_DWithin in meter space. The geometry GiST index above
-- cannot answer `ORDER BY rs.geom::geography <-> t.geom::geography` — the cast
-- changes the operator class and the planner falls back to a sequential scan on
-- 400k+ rows. Without this second index, ingest_reading_batch KNN is O(segments)
-- per reading. Postgres supports functional GiST indexes on expressions.
CREATE INDEX idx_segments_geog ON road_segments USING GIST ((geom::geography));

CREATE INDEX idx_segments_municipality ON road_segments (municipality);
CREATE INDEX idx_segments_way ON road_segments (osm_way_id);
CREATE INDEX idx_segments_type ON road_segments (road_type);
```

### Migration 003 — `segment_aggregates`

```sql
CREATE TABLE segment_aggregates (
    segment_id UUID PRIMARY KEY REFERENCES road_segments(id) ON DELETE CASCADE,
    avg_roughness_score NUMERIC(5,3),
    roughness_category roughness_category NOT NULL DEFAULT 'unscored',
    total_readings INTEGER NOT NULL DEFAULT 0,
    unique_contributors INTEGER NOT NULL DEFAULT 0,
    confidence confidence_level NOT NULL DEFAULT 'low',
    last_reading_at TIMESTAMPTZ,
    pothole_count INTEGER NOT NULL DEFAULT 0,
    trend trend_direction NOT NULL DEFAULT 'stable',
    score_last_30d NUMERIC(5,3),
    score_30_60d NUMERIC(5,3),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_aggregates_score ON segment_aggregates (avg_roughness_score DESC);
CREATE INDEX idx_aggregates_category ON segment_aggregates (roughness_category);
CREATE INDEX idx_aggregates_confidence ON segment_aggregates (confidence);
```

### Migration 004 — `readings` (partitioned)

```sql
CREATE TABLE readings (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    segment_id UUID,                              -- nullable: pre-match or no-match dropped
    batch_id UUID NOT NULL,
    device_token_hash BYTEA NOT NULL,             -- SHA-256 of client-supplied token
    roughness_rms NUMERIC(5,3) NOT NULL,
    speed_kmh NUMERIC(5,1) NOT NULL,
    heading_degrees NUMERIC(5,1),
    gps_accuracy_m NUMERIC(5,1),
    is_pothole BOOLEAN NOT NULL DEFAULT FALSE,
    pothole_magnitude NUMERIC(5,2),
    location GEOMETRY(POINT, 4326) NOT NULL,      -- kept for nightly rematch
    recorded_at TIMESTAMPTZ NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (recorded_at, id)                 -- includes partition key, enables FK via unique
) PARTITION BY RANGE (recorded_at);

-- Initial 3 months of partitions to boot
CREATE TABLE readings_2026_04 PARTITION OF readings
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE readings_2026_05 PARTITION OF readings
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE readings_2026_06 PARTITION OF readings
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

-- Indexes on each partition (cron job creates these for future partitions too)
CREATE INDEX ON readings_2026_04 USING GIST (location);
CREATE INDEX ON readings_2026_04 (segment_id);
CREATE INDEX ON readings_2026_04 (batch_id);
CREATE INDEX ON readings_2026_04 (device_token_hash);
-- (repeat for each partition)
```

**Partition creation automation:** See Migration 010 below — a `pg_cron` job creates next month's partition on the 25th of each month.

**Retention:** Drop partitions > 6 months old (also in cron job). Aggregates are preserved indefinitely; raw readings are not.

### Migration 005 — `pothole_reports`

```sql
CREATE TABLE pothole_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    segment_id UUID REFERENCES road_segments(id) ON DELETE SET NULL,
    geom GEOMETRY(POINT, 4326) NOT NULL,
    magnitude NUMERIC(4,2) NOT NULL,
    first_reported_at TIMESTAMPTZ NOT NULL,
    last_confirmed_at TIMESTAMPTZ NOT NULL,
    confirmation_count INTEGER NOT NULL DEFAULT 1,
    unique_reporters INTEGER NOT NULL DEFAULT 1,
    status pothole_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_potholes_geom ON pothole_reports USING GIST (geom);
CREATE INDEX idx_potholes_segment ON pothole_reports (segment_id);
CREATE INDEX idx_potholes_status ON pothole_reports (status);
```

### Migration 006 — `processed_batches` (idempotency)

```sql
CREATE TABLE processed_batches (
    batch_id UUID PRIMARY KEY,
    device_token_hash BYTEA NOT NULL,
    reading_count INTEGER NOT NULL,
    accepted_count INTEGER NOT NULL,
    rejected_count INTEGER NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_sent_at TIMESTAMPTZ NOT NULL,
    client_app_version TEXT,
    client_os_version TEXT
);

CREATE INDEX idx_batches_device ON processed_batches (device_token_hash, processed_at DESC);
CREATE INDEX idx_batches_processed_at ON processed_batches (processed_at DESC);
```

Purpose: duplicate batch detection, rate limit bookkeeping, audit trail.

### Migration 007 — `rate_limits`

Fixed-bucket counters. A sliding window needs a log of individual request timestamps, which is overkill — fixed buckets have a 2× worst-case burst (request 50 at end of bucket N, request 1 at start of bucket N+1) that's acceptable here.

```sql
CREATE TABLE rate_limits (
    key TEXT NOT NULL,                     -- e.g., "device:<hash>" or "ip:<ip>"
    bucket_start TIMESTAMPTZ NOT NULL,     -- truncated to the bucket boundary
    request_count INTEGER NOT NULL DEFAULT 0,   -- not named "count" to avoid shadowing the aggregate
    PRIMARY KEY (key, bucket_start)
);

CREATE INDEX idx_rate_limits_bucket_start ON rate_limits (bucket_start);
```

Device bucket size = 24h (`date_trunc('day', now())`), IP bucket size = 1h (`date_trunc('hour', now())`). Checked and incremented atomically:

```sql
CREATE OR REPLACE FUNCTION check_and_bump_rate_limit(
    p_key TEXT,
    p_bucket_start TIMESTAMPTZ,
    p_limit INTEGER
) RETURNS BOOLEAN               -- TRUE if allowed, FALSE if limit hit
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    INSERT INTO rate_limits AS rl (key, bucket_start, request_count)
    VALUES (p_key, p_bucket_start, 1)
    ON CONFLICT (key, bucket_start)
    DO UPDATE SET request_count = rl.request_count + 1
    RETURNING rl.request_count INTO v_count;

    RETURN v_count <= p_limit;
END;
$$;

-- Only the service role can bump rate limits (Edge Function calls it via SERVICE_ROLE_KEY).
REVOKE EXECUTE ON FUNCTION check_and_bump_rate_limit(TEXT, TIMESTAMPTZ, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_and_bump_rate_limit(TEXT, TIMESTAMPTZ, INTEGER) TO service_role;
```

A daily cron job (`cron.schedule` — see Migration 010) deletes buckets older than 7 days to keep the table small. Could move to Upstash/Redis later if this becomes a bottleneck; at MVP scale (< 1000 buckets/day), Postgres is fine.

### Migration 008 — RLS & permissions

```sql
-- Only the service role writes; anon role reads aggregates + tiles only
ALTER TABLE road_segments ENABLE ROW LEVEL SECURITY;
ALTER TABLE segment_aggregates ENABLE ROW LEVEL SECURITY;
ALTER TABLE readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pothole_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;

-- Anon can read aggregates and (approved) potholes
CREATE POLICY "anon read aggregates"
    ON segment_aggregates FOR SELECT TO anon USING (true);
CREATE POLICY "anon read road_segments"
    ON road_segments FOR SELECT TO anon USING (true);
CREATE POLICY "anon read potholes"
    ON pothole_reports FOR SELECT TO anon USING (status = 'active');

-- Nothing else anon can touch. readings, processed_batches, rate_limits are service-role only.
```

The iOS client uses the **anon key** for tile fetches and segment detail reads. It uses a separate **scoped-insert** flow via the Edge Function (which holds a service role key) for uploads. The client NEVER gets a service role key.

### Migration 009 — Stored procedures

See §Ingestion Pipeline and §Nightly Recompute below. Each becomes its own migration file.

### Migration 010 — Partition management functions

These are referenced by the cron jobs in Migration 011. Both are idempotent (safe to re-run) and log a NOTICE on each action so cron job runs are observable in `cron.job_run_details`.

```sql
-- Create next-month partition plus its indexes. Idempotent.
CREATE OR REPLACE FUNCTION create_next_readings_partition()
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_next_month DATE := date_trunc('month', now() + INTERVAL '1 month')::DATE;
    v_following  DATE := v_next_month + INTERVAL '1 month';
    v_part_name  TEXT := format('readings_%s', to_char(v_next_month, 'YYYY_MM'));
BEGIN
    EXECUTE format(
        $f$CREATE TABLE IF NOT EXISTS %I PARTITION OF readings
           FOR VALUES FROM (%L) TO (%L)$f$,
        v_part_name, v_next_month, v_following
    );

    EXECUTE format($f$CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (location)$f$,
                   v_part_name || '_location_gist', v_part_name);
    EXECUTE format($f$CREATE INDEX IF NOT EXISTS %I ON %I (segment_id)$f$,
                   v_part_name || '_segment', v_part_name);
    EXECUTE format($f$CREATE INDEX IF NOT EXISTS %I ON %I (batch_id)$f$,
                   v_part_name || '_batch', v_part_name);
    EXECUTE format($f$CREATE INDEX IF NOT EXISTS %I ON %I (device_token_hash)$f$,
                   v_part_name || '_device', v_part_name);

    RAISE NOTICE 'create_next_readings_partition: ensured %', v_part_name;
END;
$$;

-- Drop partitions fully older than 6 months. Idempotent.
--
-- We parse the upper bound out of the partition expression and compare
-- numerically. An earlier version regex-matched exactly one cutoff date,
-- so if cron ever missed a month (Supabase maintenance, DB paused) older
-- partitions accumulated forever. The substring-then-compare below drops
-- ALL partitions whose upper bound is <= the cutoff.
CREATE OR REPLACE FUNCTION drop_old_readings_partitions()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_cutoff DATE := date_trunc('month', now() - INTERVAL '6 months')::DATE;
    v_part   RECORD;
    v_upper  DATE;
BEGIN
    FOR v_part IN
        SELECT inhrelid::regclass AS part_name,
               pg_get_expr(relpartbound, inhrelid) AS bound
        FROM pg_inherits
        JOIN pg_class ON pg_class.oid = inhrelid
        WHERE inhparent = 'readings'::regclass
    LOOP
        -- Bound looks like: FOR VALUES FROM ('2025-10-01') TO ('2025-11-01')
        -- Extract the upper-bound date between `TO ('` and the next `'`.
        v_upper := NULLIF(
            substring(v_part.bound FROM $re$TO \('(\d{4}-\d{2}-\d{2})'\)$re$),
            ''
        )::DATE;

        IF v_upper IS NOT NULL AND v_upper <= v_cutoff THEN
            EXECUTE format('DROP TABLE IF EXISTS %s', v_part.part_name);
            RAISE NOTICE 'drop_old_readings_partitions: dropped % (upper=%)',
                         v_part.part_name, v_upper;
        END IF;
    END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_next_readings_partition() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION drop_old_readings_partitions() TO service_role;
GRANT EXECUTE ON FUNCTION create_next_readings_partition() TO service_role;
```

### Migration 011 — Cron jobs

All jobs scheduled in UTC. Halifax is UTC-4 in winter (AST) / UTC-3 summer (ADT); 03:00 UTC ≈ 23:00 AST / 00:00 ADT — late-night locally year-round. Spread across 45 min so they don't stack CPU on the Small instance.

```sql
-- Create next month's partition on the 25th of each month (gives 5+ days of slack)
SELECT cron.schedule(
    'create-next-readings-partition',
    '0 3 25 * *',
    $$SELECT create_next_readings_partition()$$
);

-- Drop partitions older than 6 months on the 1st of each month
SELECT cron.schedule(
    'drop-old-readings-partitions',
    '30 3 1 * *',
    $$SELECT drop_old_readings_partitions()$$
);

-- Nightly aggregate recompute. Run late locally (~11pm–midnight Halifax time year-round).
SELECT cron.schedule(
    'nightly-aggregate-recompute',
    '15 3 * * *',
    $$SELECT nightly_recompute_aggregates()$$
);

-- Pothole expiry (cheap, 15 min after recompute starts)
SELECT cron.schedule(
    'pothole-expiry',
    '0 4 * * *',
    $$SELECT expire_unconfirmed_potholes()$$
);

-- Rate limit bucket garbage collection (keep 7 days of history for debugging)
SELECT cron.schedule(
    'rate-limit-gc',
    '15 4 * * *',
    $$DELETE FROM rate_limits WHERE bucket_start < now() - INTERVAL '7 days'$$
);
```

Beyond MVP: also pre-create three months ahead (run on the 1st) so a single cron failure doesn't cascade.

## OSM Import Pipeline

Run as a one-off script (not a migration) — the OSM data is too large to shove into migrations, and we refresh it quarterly.

### Script: `scripts/osm-import.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Prereqs: osm2pgsql, ogr2ogr (GDAL), psql
# Targets the DB specified via $DATABASE_URL

SNAPSHOT_URL="https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf"
WORKDIR="${WORKDIR:-/tmp/roadsense-osm}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "→ Downloading OSM snapshot"
curl -fsSL -o ns.osm.pbf "$SNAPSHOT_URL"

echo "→ Importing via osm2pgsql (lua style for selective tags)"
osm2pgsql \
    --database="$DATABASE_URL" \
    --slim --drop \
    --output=flex \
    --style=scripts/osm2pgsql-style.lua \
    ns.osm.pbf

# At this point we have:
#   osm_ways (raw)
#   osm_nodes (raw)
# in the `osm` schema

echo "→ Segmentizing ways into 50m pieces"
psql "$DATABASE_URL" -f scripts/segmentize.sql

echo "→ Tagging municipalities via StatCan boundaries"
# statscan boundaries pre-imported into ref.municipalities (one-time, outside this script)
psql "$DATABASE_URL" -f scripts/tag-municipalities.sql

echo "→ Tagging features (speed bumps, rail crossings, surface)"
psql "$DATABASE_URL" -f scripts/tag-features.sql

echo "→ Done. Segment count:"
psql "$DATABASE_URL" -c "SELECT count(*) FROM road_segments;"
```

### Lua style file (`scripts/osm2pgsql-style.lua`)

Picks only the tags we care about. Avoid ingesting every amenity and POI.

```lua
-- Simplified sketch; real file handles tag projection for flex output
local tables = {}

tables.ways = osm2pgsql.define_way_table('osm_ways', {
    { column = 'highway', type = 'text' },
    { column = 'name', type = 'text' },
    { column = 'surface', type = 'text' },
    { column = 'service', type = 'text' },
    { column = 'access', type = 'text' },
    { column = 'traffic_calming', type = 'text' },
    { column = 'railway', type = 'text' },
    { column = 'geom', type = 'linestring', projection = 4326 },
})

function osm2pgsql.process_way(object)
    local hw = object.tags.highway
    if not hw then return end
    -- Keep drivable roads only; drop paths/footways/cycleways
    local keep = { motorway=true, trunk=true, primary=true, secondary=true,
                   tertiary=true, residential=true, unclassified=true,
                   service=true, motorway_link=true, trunk_link=true,
                   primary_link=true, secondary_link=true, tertiary_link=true,
                   living_street=true, track=true }
    if not keep[hw] then return end
    tables.ways:insert({ highway=hw, name=object.tags.name,
                         surface=object.tags.surface,
                         service=object.tags.service,
                         access=object.tags.access,
                         traffic_calming=object.tags['traffic_calming'],
                         railway=object.tags.railway,
                         geom=object:as_linestring() })
end
```

### `scripts/segmentize.sql`

Length is computed once per way via a CTE; segment fractions are derived from a single `generate_series` scalar. EPSG:3857 is used as a good-enough meter projection for NS (44–47°N); UTM 20N (EPSG:32620) is marginally more accurate if precision ever matters.

```sql
-- Produce road_segments by slicing each OSM way into 50m pieces
WITH ways_m AS (
    SELECT
        w.osm_id         AS osm_way_id,
        w.name           AS road_name,
        w.highway        AS road_type,
        w.surface        AS surface_type,
        ST_Transform(w.geom, 3857) AS geom_m,
        ST_Length(ST_Transform(w.geom, 3857)) AS len_m
    FROM osm.osm_ways w
    WHERE w.highway IS NOT NULL
),
cut AS (
    SELECT
        wm.osm_way_id,
        wm.road_name,
        wm.road_type,
        wm.surface_type,
        wm.len_m,
        s              AS idx,                        -- 1-based series
        (s - 1) * 50.0 / wm.len_m       AS frac_start,
        LEAST(s * 50.0 / wm.len_m, 1.0) AS frac_end,
        ST_LineSubstring(wm.geom_m,
            (s - 1) * 50.0 / wm.len_m,
            LEAST(s * 50.0 / wm.len_m, 1.0)) AS seg_m
    FROM ways_m wm,
         LATERAL generate_series(1, CEIL(wm.len_m / 50.0)::INTEGER) AS s
)
INSERT INTO road_segments (osm_way_id, segment_index, geom, length_m, road_name,
                           road_type, surface_type, bearing_degrees)
SELECT
    c.osm_way_id,
    c.idx - 1                                             AS segment_index,   -- 0-indexed
    ST_Transform(c.seg_m, 4326)                           AS geom,
    LEAST(50.0, c.len_m - (c.idx - 1) * 50.0)::NUMERIC(8,1) AS length_m,
    c.road_name,
    c.road_type,
    c.surface_type,
    degrees(ST_Azimuth(ST_StartPoint(c.seg_m), ST_EndPoint(c.seg_m)))::NUMERIC(5,2) AS bearing_degrees
FROM cut c
WHERE ST_Length(c.seg_m) > 1  -- drop degenerate tail pieces < 1m
ON CONFLICT (osm_way_id, segment_index) DO UPDATE
    SET geom            = EXCLUDED.geom,
        length_m        = EXCLUDED.length_m,
        road_name       = EXCLUDED.road_name,
        bearing_degrees = EXCLUDED.bearing_degrees,
        updated_at      = now();
```

**Performance:** For NS (~50k OSM ways), this takes ~5 minutes on Supabase Pro small instance. Run during low-traffic window. Expect ~300k–600k segments total. If it slows with growth, add `CREATE INDEX ON osm.osm_ways USING GIST (geom);` and run in batches of 5k ways.

**Generate_series gotcha:** the series returns a scalar `integer`, not an array. Earlier drafts of this script referenced `gs.path[1]` — that's `generate_subscripts`, a different function. The corrected version above uses the scalar `s` directly.

### `scripts/tag-municipalities.sql`

```sql
-- Spatial join each segment with StatCan CSD boundaries
UPDATE road_segments rs
SET municipality = m.csd_name
FROM ref.municipalities m
WHERE ST_Intersects(rs.geom, m.geom)
  AND rs.municipality IS NULL;

-- Simple centroid tiebreak for segments crossing boundaries
UPDATE road_segments rs
SET municipality = m.csd_name
FROM ref.municipalities m
WHERE rs.municipality IS NULL
  AND ST_Contains(m.geom, ST_Centroid(rs.geom));
```

**Data source:** Statistics Canada Census Subdivision boundaries (CSD), downloaded from StatCan as ESRI shapefile, imported once via `ogr2ogr` into `ref.municipalities`.

### `scripts/tag-features.sql`

```sql
-- Speed bumps
UPDATE road_segments rs
SET has_speed_bump = true
WHERE EXISTS (
    SELECT 1 FROM osm.osm_nodes n
    WHERE n.tags->>'traffic_calming' = 'bump'
      AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
);

-- Rail crossings
UPDATE road_segments rs
SET has_rail_crossing = true
WHERE EXISTS (
    SELECT 1 FROM osm.osm_nodes n
    WHERE n.tags->>'railway' = 'level_crossing'
      AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
);

-- Parking aisles
UPDATE road_segments rs
SET is_parking_aisle = true
WHERE road_type = 'service' AND surface_type = 'parking_aisle';
-- (plus segments inside amenity=parking polygons)

-- Mark unpaved
UPDATE segment_aggregates sa
SET roughness_category = 'unpaved'
FROM road_segments rs
WHERE sa.segment_id = rs.id
  AND rs.surface_type IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand');
```

## Ingestion Pipeline

### Edge Function: `POST /functions/v1/upload-readings`

Thin validation + auth + rate limit layer. Calls stored procedure for the spatial work.

```typescript
// supabase/functions/upload-readings/index.ts — sketch
import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const NS_BBOX = { minLng: -66.5, minLat: 43.3, maxLng: -59.5, maxLat: 47.1 }

serve(async (req) => {
    if (req.method !== "POST") return new Response(null, { status: 405 })

    const payload = await req.json() as UploadPayload
    const validation = validate(payload)
    if (!validation.ok) return jsonResponse({ error: validation.reason }, 400)

    // Hash device token server-side (client sends cleartext; hash with a
    // server-side pepper to make rainbow-tabling harder)
    const tokenHash = await sha256(payload.device_token + Deno.env.get("TOKEN_PEPPER")!)

    // Rate limit check (device + IP).
    // Supabase Edge Functions run on Deno Deploy; the real client IP is in x-forwarded-for
    // (first comma-separated entry). `cf-connecting-ip` is Cloudflare-specific and is not
    // reliably set on all Supabase deploys — using it alone would collapse all traffic
    // into a single "unknown" bucket and instantly trip the global limit.
    const fwd = req.headers.get("x-forwarded-for") ?? ""
    const ip = fwd.split(",")[0]?.trim()
        || req.headers.get("x-real-ip")
        || req.headers.get("cf-connecting-ip")
        || "unknown"
    // checkRateLimit returns { ok, retryAfterSeconds } — caller uses the latter to
    // populate both the JSON body AND the HTTP `Retry-After` header that the API
    // contract promises (§03 /upload-readings 429 response). Missing the header
    // causes iOS client to fall back to a 60s retry which is too aggressive.
    const rate = await checkRateLimit(tokenHash, ip)
    if (!rate.ok) {
        return jsonResponse(
            {
                error: "rate_limited",
                message: "Device or IP exceeded rate limit.",
                retry_after_s: rate.retryAfterSeconds,
            },
            429,
            { "Retry-After": String(rate.retryAfterSeconds) },
        )
    }

    // Dispatch to stored procedure
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    )
    const { data, error } = await supabase.rpc("ingest_reading_batch", {
        p_batch_id: payload.batch_id,
        p_device_token_hash: tokenHash,
        p_readings: payload.readings,
        p_client_sent_at: payload.client_sent_at,
        p_client_app_version: payload.client_app_version,
        p_client_os_version: payload.client_os_version,
    })

    if (error) {
        console.error("ingest_reading_batch failed", { batch_id: payload.batch_id, error })
        return jsonResponse({ error: "processing_failed" }, 502)
    }

    return jsonResponse({
        batch_id: payload.batch_id,
        accepted: data.accepted,
        rejected: data.rejected,
        duplicate: data.duplicate,
        rejected_reasons: data.rejected_reasons ?? {},
    }, 200)
})

// Signature: jsonResponse(body: unknown, status: number, extraHeaders?: Record<string, string>)
// — the rate-limited path above passes { "Retry-After": "..." } through this helper. Keep the
// helper definition alongside this file; the extraHeaders param is what makes the 429 contract
// (§03) actually pass its contract test.
```

### Validation

- `payload.readings.length <= 1000`
- Each reading: `lat` ∈ NS bbox, `lng` ∈ NS bbox, `speed_kmh` ∈ [0, 200], `roughness_rms` ∈ [0, 15], `gps_accuracy_m` ∈ [0, 100], `recorded_at` within last 7 days
- Reject entire batch if > 5% of readings fail validation (client bug signal)
- Reject if `batch_id` isn't a valid UUIDv4

### Rate Limits (enforced in Edge Function)

- Per device token hash: 50 batches / 24h fixed bucket (calendar day UTC)
- Per IP: 10 batches / 1h fixed bucket (calendar hour UTC)
- Implemented via `check_and_bump_rate_limit(key, bucket_start, limit)` — atomic `INSERT ... ON CONFLICT UPDATE`
- Worst case at bucket boundary: 2× the nominal limit — acceptable; a sliding-window log would be 10× the cost for a small improvement
- On limit hit: return 429 with `Retry-After` header set to seconds-until-next-bucket

```typescript
// Edge Function helper — the piece the top-level handler calls.
async function checkRateLimit(
    tokenHash: string,
    ip: string,
): Promise<{ ok: boolean; retryAfterSeconds: number }> {
    const now = new Date()
    const dayBucket  = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
    const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()))

    // Device bucket: 50/day
    const deviceOk = await sb.rpc("check_and_bump_rate_limit", {
        p_key: `dev:${tokenHash}`, p_bucket_start: dayBucket.toISOString(), p_limit: 50,
    })
    if (!deviceOk.data) {
        const secondsUntilNextDay = Math.ceil((dayBucket.getTime() + 86400000 - now.getTime()) / 1000)
        return { ok: false, retryAfterSeconds: secondsUntilNextDay }
    }

    // IP bucket: 10/hour
    const ipOk = await sb.rpc("check_and_bump_rate_limit", {
        p_key: `ip:${ip}`, p_bucket_start: hourBucket.toISOString(), p_limit: 10,
    })
    if (!ipOk.data) {
        const secondsUntilNextHour = Math.ceil((hourBucket.getTime() + 3600000 - now.getTime()) / 1000)
        return { ok: false, retryAfterSeconds: secondsUntilNextHour }
    }

    return { ok: true, retryAfterSeconds: 0 }
}
```

### Stored Procedure: `ingest_reading_batch`

```sql
CREATE OR REPLACE FUNCTION ingest_reading_batch(
    p_batch_id UUID,
    p_device_token_hash BYTEA,
    p_readings JSONB,              -- array of reading objects
    p_client_sent_at TIMESTAMPTZ,
    p_client_app_version TEXT,
    p_client_os_version TEXT
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
-- Lock the search path so a malicious schema can't shadow tables at SECURITY DEFINER time.
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_accepted INT := 0;
    v_rejected INT := 0;
    v_duplicate BOOLEAN := FALSE;
    v_rejected_reasons JSON := '{}'::JSON;
BEGIN
    -- Idempotency: if batch already processed, return prior result
    IF EXISTS (SELECT 1 FROM processed_batches WHERE batch_id = p_batch_id) THEN
        SELECT reading_count - rejected_count, rejected_count
        INTO v_accepted, v_rejected
        FROM processed_batches WHERE batch_id = p_batch_id;
        RETURN json_build_object(
            'accepted', v_accepted,
            'rejected', v_rejected,
            'duplicate', TRUE,
            'rejected_reasons', '{}'::JSON   -- not re-derivable from persisted state
        );
    END IF;

    -- Temp tables are session-scoped in Postgres. If the Supabase pooler reuses a backend
    -- for a second RPC call, ON COMMIT DROP only fires at end of the enclosing transaction,
    -- and leftovers from a prior call can collide. Drop defensively, then recreate.
    DROP TABLE IF EXISTS tmp_batch_readings;
    DROP TABLE IF EXISTS tmp_matched;

    -- Stage readings into a temp table with pre-computed geometry
    CREATE TEMP TABLE tmp_batch_readings ON COMMIT DROP AS
    SELECT
        (r->>'lat')::NUMERIC AS lat,
        (r->>'lng')::NUMERIC AS lng,
        (r->>'roughness_rms')::NUMERIC AS roughness_rms,
        (r->>'speed_kmh')::NUMERIC AS speed_kmh,
        (r->>'heading')::NUMERIC AS heading,
        (r->>'gps_accuracy_m')::NUMERIC AS gps_accuracy_m,
        COALESCE((r->>'is_pothole')::BOOLEAN, FALSE) AS is_pothole,
        (r->>'pothole_magnitude')::NUMERIC AS pothole_magnitude,
        (r->>'recorded_at')::TIMESTAMPTZ AS recorded_at,
        ST_SetSRID(ST_MakePoint((r->>'lng')::NUMERIC, (r->>'lat')::NUMERIC), 4326) AS geom
    FROM jsonb_array_elements(p_readings) AS r;

    -- Match each reading to a SINGLE best segment using KNN + heading + distance filters.
    -- The lateral takes 3 nearest candidates, filters by heading, and picks the closest
    -- surviving one. Without the inner SELECT/ORDER BY/LIMIT 1 wrap, a reading that
    -- passes the ON-filter against multiple candidates would be duplicated in tmp_matched.
    CREATE TEMP TABLE tmp_matched ON COMMIT DROP AS
    SELECT
        t.*,
        m.segment_id,
        m.distance_m,
        m.heading_diff
    FROM tmp_batch_readings t
    LEFT JOIN LATERAL (
        SELECT * FROM (
            SELECT
                rs.id AS segment_id,
                ST_Distance(rs.geom::geography, t.geom::geography) AS distance_m,
                ABS(
                    ((COALESCE(t.heading, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
                ) AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
            -- KNN on geography so ordering reflects true meters (at 44°N,
            -- degree-space ordering would bias east-west over north-south by ~30%).
            ORDER BY rs.geom::geography <-> t.geom::geography
            LIMIT 3
        ) candidates
        WHERE candidates.distance_m <= 20
          AND (candidates.heading_diff <= 45 OR candidates.heading_diff >= 135)  -- allow reverse direction
        ORDER BY candidates.distance_m
        LIMIT 1
    ) m ON TRUE
    ORDER BY t.recorded_at;

    -- Insert accepted readings
    INSERT INTO readings (
        segment_id, batch_id, device_token_hash,
        roughness_rms, speed_kmh, heading_degrees, gps_accuracy_m,
        is_pothole, pothole_magnitude, location, recorded_at
    )
    SELECT
        segment_id, p_batch_id, p_device_token_hash,
        roughness_rms, speed_kmh, heading, gps_accuracy_m,
        is_pothole, pothole_magnitude, geom, recorded_at
    FROM tmp_matched
    WHERE segment_id IS NOT NULL;
    GET DIAGNOSTICS v_accepted = ROW_COUNT;

    v_rejected := (SELECT count(*) FROM tmp_batch_readings) - v_accepted;

    -- Counts per rejection reason — surfaced in the API response so clients can
    -- distinguish transient issues (no_segment_match on a dead zone) from bugs
    -- (out_of_bounds should be impossible if the client respects the NS bbox).
    -- Edge Function rejections (validation_failed, stale_timestamp, privacy_zone)
    -- are enumerated by the Edge Function itself before the RPC is called.
    SELECT json_build_object(
        'no_segment_match', count(*) FILTER (WHERE segment_id IS NULL),
        'unpaved', 0   -- reserved; unpaved segments never enter tmp_matched
    )
    INTO v_rejected_reasons
    FROM tmp_matched;

    -- Record the batch BEFORE the aggregate fold so that if the later step errors out
    -- and the transaction is rolled back, the next retry re-runs everything cleanly.
    -- Without the insert-first pattern, a mid-function crash could commit readings
    -- but not processed_batches, causing a retry to double-count.
    INSERT INTO processed_batches (
        batch_id, device_token_hash, reading_count, accepted_count, rejected_count,
        client_sent_at, client_app_version, client_os_version
    ) VALUES (
        p_batch_id, p_device_token_hash,
        (SELECT count(*) FROM tmp_batch_readings),
        v_accepted, v_rejected,
        p_client_sent_at, p_client_app_version, p_client_os_version
    );

    -- Fold into segment_aggregates (same transaction — atomic with the readings insert)
    PERFORM update_segment_aggregates_from_batch(p_batch_id);

    -- Fold pothole candidates into pothole_reports
    PERFORM fold_pothole_candidates(p_batch_id);

    RETURN json_build_object(
        'accepted', v_accepted,
        'rejected', v_rejected,
        'duplicate', FALSE,
        'rejected_reasons', v_rejected_reasons
    );
END;
$$;

-- CRITICAL: revoke execute from anon/authenticated so only the Edge Function
-- (which holds service_role) can invoke this RPC. Without this, any client with
-- the anon key could POST /rest/v1/rpc/ingest_reading_batch and bypass the
-- Edge Function's rate limiter entirely.
REVOKE EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) TO service_role;
```

### Aggregate Folding: `update_segment_aggregates_from_batch`

Incremental update — avoid full recompute per batch. Nightly job does full recompute with outlier trimming.

```sql
CREATE OR REPLACE FUNCTION update_segment_aggregates_from_batch(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Two-step fold: (1) upsert the numeric counts with a weighted average,
    -- (2) UPDATE confidence and roughness_category from the freshly-written values.
    -- Doing both inside ON CONFLICT DO UPDATE is buggy because confidence/category
    -- would be evaluated against the pre-update avg_roughness_score and
    -- unique_contributors, and adding EXCLUDED.unique_contributors to the existing
    -- count double-counts any contributor who has appeared before.

    INSERT INTO segment_aggregates (segment_id, avg_roughness_score, total_readings,
                                    unique_contributors, last_reading_at, pothole_count,
                                    confidence, roughness_category)
    SELECT
        r.segment_id,
        AVG(r.roughness_rms)::NUMERIC(5,3),
        count(*)::INT,
        count(DISTINCT r.device_token_hash)::INT,
        MAX(r.recorded_at),
        count(*) FILTER (WHERE r.is_pothole)::INT,
        'low',
        'unscored'
    FROM readings r
    WHERE r.batch_id = p_batch_id
      AND r.segment_id IS NOT NULL
    GROUP BY r.segment_id
    ON CONFLICT (segment_id) DO UPDATE SET
        avg_roughness_score = (
            -- weighted rolling average; weight each side by its sample count
            segment_aggregates.avg_roughness_score *
                (segment_aggregates.total_readings::NUMERIC /
                 NULLIF(segment_aggregates.total_readings + EXCLUDED.total_readings, 0))
            + EXCLUDED.avg_roughness_score *
                (EXCLUDED.total_readings::NUMERIC /
                 NULLIF(segment_aggregates.total_readings + EXCLUDED.total_readings, 0))
        ),
        total_readings = segment_aggregates.total_readings + EXCLUDED.total_readings,
        -- Approximate contributor fold: upper bound = old + batch-delta. This
        -- overcounts returning contributors on the segment, but the nightly
        -- recompute makes it canonical. An earlier version ran a full
        -- count(DISTINCT device_token_hash) over the readings partitions for
        -- EVERY segment in the batch, which at steady state was tens of ms
        -- per segment per batch (hundreds of rows in each partition, no
        -- segment_id-only cross-partition index) and blew the p95-<-4s
        -- ingest budget. The approximation here is intentional and documented
        -- in the spec — confidence tier is what matters, not the exact int.
        unique_contributors = segment_aggregates.unique_contributors
                              + EXCLUDED.unique_contributors,
        last_reading_at = GREATEST(segment_aggregates.last_reading_at, EXCLUDED.last_reading_at),
        pothole_count = segment_aggregates.pothole_count + EXCLUDED.pothole_count,
        updated_at = now();

    -- Follow-up UPDATE reads the just-written row, so confidence/category reflect the
    -- new values rather than lagging by one batch.
    UPDATE segment_aggregates sa
    SET
        confidence = CASE
            WHEN sa.unique_contributors >= 10 THEN 'high'::confidence_level
            WHEN sa.unique_contributors >= 3  THEN 'medium'::confidence_level
            ELSE 'low'::confidence_level
        END,
        roughness_category = CASE
            WHEN sa.avg_roughness_score < 0.3 THEN 'smooth'::roughness_category
            WHEN sa.avg_roughness_score < 0.6 THEN 'fair'::roughness_category
            WHEN sa.avg_roughness_score < 1.0 THEN 'rough'::roughness_category
            ELSE 'very_rough'::roughness_category
        END
    WHERE sa.segment_id IN (
        SELECT DISTINCT segment_id
        FROM readings
        WHERE batch_id = p_batch_id
          AND segment_id IS NOT NULL
    );
END;
$$;
```

**Note:** this incremental scheme is approximate — the weighted average drift is bounded, and `unique_contributors` is an upper bound (overcounts returning contributors) until the nightly full recompute makes it canonical. That's acceptable for MVP: the `confidence` tier is threshold-based (`>= 3`, `>= 10`) and overcount only ever moves a segment from `low` → `medium`/`high` sooner, never the other way. Nightly job resets to exact.

### Pothole Folding: `fold_pothole_candidates`

```sql
-- For each pothole=TRUE reading in the batch, find an existing pothole within 15m
-- and within 90 days. If found, increment confirmation. If not, create a new report.
-- Logic: (straightforward UPSERT against pothole_reports, keyed on ST_DWithin + time)
```

Full body omitted here for brevity; follows same structure as aggregate folding.

## Vector Tile Endpoint

### Endpoint: `GET /functions/v1/tiles/:z/:x/:y.mvt`

Edge function builds MVT by calling a `get_tile` stored procedure.

```sql
CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
    v_min_zoom INT;
BEGIN
    -- Zoom-level road-type filter (defense in depth; client also filters)
    v_min_zoom := CASE
        WHEN z < 10 THEN 0   -- show nothing (return empty tile)
        WHEN z < 12 THEN 12  -- only major
        WHEN z < 14 THEN 14  -- + tertiary
        ELSE 0               -- show all
    END;

    IF z < 10 THEN RETURN ''::bytea; END IF;

    WITH bounds AS (
        SELECT ST_TileEnvelope(z, x, y) AS geom
    ),
    segments AS (
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            sa.avg_roughness_score AS roughness_score,
            sa.roughness_category::text AS category,
            sa.confidence::text AS confidence,
            sa.total_readings,
            sa.unique_contributors,
            sa.pothole_count,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                (SELECT geom FROM bounds),
                4096, 64, true
            ) AS geom
        FROM road_segments rs
        JOIN segment_aggregates sa ON sa.segment_id = rs.id
        WHERE ST_Transform(rs.geom, 3857) && (SELECT geom FROM bounds)
          AND sa.confidence != 'low'   -- low-confidence segments not published
          AND sa.unique_contributors >= 3
          AND (
              z >= 14
              OR rs.road_type IN ('motorway','trunk','primary','secondary','tertiary',
                                   'motorway_link','trunk_link','primary_link','secondary_link')
          )
    ),
    potholes AS (
        SELECT
            pr.id,
            pr.magnitude,
            pr.confirmation_count,
            ST_AsMVTGeom(
                ST_Transform(pr.geom, 3857),
                (SELECT geom FROM bounds),
                4096, 64, true
            ) AS geom
        FROM pothole_reports pr
        WHERE pr.status = 'active'
          AND ST_Transform(pr.geom, 3857) && (SELECT geom FROM bounds)
          AND z >= 13
    )
    SELECT
        COALESCE(
            (SELECT ST_AsMVT(segments.*, 'segment_aggregates', 4096, 'geom') FROM segments),
            ''::bytea
        ) ||
        COALESCE(
            (SELECT ST_AsMVT(potholes.*, 'potholes', 4096, 'geom') FROM potholes),
            ''::bytea
        )
    INTO v_tile;

    RETURN v_tile;
END;
$$;

-- Only the tiles Edge Function (service_role) should hit this directly.
-- Without REVOKE + explicit GRANT, PostgREST exposes it to anon via
-- /rest/v1/rpc/get_tile and anyone with the shipped anon key (extractable
-- from any iOS binary) can hammer it directly, bypassing the Edge Function's
-- caching and rate-limiting layer.
REVOKE EXECUTE ON FUNCTION get_tile(INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_tile(INT, INT, INT) TO service_role;
```

### Edge Function Wrapper (for caching + CDN)

```typescript
// supabase/functions/tiles/index.ts — sketch
serve(async (req) => {
    const url = new URL(req.url)
    const match = url.pathname.match(/\/(\d+)\/(\d+)\/(\d+)\.mvt$/)
    if (!match) return new Response(null, { status: 404 })

    const [, z, x, y] = match
    // Use SERVICE_ROLE_KEY here — get_tile is REVOKE'd from PUBLIC so that anon
    // clients cannot hit the RPC directly via PostgREST. The Edge Function is
    // the only intended caller. Do NOT expose this key to the client; the
    // function runs server-side in Deno Deploy.
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    )
    const { data, error } = await supabase.rpc("get_tile", {
        z: parseInt(z), x: parseInt(x), y: parseInt(y),
    })
    if (error) return new Response("error", { status: 500 })

    return new Response(data, {
        headers: {
            "content-type": "application/vnd.mapbox-vector-tile",
            "cache-control": "public, max-age=3600, s-maxage=3600",
            "access-control-allow-origin": "*",
        },
    })
})
```

Supabase CDN caches these at the edge based on URL. Cache-bust after nightly recompute by including a short version suffix in the URL (`?v=<unix-day>`) — the iOS client appends this automatically.

### Alternative: Martin Tile Server (if Edge Function is too slow)

If Edge Function cold-start becomes painful or p95 tile latency > 300ms, migrate to [Martin](https://github.com/maplibre/martin), a Rust tile server that speaks Postgres directly. Host it on Fly.io, ~$5/month.

**Trigger for migration:** p95 tile latency > 300ms consistently for 3+ days, or error rate > 1%.

## Nightly Aggregate Recompute

Full recompute with outlier trimming, trend calculation, and score decay.

```sql
CREATE OR REPLACE FUNCTION nightly_recompute_aggregates()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- For each segment that has had activity in the last 24h, full recompute
    WITH active_segments AS (
        SELECT DISTINCT segment_id FROM readings
        WHERE uploaded_at > now() - INTERVAL '24 hours'
          AND segment_id IS NOT NULL
    ),
    per_device_capped AS (
        -- Cap each device to at most 3 readings per segment per week
        SELECT r.segment_id, r.roughness_rms, r.is_pothole, r.recorded_at, r.device_token_hash,
               ROW_NUMBER() OVER (
                   PARTITION BY r.segment_id, r.device_token_hash,
                                DATE_TRUNC('week', r.recorded_at)
                   ORDER BY r.recorded_at DESC
               ) AS rn
        FROM readings r
        WHERE r.segment_id IN (SELECT segment_id FROM active_segments)
          AND r.recorded_at > now() - INTERVAL '6 months'
    ),
    filtered AS (
        SELECT * FROM per_device_capped WHERE rn <= 3
    ),
    -- PERCENTILE_CONT is an ordered-set aggregate and cannot be used as a window function,
    -- so compute per-segment p10/p90 as a regular aggregate and join back.
    segment_bounds AS (
        SELECT f.segment_id,
               PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY f.roughness_rms) AS p10,
               PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.roughness_rms) AS p90,
               COUNT(*) AS n
        FROM filtered f
        GROUP BY f.segment_id
    ),
    trimmed AS (
        -- Only trim when there are enough readings for the trim to be meaningful (>= 10).
        -- Otherwise keep all readings — trimming 2 of 5 would throw away too much signal.
        SELECT f.*, b.p10, b.p90, b.n
        FROM filtered f
        JOIN segment_bounds b ON b.segment_id = f.segment_id
        WHERE b.n < 10 OR f.roughness_rms BETWEEN b.p10 AND b.p90
    ),
    recency_weighted AS (
        SELECT
            t.segment_id,
            -- exponential decay: weight = exp(-age_days / 90)
            SUM(t.roughness_rms * EXP(-EXTRACT(EPOCH FROM (now() - t.recorded_at)) / (86400 * 90)))
                / NULLIF(SUM(EXP(-EXTRACT(EPOCH FROM (now() - t.recorded_at)) / (86400 * 90))), 0) AS avg_score,
            count(*) AS reading_count,
            count(DISTINCT t.device_token_hash) AS contributor_count,
            count(*) FILTER (WHERE t.is_pothole) AS pothole_count,
            MAX(t.recorded_at) AS last_at,
            -- trend: last-30d avg vs 30-60d avg
            AVG(t.roughness_rms) FILTER (WHERE t.recorded_at > now() - INTERVAL '30 days') AS avg_30d,
            AVG(t.roughness_rms) FILTER (WHERE t.recorded_at BETWEEN now() - INTERVAL '60 days' AND now() - INTERVAL '30 days') AS avg_30_60d
        FROM trimmed t
        GROUP BY t.segment_id
    )
    INSERT INTO segment_aggregates (segment_id, avg_roughness_score, total_readings,
                                    unique_contributors, last_reading_at, pothole_count,
                                    score_last_30d, score_30_60d, trend,
                                    confidence, roughness_category, updated_at)
    SELECT
        r.segment_id, r.avg_score, r.reading_count, r.contributor_count,
        r.last_at, r.pothole_count, r.avg_30d, r.avg_30_60d,
        CASE
            WHEN r.avg_30d IS NULL OR r.avg_30_60d IS NULL THEN 'stable'
            WHEN r.avg_30d > r.avg_30_60d * 1.1 THEN 'worsening'
            WHEN r.avg_30d < r.avg_30_60d * 0.9 THEN 'improving'
            ELSE 'stable'
        END::trend_direction,
        CASE
            WHEN r.contributor_count >= 10 THEN 'high'
            WHEN r.contributor_count >= 3 THEN 'medium'
            ELSE 'low'
        END::confidence_level,
        CASE
            WHEN r.avg_score < 0.3 THEN 'smooth'
            WHEN r.avg_score < 0.6 THEN 'fair'
            WHEN r.avg_score < 1.0 THEN 'rough'
            ELSE 'very_rough'
        END::roughness_category,
        now()
    FROM recency_weighted r
    ON CONFLICT (segment_id) DO UPDATE SET
        avg_roughness_score = EXCLUDED.avg_roughness_score,
        total_readings = EXCLUDED.total_readings,
        unique_contributors = EXCLUDED.unique_contributors,
        last_reading_at = EXCLUDED.last_reading_at,
        pothole_count = EXCLUDED.pothole_count,
        score_last_30d = EXCLUDED.score_last_30d,
        score_30_60d = EXCLUDED.score_30_60d,
        trend = EXCLUDED.trend,
        confidence = EXCLUDED.confidence,
        roughness_category = EXCLUDED.roughness_category,
        updated_at = now();

    -- Bust tile cache: update a version counter that the tile endpoint reads
    -- (or rely on client appending ?v=<unix-day> to invalidate at edge)
END;
$$;

-- Lock down execution: this is a heavy batch job, scheduled by pg_cron only.
-- Without REVOKE + GRANT, PostgREST exposes it to anon via
-- /rest/v1/rpc/nightly_recompute_aggregates and a single POST with the
-- shipped anon key kicks a full aggregate recompute — cheap DoS.
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION nightly_recompute_aggregates() TO service_role;
```

## Pothole Expiry

```sql
CREATE OR REPLACE FUNCTION expire_unconfirmed_potholes()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE pothole_reports
    SET status = 'expired'
    WHERE status = 'active'
      AND last_confirmed_at < now() - INTERVAL '90 days';
END;
$$;

-- Same PostgREST-exposure concern as above; lock to service_role.
REVOKE EXECUTE ON FUNCTION expire_unconfirmed_potholes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION expire_unconfirmed_potholes() TO service_role;
```

Post-MVP: add "road repaired" auto-detection — if 2+ contributors report smooth readings at a pothole location, mark as `resolved`.

## Indexing & Query Performance

Expected row counts at 12 months in at Halifax scale:

- `road_segments`: ~400k (one-time, stable)
- `segment_aggregates`: ~400k
- `readings`: ~5M / year (10 drivers × 500km/week × ~20 readings/km × 50 weeks). 20 readings/km matches 50m segments closed at ~40m window length. Grow to ~50M only if we hit 100+ concurrent drivers or shorten segments to 10m.
- `pothole_reports`: ~10k

Critical query patterns:

1. **KNN match reading → segment** (hottest path, runs per reading during ingestion)
   - Index: `GIST(geom)` on `road_segments`
   - Plan: `ORDER BY geom <-> point LIMIT 3` with `ST_DWithin` prefilter
   - Target: < 5ms per reading on warm cache

2. **Tile fetch** (bbox intersect)
   - Index: `GIST(geom)` on `road_segments`
   - Plan: `ST_Transform(geom,3857) && tile_bbox`
   - Target: < 100ms per tile on warm cache, served from Supabase CDN on subsequent hits

3. **Segment detail** (single segment lookup)
   - Index: PK on `segment_aggregates.segment_id`
   - Target: < 10ms

Run `EXPLAIN ANALYZE` on the ingestion match query after first 100k readings exist — if any reading processing exceeds 50ms, add `segment_bbox` materialized view or reduce KNN candidates to 1.

## Open Questions for Backend

- **[OPEN] Should we store `readings.location` as GEOGRAPHY instead of GEOMETRY?** Geography auto-handles meters but is slower for KNN. Default: GEOMETRY(4326) + cast to geography for distance calcs. Revisit if spatial join perf is an issue.
- **[OPEN] Materialized view for Halifax-only tile serving?** If HRM segment queries dominate, a `hrm_segments_mv` could cut tile query cost by ~50%. Defer until measured.
- **[OPEN] When to migrate to Martin tile server?** Set up the trigger (§"Alternative: Martin") before launch; don't migrate preemptively.
- **[OPEN] Should `device_token_hash` include a monthly salt?** Currently server peppers with a constant secret. A monthly-rotating salt breaks long-term contributor linkage but also breaks the "cap 3 readings/device/week" logic — rejected.
