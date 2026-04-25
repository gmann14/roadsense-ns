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
CREATE TYPE pothole_action_type AS ENUM ('manual_report', 'confirm_present', 'confirm_fixed');
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
    location GEOMETRY(POINT, 4326) NOT NULL,      -- kept for OSM-refresh rematch + QA backfills
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
    negative_confirmation_count INTEGER NOT NULL DEFAULT 0,
    unique_reporters INTEGER NOT NULL DEFAULT 1,
    last_fixed_reported_at TIMESTAMPTZ,
    has_photo BOOLEAN NOT NULL DEFAULT FALSE,
    status pothole_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_potholes_geom ON pothole_reports USING GIST (geom);
CREATE INDEX idx_potholes_segment ON pothole_reports (segment_id);
CREATE INDEX idx_potholes_status ON pothole_reports (status);
```

### Migration 005b — `pothole_actions`

Explicit user pothole actions get their own table for idempotency, dedupe, and resolution auditability.

```sql
CREATE TABLE pothole_actions (
    action_id UUID PRIMARY KEY,
    device_token_hash BYTEA NOT NULL,
    pothole_report_id UUID REFERENCES pothole_reports(id) ON DELETE SET NULL,
    segment_id UUID REFERENCES road_segments(id) ON DELETE SET NULL,
    geom GEOMETRY(POINT, 4326) NOT NULL,
    accuracy_m NUMERIC(5,2),
    action_type pothole_action_type NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pothole_actions_geom   ON pothole_actions USING GIST (geom);
CREATE INDEX idx_pothole_actions_report ON pothole_actions (pothole_report_id);
CREATE INDEX idx_pothole_actions_device ON pothole_actions (device_token_hash, recorded_at DESC);
```

### Migration 006 — `processed_batches` (idempotency)

```sql
CREATE TABLE processed_batches (
    batch_id UUID PRIMARY KEY,
    device_token_hash BYTEA NOT NULL,
    reading_count INTEGER NOT NULL,
    accepted_count INTEGER NOT NULL,
    rejected_count INTEGER NOT NULL,
    rejected_reasons JSONB NOT NULL DEFAULT '{}'::JSONB,
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

-- Refresh public_stats_mv every 5 min so the /stats card is never more than 5 min stale.
-- CONCURRENTLY avoids blocking read traffic during the refresh window.
-- Phase-9 public_worst_segments_mv has its own cron defined alongside that MV.
SELECT cron.schedule(
    'refresh-public-stats-mv',
    '2-57/5 * * * *',
    $$SELECT refresh_public_stats_mv()$$
);
```

Beyond MVP: also pre-create three months ahead (run on the 1st) so a single cron failure doesn't cascade.

## OSM Import Pipeline

Run as a one-off script (not a migration) — the OSM data is too large to shove into migrations, and we refresh it quarterly.

### Refresh Staging Objects

Quarterly refreshes must preserve existing `road_segments.id` values for stable FKs from `segment_aggregates` and historical `readings`. Use a staging table keyed on the natural segment identity, then merge into `road_segments`.

```sql
CREATE TABLE road_segments_staging (
    osm_way_id BIGINT NOT NULL,
    segment_index INTEGER NOT NULL,
    geom GEOMETRY(LINESTRING, 4326) NOT NULL,
    length_m NUMERIC(8,1) NOT NULL,
    road_name TEXT,
    road_type TEXT NOT NULL,
    surface_type TEXT,
    municipality TEXT,
    has_speed_bump BOOLEAN DEFAULT FALSE,
    has_rail_crossing BOOLEAN DEFAULT FALSE,
    is_parking_aisle BOOLEAN DEFAULT FALSE,
    bearing_degrees NUMERIC(5,2),
    PRIMARY KEY (osm_way_id, segment_index)
);

CREATE INDEX idx_segments_staging_geom ON road_segments_staging USING GIST (geom);
CREATE INDEX idx_segments_staging_geog ON road_segments_staging USING GIST ((geom::geography));
```

### Refresh Apply / Rematch Procedures

Quarterly OSM refreshes use two explicit procedures rather than relying on the nightly job:

```sql
CREATE OR REPLACE FUNCTION apply_road_segment_refresh()
RETURNS TABLE(updated_count BIGINT, inserted_count BIGINT, deleted_count BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_updated BIGINT := 0;
    v_inserted BIGINT := 0;
    v_deleted BIGINT := 0;
BEGIN
    -- Run inside an explicit transaction at the caller side (the osm-import script
    -- wraps this in BEGIN/COMMIT). Each statement below is atomic within that txn.

    -- 1. UPDATE existing road_segments rows by (osm_way_id, segment_index),
    --    preserving id so FKs from segment_aggregates and readings stay valid.
    WITH upd AS (
        UPDATE road_segments rs
        SET geom            = s.geom,
            length_m        = s.length_m,
            road_name       = s.road_name,
            road_type       = s.road_type,
            surface_type    = s.surface_type,
            municipality    = s.municipality,
            has_speed_bump  = s.has_speed_bump,
            has_rail_crossing = s.has_rail_crossing,
            is_parking_aisle = s.is_parking_aisle,
            bearing_degrees = s.bearing_degrees
        FROM road_segments_staging s
        WHERE rs.osm_way_id = s.osm_way_id
          AND rs.segment_index = s.segment_index
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_updated FROM upd;

    -- 2. INSERT newly appeared (osm_way_id, segment_index) tuples.
    WITH ins AS (
        INSERT INTO road_segments (
            osm_way_id, segment_index, geom, length_m, road_name, road_type,
            surface_type, municipality, has_speed_bump, has_rail_crossing,
            is_parking_aisle, bearing_degrees
        )
        SELECT
            s.osm_way_id, s.segment_index, s.geom, s.length_m, s.road_name,
            s.road_type, s.surface_type, s.municipality, s.has_speed_bump,
            s.has_rail_crossing, s.is_parking_aisle, s.bearing_degrees
        FROM road_segments_staging s
        LEFT JOIN road_segments rs
          ON rs.osm_way_id = s.osm_way_id
         AND rs.segment_index = s.segment_index
        WHERE rs.id IS NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_inserted FROM ins;

    -- 3. DELETE primary-table rows whose keys disappeared from staging.
    --    FK ON DELETE CASCADE on segment_aggregates removes stale aggregate rows.
    --    readings.segment_id is intentionally NOT an FK (partitioned tables, plus
    --    we want to be able to batch-rematch rather than pay per-row SET NULL on
    --    millions of rows). Any dangling segment_id values left by this DELETE
    --    get reconciled by rematch_readings_after_segment_refresh() below — it
    --    rewrites every segment_id it can, and leaves no-match cases NULL.
    WITH del AS (
        DELETE FROM road_segments rs
        USING (
            SELECT rs2.id
            FROM road_segments rs2
            LEFT JOIN road_segments_staging s
              ON s.osm_way_id = rs2.osm_way_id
             AND s.segment_index = rs2.segment_index
            WHERE s.osm_way_id IS NULL
        ) doomed
        WHERE rs.id = doomed.id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_deleted FROM del;

    RAISE NOTICE 'apply_road_segment_refresh: updated=% inserted=% deleted=%',
                 v_updated, v_inserted, v_deleted;

    RETURN QUERY SELECT v_updated, v_inserted, v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION rematch_readings_after_segment_refresh(
    p_since TIMESTAMPTZ DEFAULT now() - INTERVAL '6 months'
) RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_touched UUID[];
BEGIN
    -- Re-run the same KNN + heading matcher used by ingest against readings.location
    -- for retained raw readings since p_since. Readings with no paved match get
    -- segment_id = NULL. Return the union of old and new segment IDs touched so
    -- the caller can pass them to nightly_recompute_aggregates(segment_ids).

    WITH matched AS (
        SELECT
            r.id                AS reading_id,
            r.segment_id        AS old_segment_id,
            (
                SELECT rs.id
                FROM road_segments rs
                WHERE rs.surface_type IN ('paved', 'asphalt', 'concrete', 'paving_stones')
                  AND ST_DWithin(rs.geom::geography, r.location::geography, 25)
                  AND (
                      r.heading IS NULL
                      OR rs.bearing_degrees IS NULL
                      OR LEAST(
                          ABS(r.heading - rs.bearing_degrees),
                          360 - ABS(r.heading - rs.bearing_degrees)
                      ) <= 45
                  )
                ORDER BY rs.geom::geography <-> r.location::geography
                LIMIT 1
            )                   AS new_segment_id
        FROM readings r
        WHERE r.recorded_at >= p_since
    ),
    changed AS (
        SELECT * FROM matched
        WHERE old_segment_id IS DISTINCT FROM new_segment_id
    ),
    upd AS (
        UPDATE readings r
        SET segment_id = c.new_segment_id
        FROM changed c
        WHERE r.id = c.reading_id
        RETURNING c.old_segment_id, c.new_segment_id
    )
    SELECT ARRAY(
        SELECT DISTINCT sid
        FROM (
            SELECT old_segment_id AS sid FROM upd
            UNION
            SELECT new_segment_id AS sid FROM upd
        ) u
        WHERE sid IS NOT NULL
    ) INTO v_touched;

    RAISE NOTICE 'rematch_readings_after_segment_refresh: % segments touched',
                 COALESCE(array_length(v_touched, 1), 0);

    RETURN COALESCE(v_touched, ARRAY[]::UUID[]);
END;
$$;

REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_road_segment_refresh() TO service_role;
GRANT EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) TO service_role;
```

**Cost note:** the rematch query does a KNN lookup per reading since `p_since`. At MVP scale (~2.6M readings over 6 months, per the testing spec), expect a few minutes on the Small Supabase instance. Run quarterly, off-peak, with session-level `statement_timeout` raised accordingly. Beyond MVP, partition the work by month and drive it from a worker that commits per-partition.

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
psql "$DATABASE_URL" -c "TRUNCATE road_segments_staging"
psql "$DATABASE_URL" -f scripts/segmentize.sql

echo "→ Tagging municipalities via StatCan boundaries"
# statscan boundaries pre-imported into ref.municipalities (one-time, outside this script)
psql "$DATABASE_URL" -f scripts/tag-municipalities.sql

echo "→ Tagging features (speed bumps, rail crossings, surface)"
psql "$DATABASE_URL" -f scripts/tag-features.sql

echo "→ Applying staged refresh into road_segments and rematching retained readings"
# apply_road_segment_refresh returns (updated, inserted, deleted) counts; log them.
# Wrap the three calls in a single transaction so a rematch failure doesn't leave
# road_segments updated without aggregates reconciled.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT * FROM apply_road_segment_refresh();
SELECT nightly_recompute_aggregates(rematch_readings_after_segment_refresh());
COMMIT;
SQL

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
-- Produce staged road segments by slicing each OSM way into 50m pieces
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
INSERT INTO road_segments_staging (
    osm_way_id, segment_index, geom, length_m, road_name, road_type, surface_type, bearing_degrees
)
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
        road_type       = EXCLUDED.road_type,
        surface_type    = EXCLUDED.surface_type,
        bearing_degrees = EXCLUDED.bearing_degrees,
        municipality    = NULL,
        has_speed_bump  = FALSE,
        has_rail_crossing = FALSE,
        is_parking_aisle = FALSE;
```

**Performance:** For NS (~50k OSM ways), this takes ~5 minutes on Supabase Pro small instance. Run during low-traffic window. Expect ~300k–600k segments total. If it slows with growth, add `CREATE INDEX ON osm.osm_ways USING GIST (geom);` and run in batches of 5k ways.

**Generate_series gotcha:** the series returns a scalar `integer`, not an array. Earlier drafts of this script referenced `gs.path[1]` — that's `generate_subscripts`, a different function. The corrected version above uses the scalar `s` directly.

### `scripts/tag-municipalities.sql`

```sql
-- Spatial join each segment with StatCan CSD boundaries
UPDATE road_segments_staging rs
SET municipality = m.csd_name
FROM ref.municipalities m
WHERE ST_Intersects(rs.geom, m.geom)
  AND rs.municipality IS NULL;

-- Simple centroid tiebreak for segments crossing boundaries
UPDATE road_segments_staging rs
SET municipality = m.csd_name
FROM ref.municipalities m
WHERE rs.municipality IS NULL
  AND ST_Contains(m.geom, ST_Centroid(rs.geom));
```

**Data source:** Statistics Canada Census Subdivision boundaries (CSD), downloaded from StatCan as ESRI shapefile, imported once via `ogr2ogr` into `ref.municipalities`.

### `scripts/tag-features.sql`

```sql
-- Speed bumps
UPDATE road_segments_staging rs
SET has_speed_bump = true
WHERE EXISTS (
    SELECT 1 FROM osm.osm_nodes n
    WHERE n.tags->>'traffic_calming' = 'bump'
      AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
);

-- Rail crossings
UPDATE road_segments_staging rs
SET has_rail_crossing = true
WHERE EXISTS (
    SELECT 1 FROM osm.osm_nodes n
    WHERE n.tags->>'railway' = 'level_crossing'
      AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
);

-- Parking aisles
UPDATE road_segments_staging rs
SET is_parking_aisle = true
WHERE road_type = 'service' AND surface_type = 'parking_aisle';
-- (plus segments inside amenity=parking polygons)

-- Do NOT write aggregate categories here. Unpaved handling happens in the
-- ingest / recompute paths, which either reject these readings with
-- `rejected_reason = 'unpaved'` or derive the category from the matched
-- `road_segments.surface_type` at fold time. Writing `segment_aggregates`
-- during import is a no-op on a fresh DB and drifts once aggregates exist.
```

## Ingestion Pipeline

### Edge Function: `POST /functions/v1/upload-readings`

Thin validation + auth + rate limit layer. Calls stored procedure for the spatial work.

```typescript
// supabase/functions/upload-readings/index.ts — sketch
import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"

type UploadPayload = {
    batch_id: string
    device_token: string
    client_sent_at: string
    client_app_version: string
    client_os_version: string
    readings: Array<{
        lat: number
        lng: number
        roughness_rms: number
        speed_kmh: number
        heading: number | null
        gps_accuracy_m: number
        recorded_at: string
        is_pothole?: boolean
        pothole_magnitude?: number | null
    }>
}

serve(async (req) => {
    if (req.method !== "POST") return new Response(null, { status: 405 })

    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID()
    const payload = await req.json() as UploadPayload
    const validation = validateRequestShape(payload)
    if (!validation.ok) {
        return jsonResponse(
            {
                error: "validation_failed",
                message: "Payload is malformed.",
                field_errors: validation.fieldErrors,
                request_id: requestId,
            },
            400,
            {},
            requestId,
        )
    }

    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    )

    // Hash device token server-side (client sends cleartext; hash with a
    // server-side pepper to make rainbow-tabling harder)
    const tokenHashHex = await sha256Hex(payload.device_token + Deno.env.get("TOKEN_PEPPER")!)
    const tokenHashBytea = `\\x${tokenHashHex}`   // Postgres BYTEA literal for RPC input

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
    const rate = await checkRateLimit(supabase, tokenHashHex, ip)
    if (!rate.ok) {
        return jsonResponse(
            {
                error: "rate_limited",
                message: "Device or IP exceeded rate limit.",
                retry_after_s: rate.retryAfterSeconds,
                request_id: requestId,
            },
            429,
            { "Retry-After": String(rate.retryAfterSeconds) },
            requestId,
        )
    }

    // Dispatch to stored procedure
    const { data, error } = await supabase.rpc("ingest_reading_batch", {
        p_batch_id: payload.batch_id,
        p_device_token_hash: tokenHashBytea,
        p_readings: payload.readings,
        p_client_sent_at: payload.client_sent_at,
        p_client_app_version: payload.client_app_version,
        p_client_os_version: payload.client_os_version,
    })

    if (error) {
        console.error("ingest_reading_batch failed", {
            request_id: requestId,
            batch_id: payload.batch_id,
            token_hash_prefix: tokenHashHex.slice(0, 4),
            error,
        })
        return jsonResponse(
            { error: "processing_failed", request_id: requestId },
            502,
            {},
            requestId,
        )
    }

    return jsonResponse({
        batch_id: payload.batch_id,
        accepted: data.accepted,
        rejected: data.rejected,
        duplicate: data.duplicate,
        rejected_reasons: data.rejected_reasons ?? {},
    }, 200, {}, requestId)
})

// Signature: jsonResponse(body: unknown, status: number, extraHeaders?: Record<string, string>, requestId?: string)
// — the rate-limited path above passes { "Retry-After": "..." } through this helper. Keep the
// helper definition alongside this file; it must always emit the `x-request-id`
// header, and the extraHeaders param is what makes the 429 contract (§03)
// actually pass its contract test.
//
// Keep these helpers in the same file so the sketch is directly runnable:
// - validateRequestShape(payload): returns { ok: boolean, fieldErrors?: Record<string, string> }
// - sha256Hex(input): returns a 64-char lowercase hex digest
```

### Validation

- Hard 400 validation is for malformed payloads only:
  - `batch_id` / `device_token` not valid UUIDv4
  - `readings.length > 1000` (`batch_too_large`)
  - missing required top-level fields
  - missing or non-numeric per-reading scalar fields
- Domain-level rejects are **not** 400s. The stored procedure counts them into `rejected_reasons` and returns 200 with partial acceptance:
  - `out_of_bounds`
  - `future_timestamp`
  - `stale_timestamp`
  - `low_quality`
  - `no_segment_match`
  - `unpaved`

### Rate Limits (enforced in Edge Function)

- Per device token hash: 50 batches / 24h fixed bucket (calendar day UTC)
- Per IP: 10 batches / 1h fixed bucket (calendar hour UTC)
- Implemented via `check_and_bump_rate_limit(key, bucket_start, limit)` — atomic `INSERT ... ON CONFLICT UPDATE`
- Worst case at bucket boundary: 2× the nominal limit — acceptable; a sliding-window log would be 10× the cost for a small improvement
- On limit hit: return 429 with `Retry-After` header set to seconds-until-next-bucket

```typescript
// Edge Function helper — the piece the top-level handler calls.
async function checkRateLimit(
    supabase: SupabaseClient,
    tokenHashHex: string,
    ip: string,
): Promise<{ ok: boolean; retryAfterSeconds: number }> {
    const now = new Date()
    const dayBucket  = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
    const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()))

    // Device bucket: 50/day
    const deviceOk = await supabase.rpc("check_and_bump_rate_limit", {
        p_key: `dev:${tokenHashHex}`, p_bucket_start: dayBucket.toISOString(), p_limit: 50,
    })
    if (!deviceOk.data) {
        const secondsUntilNextDay = Math.ceil((dayBucket.getTime() + 86400000 - now.getTime()) / 1000)
        return { ok: false, retryAfterSeconds: secondsUntilNextDay }
    }

    // IP bucket: 10/hour
    const ipOk = await supabase.rpc("check_and_bump_rate_limit", {
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
    v_rejected_reasons JSON := '{}'::JSON;
BEGIN
    -- Serialize duplicate retries on batch_id. Without the advisory lock,
    -- two in-flight retries can both miss the EXISTS check and the loser
    -- hits the processed_batches PK at the end of the transaction.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_batch_id::TEXT, 0));

    -- Idempotency: if batch already processed, replay the original result exactly.
    IF EXISTS (SELECT 1 FROM processed_batches WHERE batch_id = p_batch_id) THEN
        SELECT accepted_count, rejected_count, rejected_reasons::JSON
        INTO v_accepted, v_rejected, v_rejected_reasons
        FROM processed_batches WHERE batch_id = p_batch_id;
        RETURN json_build_object(
            'accepted', v_accepted,
            'rejected', v_rejected,
            'duplicate', TRUE,
            'rejected_reasons', v_rejected_reasons
        );
    END IF;

    -- Temp tables are session-scoped in Postgres. If the Supabase pooler reuses a backend
    -- for a second RPC call, ON COMMIT DROP only fires at end of the enclosing transaction,
    -- and leftovers from a prior call can collide. Drop defensively, then recreate.
    DROP TABLE IF EXISTS tmp_batch_readings;
    DROP TABLE IF EXISTS tmp_matched;
    DROP TABLE IF EXISTS tmp_final;

    -- Stage readings into a temp table with pre-computed geometry and the
    -- server-visible rejection reasons that are cheap to evaluate before
    -- spatial matching. Client-only quality gates such as sample_count and
    -- duration_s are enforced on-device and should never reach the backend.
    CREATE TEMP TABLE tmp_batch_readings ON COMMIT DROP AS
    SELECT
        p.reading_idx,
        p.lat,
        p.lng,
        p.roughness_rms,
        p.speed_kmh,
        p.heading,
        p.gps_accuracy_m,
        p.is_pothole,
        p.pothole_magnitude,
        p.recorded_at,
        ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326) AS geom,
        CASE
            WHEN p.lng NOT BETWEEN -66.5 AND -59.5
              OR p.lat NOT BETWEEN 43.3 AND 47.1 THEN 'out_of_bounds'
            WHEN p.recorded_at > now() + INTERVAL '60 seconds' THEN 'future_timestamp'
            WHEN p.recorded_at < now() - INTERVAL '7 days' THEN 'stale_timestamp'
            WHEN p.gps_accuracy_m > 20
              OR p.speed_kmh < 15
              OR p.speed_kmh > 160
              OR p.roughness_rms < 0
              OR p.roughness_rms > 15 THEN 'low_quality'
            ELSE NULL
        END::TEXT AS rejection_reason
    FROM (
        SELECT
            ordinality AS reading_idx,
            (r->>'lat')::NUMERIC AS lat,
            (r->>'lng')::NUMERIC AS lng,
            (r->>'roughness_rms')::NUMERIC AS roughness_rms,
            (r->>'speed_kmh')::NUMERIC AS speed_kmh,
            (r->>'heading')::NUMERIC AS heading,
            (r->>'gps_accuracy_m')::NUMERIC AS gps_accuracy_m,
            COALESCE((r->>'is_pothole')::BOOLEAN, FALSE) AS is_pothole,
            (r->>'pothole_magnitude')::NUMERIC AS pothole_magnitude,
            (r->>'recorded_at')::TIMESTAMPTZ AS recorded_at
        FROM jsonb_array_elements(p_readings) WITH ORDINALITY AS r(r, ordinality)
    ) p;

    -- Match each reading to a SINGLE best segment using KNN + heading + distance filters.
    -- The lateral takes 3 nearest candidates, filters by heading, and picks the closest
    -- surviving one. Without the inner SELECT/ORDER BY/LIMIT 1 wrap, a reading that
    -- passes the ON-filter against multiple candidates would be duplicated in tmp_matched.
    CREATE TEMP TABLE tmp_matched ON COMMIT DROP AS
    SELECT
        t.reading_idx,
        m.segment_id,
        m.distance_m,
        m.heading_diff,
        m.surface_type
    FROM tmp_batch_readings t
    LEFT JOIN LATERAL (
        SELECT * FROM (
            SELECT
                rs.id AS segment_id,
                rs.surface_type,
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
    ) m ON t.rejection_reason IS NULL
    ORDER BY t.recorded_at;

    CREATE TEMP TABLE tmp_final ON COMMIT DROP AS
    SELECT
        t.*,
        m.segment_id,
        m.distance_m,
        m.heading_diff,
        CASE
            WHEN t.rejection_reason IS NOT NULL THEN t.rejection_reason
            WHEN m.segment_id IS NULL THEN 'no_segment_match'
            WHEN m.surface_type IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand') THEN 'unpaved'
            ELSE NULL
        END::TEXT AS final_rejection_reason
    FROM tmp_batch_readings t
    LEFT JOIN tmp_matched m USING (reading_idx)
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
    FROM tmp_final
    WHERE final_rejection_reason IS NULL;
    GET DIAGNOSTICS v_accepted = ROW_COUNT;

    v_rejected := (SELECT count(*) FROM tmp_final WHERE final_rejection_reason IS NOT NULL);

    -- Counts per rejection reason — surfaced in the API response so clients can
    -- distinguish transient issues (no_segment_match on a dead zone) from bugs
    -- (`out_of_bounds` / `low_quality` mean the client let through data it
    -- should normally have filtered on-device).
    SELECT COALESCE(
        jsonb_object_agg(reason, reason_count ORDER BY reason),
        '{}'::JSONB
    )::JSON
    INTO v_rejected_reasons
    FROM (
        SELECT final_rejection_reason AS reason, count(*) AS reason_count
        FROM tmp_final
        WHERE final_rejection_reason IS NOT NULL
        GROUP BY final_rejection_reason
    ) reasons;

    -- Record the batch BEFORE the aggregate fold so that if the later step errors out
    -- and the transaction is rolled back, the next retry re-runs everything cleanly.
    -- Without the insert-first pattern, a mid-function crash could commit readings
    -- but not processed_batches, causing a retry to double-count.
    INSERT INTO processed_batches (
        batch_id, device_token_hash, reading_count, accepted_count, rejected_count, rejected_reasons,
        client_sent_at, client_app_version, client_os_version
    ) VALUES (
        p_batch_id, p_device_token_hash,
        (SELECT count(*) FROM tmp_final),
        v_accepted, v_rejected, v_rejected_reasons::JSONB,
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

### Explicit Pothole Actions: `apply_pothole_action`

Manual `Mark pothole`, `Still there`, and `Looks fixed` actions all flow through one stored procedure plus an idempotent `pothole_actions` insert.

Rules:

0. same-device duplicates do not get to farm counts
   - if the same `device_token_hash` already submitted the same `action_type` against the same canonical pothole within the last `24h`, return `200` with the same canonical `pothole_report_id` but do **not** increment counters again
1. `manual_report`
   - find the nearest `pothole_reports` row within `15m` and `status IN ('active', 'resolved')`
   - if found, increment `confirmation_count`, update `last_confirmed_at`, and force `status = 'active'`
   - if not found, create a new `active` row
   - optional `sensor_backed_magnitude_g` + `sensor_backed_at` may be provided only for `manual_report`; the timestamp must be close to `recorded_at`, the magnitude must be in the accepted sensor range, and the canonical report magnitude becomes `GREATEST(existing, sensor_backed_magnitude_g)`
2. `confirm_present`
   - requires `pothole_report_id`
   - reject with `409 stale_target` if the provided coordinate is > `30m` from the target cluster geom
   - increment `confirmation_count`, update `last_confirmed_at`, and force `status = 'active'`
3. `confirm_fixed`
   - requires `pothole_report_id`
   - reject with `409 stale_target` if the provided coordinate is > `30m` from the target cluster geom
   - increment `negative_confirmation_count`, update `last_fixed_reported_at`
   - mark the report `resolved` only if there are at least **2 distinct device_token_hash** values in `pothole_actions` where:
     - `action_type = 'confirm_fixed'`
     - `pothole_report_id = target`
     - `recorded_at > pothole_reports.last_confirmed_at`
     - `recorded_at >= now() - interval '30 days'`

Important consequence: a single `Looks fixed` report never deletes the marker. A later positive confirmation (`manual_report`, `confirm_present`, passive spike, or approved photo) re-activates the same pothole row if it is still within the 90-day relevance window.

### Pothole Action Rate Limits

Explicit pothole actions get their own rate-limit bucket so they cannot starve reading uploads and so a spammy tapper cannot brute-force public pothole counts:

- **Per device token hash:** 60 pothole actions / 24h
- **Per IP:** 120 pothole actions / 1h

Reuse the existing `rate_limits` table and `check_and_bump_rate_limit` RPC with keys `pothole-action-device:<hash>` and `pothole-action-ip:<ip>`.

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
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
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
                (SELECT geom_3857 FROM bounds),
                4096, 64, true
            ) AS geom
        FROM road_segments rs
        JOIN segment_aggregates sa ON sa.segment_id = rs.id
        WHERE rs.geom && (SELECT geom_4326 FROM bounds)
          AND ST_Intersects(ST_Transform(rs.geom, 3857), (SELECT geom_3857 FROM bounds))
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
                (SELECT geom_3857 FROM bounds),
                4096, 64, true
            ) AS geom
        FROM pothole_reports pr
        WHERE pr.status = 'active'
          AND pr.geom && (SELECT geom_4326 FROM bounds)
          AND ST_Intersects(ST_Transform(pr.geom, 3857), (SELECT geom_3857 FROM bounds))
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
    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID()
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
    if (error) {
        return new Response("error", {
            status: 500,
            headers: { "x-request-id": requestId },
        })
    }
    if (!(data instanceof Uint8Array) || data.length === 0) {
        return new Response(null, {
            status: 204,
            headers: {
                "cache-control": "public, max-age=3600, s-maxage=3600",
                "x-request-id": requestId,
            },
        })
    }

    return new Response(data, {
        headers: {
            "content-type": "application/vnd.mapbox-vector-tile",
            "cache-control": "public, max-age=3600, s-maxage=3600",
            "access-control-allow-origin": "*",
            "x-request-id": requestId,
        },
    })
})
```

Supabase CDN caches these at the edge based on URL. Cache-bust after nightly recompute by including a short version suffix in the URL (`?v=<unix-day>`) — the iOS client appends this automatically.

### Coverage Tile Endpoint for Web: `GET /functions/v1/tiles/coverage/:z/:x/:y.mvt`

The standard quality tile intentionally hides low-confidence and unscored roads, so it cannot power the public web `Coverage` mode. Add a separate coverage tile RPC and Edge Function wrapper.

```sql
CREATE OR REPLACE FUNCTION get_coverage_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 10 THEN RETURN ''::bytea; END IF;

    WITH bounds AS (
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
    ),
    segments AS (
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            CASE
                WHEN sa.segment_id IS NULL OR COALESCE(sa.total_readings, 0) = 0
                    THEN 'none'
                WHEN sa.unique_contributors < 3
                    THEN 'emerging'
                WHEN sa.unique_contributors < 10
                    THEN 'published'
                ELSE 'strong'
            END AS coverage_level,
            sa.updated_at::TEXT AS updated_at,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                (SELECT geom_3857 FROM bounds),
                4096, 64, true
            ) AS geom
        FROM road_segments rs
        LEFT JOIN segment_aggregates sa ON sa.segment_id = rs.id
        WHERE rs.geom && (SELECT geom_4326 FROM bounds)
          AND ST_Intersects(ST_Transform(rs.geom, 3857), (SELECT geom_3857 FROM bounds))
          AND rs.is_parking_aisle = FALSE
          AND COALESCE(rs.surface_type, 'unknown') != 'unpaved'
          AND (
              z >= 14
              OR rs.road_type IN ('motorway','trunk','primary','secondary','tertiary',
                                   'motorway_link','trunk_link','primary_link','secondary_link')
          )
    )
    SELECT COALESCE(
        (SELECT ST_AsMVT(segments.*, 'segment_coverage', 4096, 'geom') FROM segments),
        ''::bytea
    )
    INTO v_tile;

    RETURN v_tile;
END;
$$;

REVOKE EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) TO service_role;
```

Edge Function sketch:

```typescript
// supabase/functions/tiles-coverage/index.ts — sketch
serve(async (req) => {
    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID()
    const url = new URL(req.url)
    const match = url.pathname.match(/\/coverage\/(\d+)\/(\d+)\/(\d+)\.mvt$/)
    if (!match) return new Response(null, { status: 404 })

    const [, z, x, y] = match
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    )
    const { data, error } = await supabase.rpc("get_coverage_tile", {
        z: parseInt(z), x: parseInt(x), y: parseInt(y),
    })
    if (error) {
        return new Response("error", {
            status: 500,
            headers: { "x-request-id": requestId },
        })
    }
    if (!(data instanceof Uint8Array) || data.length === 0) {
        return new Response(null, {
            status: 204,
            headers: {
                "cache-control": "public, max-age=3600, s-maxage=3600",
                "x-request-id": requestId,
            },
        })
    }
    return new Response(data, {
        headers: {
            "content-type": "application/vnd.mapbox-vector-tile",
            "cache-control": "public, max-age=3600, s-maxage=3600",
            "access-control-allow-origin": "*",
            "x-request-id": requestId,
        },
    })
})
```

### Alternative: Martin Tile Server (if Edge Function is too slow)

If Edge Function cold-start becomes painful or p95 tile latency > 300ms, migrate to [Martin](https://github.com/maplibre/martin), a Rust tile server that speaks Postgres directly. Host it on Fly.io, ~$5/month.

**Trigger for migration:** p95 tile latency > 300ms consistently for 3+ days, or error rate > 1%.

## Read API Endpoints

These are all thin Edge Function wrappers. `segments` and `potholes` can use an anon-scoped Supabase client because RLS already allows those reads. `stats`, `tiles`, `tiles/coverage`, `segments/worst`, `upload-readings`, and `health` use service role because they depend on locked RPCs, materialized views, or unauthenticated liveness checks.

### `GET /functions/v1/segments/:id`

Single joined query over `road_segments` + `segment_aggregates`, returning:

- static segment fields from `road_segments`
- aggregate fields from `segment_aggregates`
- `history: []` and `neighbors: null` as explicit MVP stubs

Return 404 if either the segment does not exist or no aggregate row exists yet.

### `GET /functions/v1/potholes?bbox=...`

Validate the bbox before touching Postgres:

- 4 comma-separated floats
- `minLng < maxLng`, `minLat < maxLat`
- max span approximately 10 km x 10 km (`maxLng - minLng <= 0.12`, `maxLat - minLat <= 0.09` at Halifax latitudes)

Then query active potholes:

```sql
SELECT
    id,
    ST_Y(geom) AS lat,
    ST_X(geom) AS lng,
    magnitude,
    confirmation_count,
    first_reported_at,
    last_confirmed_at,
    status,
    segment_id
FROM pothole_reports
WHERE status = 'active'
  AND geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
ORDER BY last_confirmed_at DESC
LIMIT 500;
```

### `GET /functions/v1/stats`

Back the public stats card with a materialized view refreshed every 5 minutes. `public_stats_mv` is MVP; `public_worst_segments_mv` (Phase 9) is defined later in the `/segments/worst` section. Each MV has its own refresh function so the two are decoupled — a slow worst-segments refresh cannot stall the stats card, and Phase-9 can ship without touching MVP cron.

```sql
CREATE MATERIALIZED VIEW public_stats_mv AS
SELECT
    1::SMALLINT AS stats_key,
    COALESCE(SUM(rs.length_m) FILTER (WHERE sa.total_readings > 0), 0)::NUMERIC(12,1) / 1000 AS total_km_mapped,
    COALESCE(SUM(sa.total_readings), 0)::BIGINT AS total_readings,
    COUNT(*) FILTER (WHERE sa.total_readings > 0)::BIGINT AS segments_scored,
    (SELECT COUNT(*) FROM pothole_reports WHERE status = 'active')::BIGINT AS active_potholes,
    COUNT(DISTINCT rs.municipality) FILTER (WHERE sa.total_readings > 0)::BIGINT AS municipalities_covered,
    now() AS generated_at
FROM road_segments rs
LEFT JOIN segment_aggregates sa ON sa.segment_id = rs.id;

-- Unique index required for REFRESH MATERIALIZED VIEW CONCURRENTLY.
-- Use a real singleton column; an expression index on ((1)) is not accepted by
-- Postgres for concurrent MV refresh.
CREATE UNIQUE INDEX public_stats_mv_singleton ON public_stats_mv (stats_key);
```

The refresh cron for `public_stats_mv` is scheduled in Migration 011 alongside the other MVP cron jobs. Schedule the SQL command directly:

```sql
SELECT cron.schedule(
    'refresh-public-stats-mv',
    '2-57/5 * * * *',
    $$REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv$$
);
```

`CONCURRENTLY` cannot live inside a PL/pgSQL function wrapper because Postgres rejects that command inside a transaction block. `GET /stats` reads `public_stats_mv`. `GET /segments/worst` (Phase 9) reads `public_worst_segments_mv`.

### `GET /functions/v1/segments/worst?municipality=...&limit=...`

Thin wrapper over `public_worst_segments_mv` for the web `Worst Roads` report. This endpoint and its backing MV ship with **Phase 9** (web dashboard).

```sql
-- Phase 9: worst-segments MV + direct cron refresh
CREATE MATERIALIZED VIEW public_worst_segments_mv AS
SELECT
    rs.id AS segment_id,
    rs.road_name,
    rs.municipality,
    rs.road_type,
    sa.roughness_category::text AS category,
    sa.confidence::text AS confidence,
    sa.avg_roughness_score,
    sa.score_last_30d,
    sa.score_30_60d,
    sa.trend::text AS trend,
    sa.total_readings,
    sa.unique_contributors,
    sa.pothole_count,
    sa.last_reading_at,
    now() AS generated_at
FROM road_segments rs
JOIN segment_aggregates sa ON sa.segment_id = rs.id
WHERE sa.unique_contributors >= 3
  AND sa.confidence != 'low'
  AND sa.roughness_category NOT IN ('unscored', 'unpaved');

-- Unique index required for REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX idx_public_worst_segments_mv_segment_id
    ON public_worst_segments_mv (segment_id);

CREATE INDEX idx_public_worst_segments_mv_municipality_score
    ON public_worst_segments_mv (municipality, avg_roughness_score DESC);

CREATE INDEX idx_public_worst_segments_mv_score
    ON public_worst_segments_mv (avg_roughness_score DESC);

-- Worst-segments doesn't need 5-minute freshness; every 15 min is plenty.
-- Offset from stats refresh to avoid stacking CPU.
SELECT cron.schedule(
    'refresh-public-worst-segments-mv',
    '7-52/15 * * * *',
    $$REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv$$
);
```

As with `public_stats_mv`, do **not** wrap `REFRESH MATERIALIZED VIEW CONCURRENTLY` in a PL/pgSQL function. Postgres rejects that command inside a transaction block, so the cron entry runs the refresh SQL directly.

Validation rules:

- `limit` required, integer, `1 <= limit <= 100`
- `municipality` optional exact display name; reject unknown names with 400 instead of silently returning empty rows

Query:

```sql
WITH filtered AS (
    SELECT *
    FROM public_worst_segments_mv
    WHERE ($1::TEXT IS NULL OR municipality = $1)
    ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC
    LIMIT $2
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC
    )::INT AS rank,
    segment_id,
    road_name,
    municipality,
    road_type,
    category,
    confidence,
    avg_roughness_score,
    score_last_30d,
    score_30_60d,
    trend,
    total_readings,
    unique_contributors,
    pothole_count,
    last_reading_at,
    generated_at
FROM filtered;
```

### `GET /functions/v1/health`

The only unauthenticated endpoint. It proves the DB is reachable and returns deploy metadata from env vars:

```sql
CREATE OR REPLACE FUNCTION db_healthcheck()
RETURNS TIMESTAMPTZ
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$SELECT now();$$;

REVOKE EXECUTE ON FUNCTION db_healthcheck() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION db_healthcheck() TO service_role;
```

Health Edge Function sketch:

```typescript
serve(async () => {
    const requestId = crypto.randomUUID()
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    )
    const { data, error } = await supabase.rpc("db_healthcheck")
    if (error) {
        return jsonResponse(
            { status: "error", db: "unreachable", request_id: requestId },
            503,
            {},
            requestId,
        )
    }
    return jsonResponse(
        {
            status: "ok",
            version: Deno.env.get("APP_VERSION"),
            commit: Deno.env.get("GIT_SHA"),
            deployed_at: Deno.env.get("DEPLOYED_AT"),
            db: "reachable",
            db_time: data,
        },
        200,
        {},
        requestId,
    )
})
```

## Nightly Aggregate Recompute

Full recompute with outlier trimming, trend calculation, and score decay.

```sql
CREATE OR REPLACE FUNCTION nightly_recompute_aggregates(
    p_segment_ids UUID[] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Default mode: recompute segments that had activity in the last 24h.
    -- Refresh mode: caller passes the exact touched segment IDs from
    -- rematch_readings_after_segment_refresh().
    WITH target_segments AS (
        SELECT DISTINCT segment_id
        FROM readings
        WHERE p_segment_ids IS NULL
          AND uploaded_at > now() - INTERVAL '24 hours'
          AND segment_id IS NOT NULL
        UNION
        SELECT DISTINCT unnest(p_segment_ids)
        WHERE p_segment_ids IS NOT NULL
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
        WHERE r.segment_id IN (SELECT segment_id FROM target_segments)
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

-- Lock down execution: this is a heavy batch job, scheduled by pg_cron in
-- steady state and manually invoked only during controlled OSM refreshes.
-- Without REVOKE + GRANT, PostgREST exposes it to anon via
-- /rest/v1/rpc/nightly_recompute_aggregates and a single POST with the
-- shipped anon key kicks a full aggregate recompute — cheap DoS.
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) TO service_role;
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

Post-MVP: add "road repaired" auto-detection — if 2+ contributors report smooth readings at a pothole location, treat that as another negative confirmation input alongside explicit `confirm_fixed` actions.

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
   - Plan: `geom && tile_bbox_4326` as the indexable prefilter, then `ST_Intersects(ST_Transform(geom,3857), tile_bbox_3857)` for exact clipping
   - Target: < 100ms per tile on warm cache, served from Supabase CDN on subsequent hits

3. **Segment detail** (single segment lookup)
   - Index: PK on `segment_aggregates.segment_id`
   - Target: < 10ms

Run `EXPLAIN ANALYZE` on the ingestion match query after first 100k readings exist — if any reading processing exceeds 50ms, add `segment_bbox` materialized view or reduce KNN candidates to 1.

## Backend Decisions and Deferred Optimizations

- **Keep `readings.location` as `GEOMETRY(4326)`.** Cast to geography only where meter-based calculations are needed.
- **Do not add a Halifax-only tile materialized view unless measurement proves it is needed.**
- **Do not migrate to Martin preemptively.** Follow the documented latency/error trigger first.
- **Do not add a monthly salt to `device_token_hash`.** The current constant-pepper approach is the correct tradeoff for weekly per-device caps and monthly client-side rotation.

## Pothole Photo Moderation (Post-MVP)

*Status: implemented end-to-end in the current build for the internal moderation workflow: `pothole_photos` schema, private Storage bucket, `POST /pothole-photos` signed-upload endpoint, rate limiting, cron-based promotion from `pending_upload` to `pending_moderation`, moderation queue view, approve/reject procedures, signed image preview, and publishing/rejection storage actions. The current build also hardens the path with single-write signed upload URLs (`upsert: false`), `segment_id` persistence from iOS, moderation move rollback on failed approval RPCs, reject-before-delete ordering, `security_invoker` on the moderation queue view, and a geography index for the approval-path nearby lookup.*

This section covers the server half of the photo capture feature: storage, moderation queue, and publishing flow.

### Storage Bucket

One Supabase Storage bucket, `pothole-photos`, with:

- **Access:** private by default. Reads for the moderation tool go through a dedicated internal-only `pothole-photo-image` Edge Function that enforces moderation status and emits signed read URLs with a short TTL (60s). This is **not** part of the public mobile API contract in [03-api-contracts.md](03-api-contracts.md).
- **Write path:** signed PUT URLs issued by `POST /pothole-photos` (see [03-api-contracts.md](03-api-contracts.md)). In practice these are treated as ~2 hour Supabase signed upload URLs and can only write to `pending/{report_id}.jpg`. URLs are issued with `upsert: false`, so the object path is single-write; repeating the metadata POST while the row is still `pending_upload` reissues a fresh signed URL only until the object actually exists.
- **Max object size:** 1.5 MB enforced at the bucket level. Client target is ≤ 400 KB; the extra headroom tolerates compression variance. Anything larger is a bug or abuse.
- **Content-Type allowlist:** `image/jpeg` only. HEIC is converted to JPEG client-side before upload.

On successful upload, a Storage webhook (or a one-minute `pg_cron` scan if webhooks are unavailable) promotes the row from `pending_upload` to `pending_moderation`. Approvals move the object to `published/{report_id}.jpg`; rejections delete the object from Storage immediately.

### Migration 017 — `pothole_photos`

```sql
CREATE TYPE pothole_photo_status AS ENUM (
    'pending_upload',     -- row created, object not yet in storage
    'pending_moderation', -- object in storage, awaiting human review
    'approved',           -- visible on the map
    'rejected',           -- failed moderation, object deleted
    'expired'             -- auto-expired after 90d without confirmation (same rules as pothole_reports)
);

CREATE TABLE pothole_photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL UNIQUE,               -- client-generated, used in URLs and idempotency
    device_token_hash BYTEA NOT NULL,
    segment_id UUID REFERENCES road_segments(id) ON DELETE SET NULL,
    pothole_report_id UUID REFERENCES pothole_reports(id) ON DELETE SET NULL,
    geom GEOMETRY(POINT, 4326) NOT NULL,          -- precise client coordinate after privacy-zone filtering
    accuracy_m NUMERIC(5,2),
    captured_at TIMESTAMPTZ NOT NULL,
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    uploaded_at TIMESTAMPTZ,
    reviewed_at TIMESTAMPTZ,
    reviewed_by TEXT,                             -- moderator identifier, null until reviewed
    status pothole_photo_status NOT NULL DEFAULT 'pending_upload',
    storage_object_path TEXT NOT NULL,            -- e.g., pending/{report_id}.jpg
    content_sha256 BYTEA NOT NULL,                -- supplied by client for idempotency / metadata-consistency checks
    byte_size INTEGER NOT NULL,
    rejection_reason TEXT
);

CREATE INDEX idx_pothole_photos_geom   ON pothole_photos USING GIST (geom);
CREATE INDEX idx_pothole_photos_status ON pothole_photos (status);
CREATE INDEX idx_pothole_photos_device ON pothole_photos (device_token_hash, submitted_at DESC);
```

**Relationship to `pothole_reports`:** an approved photo that matches (or creates) a nearby pothole cluster links back via `pothole_report_id`. The existing pothole folding logic (see Migration 012) is extended: a photo's `geom` participates in the same 15m-radius cluster merge as accelerometer-detected pothole points and manual pothole actions, and the resulting `pothole_reports` row carries `has_photo = true`. The public map uses the merged `pothole_reports` point, not the raw `pothole_photos.geom`.

### Moderation Tooling

MVP moderation is deliberately low-tech: a Supabase Studio view (`moderation_pothole_photo_queue`) showing the `pending_moderation` queue sorted by `submitted_at ASC`, with:

- the image (fetched via the internal `pothole-photo-image` function)
- the reported lat/lng pinned on a small map
- approve / reject actions wired through the internal `pothole-photo-moderation` function, which coordinates Storage move/delete with the SQL procedures, including rollback on failed approve RPCs and delete-after-state-change ordering on reject

The view now runs with `security_invoker = true`, so future narrower moderation roles inherit table-level access rules rather than silently bypassing them through a definer-owned view.

No ML classifier in MVP. The moderation policy (spec-driven, not code-driven) is:

| Keep if | Reject if |
|---|---|
| Image clearly shows road damage | Image contains faces, license plates, house numbers in close-up |
| Location in Nova Scotia | Image is indoors, not a road, or is obviously a joke/test |
| No people identifiable | Image is blurred to the point of being unreadable |

Rejections delete the storage object immediately. The client is not told why.

### Rate Limits

Photo submissions get their own rate-limit bucket (separate from reading batches so a spammy reporter does not poison readings uploads):

- **Per device token hash:** 20 photo submissions / 24h
- **Per IP:** 40 photo submissions / 1h

Both buckets reuse the existing `rate_limits` table and `check_and_bump_rate_limit` RPC with keys `pothole-photo-device:<hash>` and `pothole-photo-ip:<ip>`.

### RLS

- Anon can read `status = 'approved'` rows only.
- No anon writes; only the `/functions/v1/pothole-photos` Edge Function (service role) inserts and updates.
- Moderators use the service role key via the Supabase Studio UI; there is no moderator user auth flow in MVP. Rotate the service role key if a moderator leaves.

### Not In MVP

- Automatic image classification (CLIP / dedicated pothole classifier). Human moderation is fine for TestFlight volume (< 200 photos/week).
- Reverse geocoding display names on the server. The client already knows the road name from the nearest segment.
- Per-municipality moderator assignment. Single moderator queue for the beta.
