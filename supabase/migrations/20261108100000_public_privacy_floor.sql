-- P0-5 (docs/reviews/2026-10-18-full-codebase-review.md): public read models
-- have no k-anonymity floor and expose timestamps to the second.
--
-- With a small beta cohort, a segment scored by one or two devices is a
-- trace of those people's drives, and a to-the-second `updated_at` /
-- `last_confirmed_at` lets anyone line a tile up with a specific trip. This
-- migration puts every public read model back behind the project's own
-- aggregate-privacy rule:
--
-- 1. `get_tile` (segment_aggregates layer): restores the original
--    `unique_contributors >= 3` floor that 20260424213000 relaxed for
--    bootstrap visibility. Low-*confidence* segments stay visible (the
--    confidence tier is presentation), but a segment needs three distinct
--    contributors before it is published at all. Redefined from the latest
--    body (20260506193000_filter_bike_pothole_reports.sql); the zoom rules,
--    road-type filters and the potholes layer are unchanged. The
--    `quality_corridors` layer stays gone (the web no longer requests it).
-- 2. `get_coverage_tile`: drops the `updated_at` attribute (it was the
--    aggregate's last write time, to the second). Redefined from
--    20260419103016_web_dashboard_backend.sql, otherwise unchanged.
-- 3. `get_potholes_in_bbox` / `get_top_potholes`: `first_reported_at` and
--    `last_confirmed_at` are truncated to the UTC day. Return types are
--    unchanged (still TIMESTAMPTZ) so the gateway's row normalisers keep
--    working.
-- 4. `public_worst_segments_mv`: `last_reading_at` truncated to the UTC day.
-- 5. `public_stats_mv`:
--    - new `data_updated_at`: the UTC day of the newest reading on any
--      publicly visible (>= 3 contributor) segment. `generated_at` is the
--      materialized-view refresh time, which is why the web freshness pill
--      always said "Updated today".
--    - `map_bounds` / `focus_bounds` are computed from publicly visible
--      segments only, so the bounding box can't reveal where a single
--      driver went. Whole-province totals (km, readings, segments,
--      municipalities) keep counting every scored segment, per the
--      three-layer aggregate rule (an all-NS total is a Layer 1 aggregate).
--    - `total_km_mapped` is re-summed from the length backfill in
--      20261108090000.

CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 6 THEN
        RETURN ''::BYTEA;
    END IF;

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
            sa.roughness_category::TEXT AS category,
            sa.confidence::TEXT AS confidence,
            sa.total_readings,
            sa.unique_contributors,
            sa.pothole_count,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN road_segments rs
          ON rs.geom && b.geom_4326
        JOIN segment_aggregates sa
          ON sa.segment_id = rs.id
        WHERE ST_Intersects(ST_Transform(rs.geom, 3857), b.geom_3857)
          AND rs.is_parking_aisle = FALSE
          AND sa.total_readings > 0
          -- P0-5: k-anonymity floor. Never publish a segment that fewer than
          -- three distinct devices have driven.
          AND sa.unique_contributors >= 3
          AND CASE
              WHEN z < 12 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link'
              )
              WHEN z < 14 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link'
              )
              ELSE TRUE
          END
    ),
    potholes AS (
        SELECT
            pr.id,
            pr.magnitude,
            pr.confirmation_count,
            ST_AsMVTGeom(
                ST_Transform(pr.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN pothole_reports pr
          ON pr.geom && b.geom_4326
        WHERE pr.status = 'active'
          AND z >= 8
          AND ST_Intersects(ST_Transform(pr.geom, 3857), b.geom_3857)
    )
    SELECT
        COALESCE(
            (
                SELECT ST_AsMVT(segment_rows.*, 'segment_aggregates', 4096, 'geom')
                FROM segments AS segment_rows
            ),
            ''::BYTEA
        ) ||
        COALESCE(
            (
                SELECT ST_AsMVT(pothole_rows.*, 'potholes', 4096, 'geom')
                FROM potholes AS pothole_rows
            ),
            ''::BYTEA
        )
    INTO v_tile;

    RETURN COALESCE(v_tile, ''::BYTEA);
END;
$$;

REVOKE EXECUTE ON FUNCTION get_tile(INT, INT, INT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_tile(INT, INT, INT) FROM anon;
REVOKE EXECUTE ON FUNCTION get_tile(INT, INT, INT) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_tile(INT, INT, INT) TO service_role;

CREATE OR REPLACE FUNCTION get_coverage_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 10 THEN
        RETURN ''::BYTEA;
    END IF;

    WITH bounds AS (
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
    ),
    segments AS (
        -- P0-5: the to-the-second `updated_at` attribute is gone.
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            CASE
                WHEN sa.segment_id IS NULL OR COALESCE(sa.total_readings, 0) = 0 THEN 'none'
                WHEN sa.unique_contributors < 3 THEN 'emerging'
                WHEN sa.unique_contributors < 10 THEN 'published'
                ELSE 'strong'
            END AS coverage_level,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN road_segments rs
          ON rs.geom && b.geom_4326
        LEFT JOIN segment_aggregates sa
          ON sa.segment_id = rs.id
        WHERE ST_Intersects(ST_Transform(rs.geom, 3857), b.geom_3857)
          AND rs.is_parking_aisle = FALSE
          AND COALESCE(rs.surface_type, 'unknown') != 'unpaved'
          AND CASE
              WHEN z < 14 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link'
              )
              ELSE TRUE
          END
    )
    SELECT COALESCE(
        (
            SELECT ST_AsMVT(segment_rows.*, 'segment_coverage', 4096, 'geom')
            FROM segments AS segment_rows
        ),
        ''::BYTEA
    )
    INTO v_tile;

    RETURN COALESCE(v_tile, ''::BYTEA);
END;
$$;

REVOKE EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) FROM anon;
REVOKE EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_coverage_tile(INT, INT, INT) TO service_role;

CREATE OR REPLACE FUNCTION get_potholes_in_bbox(
    p_min_lng DOUBLE PRECISION,
    p_min_lat DOUBLE PRECISION,
    p_max_lng DOUBLE PRECISION,
    p_max_lat DOUBLE PRECISION
)
RETURNS TABLE (
    id UUID,
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    magnitude NUMERIC(4,2),
    confirmation_count INTEGER,
    first_reported_at TIMESTAMPTZ,
    last_confirmed_at TIMESTAMPTZ,
    status pothole_status,
    segment_id UUID
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT
        pr.id,
        ST_Y(pr.geom) AS lat,
        ST_X(pr.geom) AS lng,
        pr.magnitude,
        pr.confirmation_count,
        -- P0-5: public timestamps are day-granular.
        date_trunc('day', pr.first_reported_at, 'UTC') AS first_reported_at,
        date_trunc('day', pr.last_confirmed_at, 'UTC') AS last_confirmed_at,
        pr.status,
        pr.segment_id
    FROM pothole_reports pr
    WHERE pr.status = 'active'
      AND pr.geom && ST_MakeEnvelope(p_min_lng, p_min_lat, p_max_lng, p_max_lat, 4326)
    ORDER BY pr.last_confirmed_at DESC
    LIMIT 500;
$$;

REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM anon;
REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO service_role;

CREATE OR REPLACE FUNCTION get_top_potholes(
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    id UUID,
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION,
    magnitude NUMERIC(4,2),
    confirmation_count INTEGER,
    first_reported_at TIMESTAMPTZ,
    last_confirmed_at TIMESTAMPTZ,
    status pothole_status,
    segment_id UUID
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT
        pr.id,
        ST_Y(pr.geom) AS lat,
        ST_X(pr.geom) AS lng,
        pr.magnitude,
        pr.confirmation_count,
        -- P0-5: public timestamps are day-granular.
        date_trunc('day', pr.first_reported_at, 'UTC') AS first_reported_at,
        date_trunc('day', pr.last_confirmed_at, 'UTC') AS last_confirmed_at,
        pr.status,
        pr.segment_id
    FROM pothole_reports pr
    WHERE pr.status = 'active'
    ORDER BY
        pr.confirmation_count DESC,
        pr.magnitude DESC,
        pr.last_confirmed_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
$$;

REVOKE EXECUTE ON FUNCTION get_top_potholes(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO service_role;

-- public_worst_segments_mv: same definition as 20260419103016 except the
-- day-truncated last_reading_at. It already enforced unique_contributors >= 3.
DROP MATERIALIZED VIEW IF EXISTS public_worst_segments_mv;

CREATE MATERIALIZED VIEW public_worst_segments_mv AS
SELECT
    rs.id AS segment_id,
    rs.road_name,
    rs.municipality,
    rs.road_type,
    sa.roughness_category::TEXT AS category,
    sa.confidence::TEXT AS confidence,
    sa.avg_roughness_score,
    sa.score_last_30d,
    sa.score_30_60d,
    sa.trend::TEXT AS trend,
    sa.total_readings,
    sa.unique_contributors,
    sa.pothole_count,
    date_trunc('day', sa.last_reading_at, 'UTC') AS last_reading_at,
    now() AS generated_at
FROM road_segments rs
JOIN segment_aggregates sa
  ON sa.segment_id = rs.id
WHERE sa.unique_contributors >= 3
  AND sa.confidence != 'low'
  AND sa.roughness_category NOT IN ('unscored', 'unpaved')
  AND COALESCE(rs.surface_type, 'unknown') != 'unpaved'
  AND rs.is_parking_aisle = FALSE;

CREATE UNIQUE INDEX idx_public_worst_segments_mv_segment_id
    ON public_worst_segments_mv (segment_id);

CREATE INDEX idx_public_worst_segments_mv_municipality_score
    ON public_worst_segments_mv (municipality, avg_roughness_score DESC, pothole_count DESC, total_readings DESC);

CREATE INDEX idx_public_worst_segments_mv_score
    ON public_worst_segments_mv (avg_roughness_score DESC, pothole_count DESC, total_readings DESC);

REVOKE ALL ON public_worst_segments_mv FROM PUBLIC;
REVOKE ALL ON public_worst_segments_mv FROM anon;
REVOKE ALL ON public_worst_segments_mv FROM authenticated;
GRANT SELECT ON public_worst_segments_mv TO service_role;

-- public_stats_mv: redefinition of 20260506152000 with data_updated_at and
-- k-anonymous bounds (see header).
DROP MATERIALIZED VIEW IF EXISTS public_stats_mv;

CREATE MATERIALIZED VIEW public_stats_mv AS
WITH scored_segments AS (
    SELECT
        rs.geom,
        rs.length_m,
        rs.municipality,
        sa.total_readings,
        sa.unique_contributors,
        sa.last_reading_at,
        ST_X(ST_Centroid(rs.geom)) AS center_lng,
        ST_Y(ST_Centroid(rs.geom)) AS center_lat
    FROM road_segments rs
    JOIN segment_aggregates sa
      ON sa.segment_id = rs.id
    WHERE sa.total_readings > 0
),
public_segments AS (
    -- Same k-anonymity floor as get_tile: only geometry the public map can
    -- actually show is allowed to shape the published bounding boxes.
    SELECT *
    FROM scored_segments
    WHERE unique_contributors >= 3
),
stats AS (
    SELECT
        COALESCE(SUM(length_m), 0)::NUMERIC(12,1) / 1000 AS total_km_mapped,
        COALESCE(SUM(total_readings), 0)::BIGINT AS total_readings,
        COUNT(*)::BIGINT AS segments_scored,
        COUNT(DISTINCT municipality)::BIGINT AS municipalities_covered
    FROM scored_segments
),
public_freshness AS (
    SELECT date_trunc('day', MAX(last_reading_at), 'UTC') AS data_updated_at
    FROM public_segments
),
scored_bounds AS (
    SELECT ST_Extent(geom) AS bbox
    FROM public_segments
),
focus_percentiles AS (
    SELECT
        COUNT(*)::BIGINT AS segment_count,
        percentile_disc(0.01) WITHIN GROUP (ORDER BY center_lng) AS min_focus_lng,
        percentile_disc(0.99) WITHIN GROUP (ORDER BY center_lng) AS max_focus_lng,
        percentile_disc(0.01) WITHIN GROUP (ORDER BY center_lat) AS min_focus_lat,
        percentile_disc(0.99) WITHIN GROUP (ORDER BY center_lat) AS max_focus_lat
    FROM public_segments
),
focus_segments AS (
    SELECT public_segments.geom
    FROM public_segments
    CROSS JOIN focus_percentiles
    WHERE focus_percentiles.segment_count < 100
       OR (
            public_segments.center_lng BETWEEN focus_percentiles.min_focus_lng AND focus_percentiles.max_focus_lng
        AND public_segments.center_lat BETWEEN focus_percentiles.min_focus_lat AND focus_percentiles.max_focus_lat
       )
),
focus_bounds AS (
    SELECT ST_Extent(geom) AS bbox
    FROM focus_segments
),
pothole_totals AS (
    SELECT
        COUNT(*)::BIGINT AS active_potholes,
        ST_Extent(geom) AS bbox
    FROM pothole_reports
    WHERE status = 'active'
)
SELECT
    1::SMALLINT AS stats_key,
    stats.total_km_mapped,
    stats.total_readings,
    stats.segments_scored,
    pothole_totals.active_potholes,
    stats.municipalities_covered,
    CASE
        WHEN scored_bounds.bbox IS NULL THEN NULL
        ELSE jsonb_build_object(
            'minLng', ST_XMin(scored_bounds.bbox),
            'minLat', ST_YMin(scored_bounds.bbox),
            'maxLng', ST_XMax(scored_bounds.bbox),
            'maxLat', ST_YMax(scored_bounds.bbox)
        )
    END AS map_bounds,
    CASE
        WHEN COALESCE(focus_bounds.bbox, scored_bounds.bbox) IS NULL THEN NULL
        ELSE jsonb_build_object(
            'minLng', ST_XMin(COALESCE(focus_bounds.bbox, scored_bounds.bbox)),
            'minLat', ST_YMin(COALESCE(focus_bounds.bbox, scored_bounds.bbox)),
            'maxLng', ST_XMax(COALESCE(focus_bounds.bbox, scored_bounds.bbox)),
            'maxLat', ST_YMax(COALESCE(focus_bounds.bbox, scored_bounds.bbox))
        )
    END AS focus_bounds,
    CASE
        WHEN pothole_totals.bbox IS NULL THEN NULL
        ELSE jsonb_build_object(
            'minLng', ST_XMin(pothole_totals.bbox),
            'minLat', ST_YMin(pothole_totals.bbox),
            'maxLng', ST_XMax(pothole_totals.bbox),
            'maxLat', ST_YMax(pothole_totals.bbox)
        )
    END AS pothole_bounds,
    public_freshness.data_updated_at,
    now() AS generated_at
FROM stats
CROSS JOIN public_freshness
CROSS JOIN scored_bounds
CROSS JOIN focus_bounds
CROSS JOIN pothole_totals;

CREATE UNIQUE INDEX public_stats_mv_singleton
    ON public_stats_mv (stats_key);

GRANT SELECT ON public_stats_mv TO service_role;
GRANT SELECT ON public_stats_mv TO anon;
GRANT SELECT ON public_stats_mv TO authenticated;
