DROP MATERIALIZED VIEW IF EXISTS public_stats_mv;

CREATE MATERIALIZED VIEW public_stats_mv AS
WITH scored_segments AS (
    SELECT
        rs.geom,
        rs.length_m,
        rs.municipality,
        sa.total_readings,
        ST_X(ST_Centroid(rs.geom)) AS center_lng,
        ST_Y(ST_Centroid(rs.geom)) AS center_lat
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
focus_percentiles AS (
    SELECT
        COUNT(*)::BIGINT AS segment_count,
        percentile_disc(0.01) WITHIN GROUP (ORDER BY center_lng) AS min_focus_lng,
        percentile_disc(0.99) WITHIN GROUP (ORDER BY center_lng) AS max_focus_lng,
        percentile_disc(0.01) WITHIN GROUP (ORDER BY center_lat) AS min_focus_lat,
        percentile_disc(0.99) WITHIN GROUP (ORDER BY center_lat) AS max_focus_lat
    FROM scored_segments
),
focus_segments AS (
    SELECT scored_segments.geom
    FROM scored_segments
    CROSS JOIN focus_percentiles
    WHERE focus_percentiles.segment_count < 100
       OR (
            scored_segments.center_lng BETWEEN focus_percentiles.min_focus_lng AND focus_percentiles.max_focus_lng
        AND scored_segments.center_lat BETWEEN focus_percentiles.min_focus_lat AND focus_percentiles.max_focus_lat
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
    now() AS generated_at
FROM stats
CROSS JOIN scored_bounds
CROSS JOIN focus_bounds
CROSS JOIN pothole_totals;

CREATE UNIQUE INDEX public_stats_mv_singleton
    ON public_stats_mv (stats_key);

GRANT SELECT ON public_stats_mv TO service_role;
GRANT SELECT ON public_stats_mv TO anon;
GRANT SELECT ON public_stats_mv TO authenticated;
