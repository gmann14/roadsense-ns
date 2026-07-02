-- P1: Web-Mercator segment lengths overstate ~40% at Nova Scotia latitude.
--
-- stage_osm_segments() (current live body: 20260424192500_fix_stage_osm_segments_way_id.sql,
-- originally 20260418110009_road_segment_refresh.sql) computed both the
-- persisted `length_m`/`len_m` AND the 50m cut-fraction denominators from
-- `ST_Length(ST_Transform(w.geom, 3857))`. Web Mercator distances are scaled
-- by 1/cos(latitude) relative to true ground distance; at Nova Scotia's
-- ~44-46 degN this is roughly a 1.40-1.44x inflation (~40-44% overstatement),
-- so every persisted segment length and every "50m" cut point was wrong by
-- that factor — segments were both mis-measured and mis-sized.
--
-- Fix: measure length with `ST_Length(w.geom::geography)`, which is accurate
-- in meters regardless of latitude (geography uses a spheroidal calculation,
-- not a planar projection). The cut still has to happen on a planar geometry
-- (ST_LineSubstring needs linear-referenced fractions, which geography does
-- not support directly), so `geom_m` / ST_Transform(..., 3857) is kept only
-- as the substring input; the *fractions* passed to ST_LineSubstring are now
-- derived from the corrected geography length (`len_m`) instead of the
-- inflated planar length. Since fraction-along-the-line is a normalized
-- proportion of arc length and Web Mercator preserves point ordering/relative
-- spacing along a way (it just scales distance), cutting the 3857 geometry at
-- fractions computed from the true geography length still lands each cut at
-- the correct physical 50m mark, to within normal projection-distortion
-- tolerances over a 50m span.
--
-- `length_m` (and the tail-segment remainder) are now computed from `len_m`
-- (the geography length), so persisted lengths are accurate meters.

CREATE OR REPLACE FUNCTION stage_osm_segments()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    way_id_column TEXT;
BEGIN
    SELECT c.column_name
    INTO way_id_column
    FROM information_schema.columns c
    WHERE c.table_schema = 'osm'
      AND c.table_name = 'osm_ways'
      AND c.column_name IN ('way_id', 'osm_id')
    ORDER BY CASE c.column_name
        WHEN 'way_id' THEN 0
        ELSE 1
    END
    LIMIT 1;

    IF way_id_column IS NULL THEN
        RAISE EXCEPTION 'osm.osm_ways is missing a supported identifier column (way_id or osm_id)';
    END IF;

    EXECUTE format($sql$
        INSERT INTO road_segments_staging (
            osm_way_id,
            segment_index,
            geom,
            length_m,
            road_name,
            road_type,
            surface_type,
            is_parking_aisle,
            bearing_degrees
        )
        WITH ways_m AS (
            SELECT
                w.%1$I AS osm_way_id,
                w.name AS road_name,
                w.highway AS road_type,
                w.surface AS surface_type,
                w.service AS service_type,
                ST_Transform(w.geom, 3857) AS geom_m,
                ST_Length(w.geom::geography) AS len_m
            FROM osm.osm_ways w
            WHERE w.highway IS NOT NULL
        ),
        cut AS (
            SELECT
                wm.osm_way_id,
                wm.road_name,
                wm.road_type,
                wm.surface_type,
                wm.service_type,
                wm.len_m,
                s AS idx,
                ST_LineSubstring(
                    wm.geom_m,
                    ((s - 1) * 50.0) / wm.len_m,
                    LEAST((s * 50.0) / wm.len_m, 1.0)
                ) AS seg_m
            FROM ways_m wm,
                 LATERAL generate_series(1, GREATEST(CEIL(wm.len_m / 50.0)::INTEGER, 1)) AS s
            WHERE wm.len_m > 0
        )
        SELECT
            c.osm_way_id,
            c.idx - 1 AS segment_index,
            ST_Transform(c.seg_m, 4326) AS geom,
            LEAST(50.0, c.len_m - ((c.idx - 1) * 50.0))::NUMERIC(8,1) AS length_m,
            c.road_name,
            c.road_type,
            c.surface_type,
            (c.road_type = 'service' AND c.service_type = 'parking_aisle') AS is_parking_aisle,
            CASE
                WHEN ST_NPoints(c.seg_m) >= 2 AND ST_Length(c.seg_m) > 1
                    THEN degrees(ST_Azimuth(ST_StartPoint(c.seg_m), ST_EndPoint(c.seg_m)))::NUMERIC(5,2)
                ELSE NULL
            END AS bearing_degrees
        FROM cut c
        WHERE ST_Length(c.seg_m) > 1
        ON CONFLICT (osm_way_id, segment_index) DO UPDATE
        SET
            geom = EXCLUDED.geom,
            length_m = EXCLUDED.length_m,
            road_name = EXCLUDED.road_name,
            road_type = EXCLUDED.road_type,
            surface_type = EXCLUDED.surface_type,
            is_parking_aisle = EXCLUDED.is_parking_aisle,
            bearing_degrees = EXCLUDED.bearing_degrees,
            municipality = NULL,
            has_speed_bump = FALSE,
            has_rail_crossing = FALSE
    $sql$, way_id_column);
END;
$$;

COMMENT ON FUNCTION stage_osm_segments() IS
    'Cuts osm.osm_ways into ~50m road_segments_staging rows. Segment length_m and the 50m cut fractions are derived from ST_Length(w.geom::geography) (accurate meters at any latitude), not ST_Transform(...,3857) (which overstates distance by ~1/cos(latitude), ~40% at Nova Scotia latitudes). The actual ST_LineSubstring cut still runs on the 3857-projected geometry because linear referencing requires a planar geometry; only the fraction denominators changed. See 20260702130000_stage_osm_segments_geography_length.sql.';

REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM anon;
REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM authenticated;
GRANT EXECUTE ON FUNCTION stage_osm_segments() TO service_role;
