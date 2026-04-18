CREATE MATERIALIZED VIEW IF NOT EXISTS public_stats_mv AS
SELECT
    1::SMALLINT AS stats_key,
    COALESCE(SUM(rs.length_m) FILTER (WHERE sa.total_readings > 0), 0)::NUMERIC(12,1) / 1000 AS total_km_mapped,
    COALESCE(SUM(sa.total_readings), 0)::BIGINT AS total_readings,
    COUNT(*) FILTER (WHERE sa.total_readings > 0)::BIGINT AS segments_scored,
    (SELECT COUNT(*) FROM pothole_reports WHERE status = 'active')::BIGINT AS active_potholes,
    COUNT(DISTINCT rs.municipality) FILTER (WHERE sa.total_readings > 0)::BIGINT AS municipalities_covered,
    now() AS generated_at
FROM road_segments rs
LEFT JOIN segment_aggregates sa
  ON sa.segment_id = rs.id;

CREATE UNIQUE INDEX IF NOT EXISTS public_stats_mv_singleton
    ON public_stats_mv (stats_key);

GRANT SELECT ON public_stats_mv TO service_role;

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
        pr.first_reported_at,
        pr.last_confirmed_at,
        pr.status,
        pr.segment_id
    FROM pothole_reports pr
    WHERE pr.status = 'active'
      AND pr.geom && ST_MakeEnvelope(p_min_lng, p_min_lat, p_max_lng, p_max_lat, 4326)
    ORDER BY pr.last_confirmed_at DESC
    LIMIT 500;
$$;

CREATE OR REPLACE FUNCTION db_healthcheck()
RETURNS TIMESTAMPTZ
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$SELECT now();$$;

REVOKE EXECUTE ON FUNCTION db_healthcheck() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION db_healthcheck() FROM anon;
REVOKE EXECUTE ON FUNCTION db_healthcheck() FROM authenticated;
GRANT EXECUTE ON FUNCTION db_healthcheck() TO service_role;

REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM anon;
REVOKE EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_potholes_in_bbox(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) TO service_role;

DO $jobs$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid INTO v_job_id
    FROM cron.job
    WHERE jobname = 'refresh-public-stats-mv';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

    PERFORM cron.schedule(
        'refresh-public-stats-mv',
        '2-57/5 * * * *',
        $cmd$REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv$cmd$
    );
END;
$jobs$;
