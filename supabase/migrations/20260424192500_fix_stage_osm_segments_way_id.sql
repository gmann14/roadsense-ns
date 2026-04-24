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
            has_rail_crossing = FALSE
    $sql$, way_id_column);
END;
$$;
