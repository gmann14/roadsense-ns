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
        pr.first_reported_at,
        pr.last_confirmed_at,
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
REVOKE EXECUTE ON FUNCTION get_top_potholes(INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION get_top_potholes(INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO anon;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_top_potholes(INTEGER) TO service_role;
