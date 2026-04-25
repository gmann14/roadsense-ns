DROP MATERIALIZED VIEW IF EXISTS public_stats_mv;

CREATE MATERIALIZED VIEW public_stats_mv AS
WITH scored_segments AS (
    SELECT
        rs.geom,
        rs.length_m,
        rs.municipality,
        sa.total_readings
    FROM road_segments rs
    JOIN segment_aggregates sa
      ON sa.segment_id = rs.id
    WHERE sa.total_readings > 0
),
stats AS (
    SELECT
        COALESCE(SUM(length_m), 0)::NUMERIC(12,1) / 1000 AS total_km_mapped,
        COALESCE(SUM(total_readings), 0)::BIGINT AS total_readings,
        COUNT(*)::BIGINT AS segments_scored,
        COUNT(DISTINCT municipality)::BIGINT AS municipalities_covered
    FROM scored_segments
),
scored_bounds AS (
    SELECT ST_Extent(geom) AS bbox
    FROM scored_segments
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
        WHEN pothole_totals.bbox IS NULL THEN NULL
        ELSE jsonb_build_object(
            'minLng', ST_XMin(pothole_totals.bbox),
            'minLat', ST_YMin(pothole_totals.bbox),
            'maxLng', ST_XMax(pothole_totals.bbox),
            'maxLat', ST_YMax(pothole_totals.bbox)
        )
    END AS pothole_bounds,
    now() AS generated_at
FROM stats
CROSS JOIN scored_bounds
CROSS JOIN pothole_totals;

CREATE UNIQUE INDEX public_stats_mv_singleton
    ON public_stats_mv (stats_key);

GRANT SELECT ON public_stats_mv TO service_role;

CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
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
          AND z >= 12
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
