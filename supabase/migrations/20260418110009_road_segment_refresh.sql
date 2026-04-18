CREATE SCHEMA IF NOT EXISTS osm;
CREATE SCHEMA IF NOT EXISTS ref;

CREATE TABLE IF NOT EXISTS road_segments_staging (
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

CREATE INDEX IF NOT EXISTS idx_segments_staging_geom
    ON road_segments_staging USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_segments_staging_geog
    ON road_segments_staging USING GIST ((geom::geography));

CREATE OR REPLACE FUNCTION stage_osm_segments()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
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
            w.osm_id AS osm_way_id,
            w.name AS road_name,
            w.highway AS road_type,
            w.surface AS surface_type,
            w.service AS service_type,
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
        has_rail_crossing = FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION tag_staged_municipalities()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE road_segments_staging rs
    SET municipality = m.csd_name
    FROM ref.municipalities m
    WHERE ST_Intersects(rs.geom, m.geom)
      AND rs.municipality IS NULL;

    UPDATE road_segments_staging rs
    SET municipality = m.csd_name
    FROM ref.municipalities m
    WHERE rs.municipality IS NULL
      AND ST_Contains(m.geom, ST_Centroid(rs.geom));
END;
$$;

CREATE OR REPLACE FUNCTION tag_staged_features()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE road_segments_staging rs
    SET has_speed_bump = TRUE
    WHERE EXISTS (
        SELECT 1
        FROM osm.osm_nodes n
        WHERE n.traffic_calming = 'bump'
          AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
    );

    UPDATE road_segments_staging rs
    SET has_rail_crossing = TRUE
    WHERE EXISTS (
        SELECT 1
        FROM osm.osm_nodes n
        WHERE n.railway = 'level_crossing'
          AND ST_DWithin(rs.geom::geography, n.geom::geography, 10)
    );
END;
$$;

CREATE OR REPLACE FUNCTION apply_road_segment_refresh()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE road_segments rs
    SET
        geom = s.geom,
        length_m = s.length_m,
        road_name = s.road_name,
        road_type = s.road_type,
        surface_type = s.surface_type,
        municipality = s.municipality,
        has_speed_bump = COALESCE(s.has_speed_bump, FALSE),
        has_rail_crossing = COALESCE(s.has_rail_crossing, FALSE),
        is_parking_aisle = COALESCE(s.is_parking_aisle, FALSE),
        bearing_degrees = s.bearing_degrees,
        updated_at = now()
    FROM road_segments_staging s
    WHERE rs.osm_way_id = s.osm_way_id
      AND rs.segment_index = s.segment_index;

    INSERT INTO road_segments (
        osm_way_id,
        segment_index,
        geom,
        length_m,
        road_name,
        road_type,
        surface_type,
        municipality,
        has_speed_bump,
        has_rail_crossing,
        is_parking_aisle,
        bearing_degrees
    )
    SELECT
        s.osm_way_id,
        s.segment_index,
        s.geom,
        s.length_m,
        s.road_name,
        s.road_type,
        s.surface_type,
        s.municipality,
        COALESCE(s.has_speed_bump, FALSE),
        COALESCE(s.has_rail_crossing, FALSE),
        COALESCE(s.is_parking_aisle, FALSE),
        s.bearing_degrees
    FROM road_segments_staging s
    LEFT JOIN road_segments rs
        ON rs.osm_way_id = s.osm_way_id
       AND rs.segment_index = s.segment_index
    WHERE rs.id IS NULL;

    DELETE FROM road_segments rs
    WHERE NOT EXISTS (
        SELECT 1
        FROM road_segments_staging s
        WHERE s.osm_way_id = rs.osm_way_id
          AND s.segment_index = rs.segment_index
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM anon;
REVOKE EXECUTE ON FUNCTION stage_osm_segments() FROM authenticated;
GRANT EXECUTE ON FUNCTION stage_osm_segments() TO service_role;

REVOKE EXECUTE ON FUNCTION tag_staged_municipalities() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION tag_staged_municipalities() FROM anon;
REVOKE EXECUTE ON FUNCTION tag_staged_municipalities() FROM authenticated;
GRANT EXECUTE ON FUNCTION tag_staged_municipalities() TO service_role;

REVOKE EXECUTE ON FUNCTION tag_staged_features() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION tag_staged_features() FROM anon;
REVOKE EXECUTE ON FUNCTION tag_staged_features() FROM authenticated;
GRANT EXECUTE ON FUNCTION tag_staged_features() TO service_role;

REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM anon;
REVOKE EXECUTE ON FUNCTION apply_road_segment_refresh() FROM authenticated;
GRANT EXECUTE ON FUNCTION apply_road_segment_refresh() TO service_role;
