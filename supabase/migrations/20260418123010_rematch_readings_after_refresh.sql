CREATE OR REPLACE FUNCTION rematch_readings_after_segment_refresh(
    p_since TIMESTAMPTZ DEFAULT now() - INTERVAL '6 months'
)
RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_touched UUID[];
BEGIN
    WITH matched AS (
        SELECT
            r.recorded_at AS reading_recorded_at,
            r.id AS reading_id,
            r.segment_id AS old_segment_id,
            m.segment_id AS new_segment_id
        FROM readings r
        LEFT JOIN LATERAL (
            SELECT *
            FROM (
                SELECT
                    rs.id AS segment_id,
                    ST_Distance(rs.geom::geography, r.location::geography) AS distance_m,
                    ABS(
                        ((COALESCE(r.heading_degrees, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
                    ) AS heading_diff
                FROM road_segments rs
                WHERE ST_DWithin(rs.geom::geography, r.location::geography, 25)
                  AND rs.is_parking_aisle = FALSE
                  AND COALESCE(rs.surface_type, 'unknown') IN ('paved', 'asphalt', 'concrete', 'paving_stones')
                ORDER BY rs.geom::geography <-> r.location::geography
                LIMIT 3
            ) candidates
            WHERE candidates.distance_m <= 20
              AND (candidates.heading_diff <= 45 OR candidates.heading_diff >= 135)
            ORDER BY candidates.distance_m
            LIMIT 1
        ) m ON TRUE
        WHERE r.recorded_at >= p_since
    ),
    changed AS (
        SELECT *
        FROM matched
        WHERE old_segment_id IS DISTINCT FROM new_segment_id
    ),
    upd AS (
        UPDATE readings r
        SET segment_id = c.new_segment_id
        FROM changed c
        WHERE r.recorded_at = c.reading_recorded_at
          AND r.id = c.reading_id
        RETURNING c.old_segment_id, c.new_segment_id
    )
    SELECT ARRAY(
        SELECT DISTINCT sid
        FROM (
            SELECT old_segment_id AS sid FROM upd
            UNION
            SELECT new_segment_id AS sid FROM upd
        ) touched
        WHERE sid IS NOT NULL
    ) INTO v_touched;

    RAISE NOTICE 'rematch_readings_after_segment_refresh: % segments touched',
        COALESCE(array_length(v_touched, 1), 0);

    RETURN COALESCE(v_touched, ARRAY[]::UUID[]);
END;
$$;

REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM anon;
REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM authenticated;
GRANT EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) TO service_role;
