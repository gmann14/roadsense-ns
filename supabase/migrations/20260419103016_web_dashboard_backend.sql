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
            sa.updated_at::TEXT AS updated_at,
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
    sa.last_reading_at,
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

DO $jobs$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid INTO v_job_id
    FROM cron.job
    WHERE jobname = 'refresh-public-worst-segments-mv';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
        'refresh-public-worst-segments-mv',
        '7-52/15 * * * *',
        $cmd$REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv$cmd$
    );
END;
$jobs$;
