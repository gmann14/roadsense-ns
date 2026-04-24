CREATE OR REPLACE FUNCTION tag_staged_features()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    WITH tagged_speed_bumps AS (
        SELECT DISTINCT
            rs.osm_way_id,
            rs.segment_index
        FROM osm.osm_nodes n
        JOIN road_segments_staging rs
            ON ST_DWithin(rs.geom::geography, n.geom::geography, 10)
        WHERE n.traffic_calming = 'bump'
    )
    UPDATE road_segments_staging rs
    SET has_speed_bump = TRUE
    FROM tagged_speed_bumps t
    WHERE rs.osm_way_id = t.osm_way_id
      AND rs.segment_index = t.segment_index;

    WITH tagged_level_crossings AS (
        SELECT DISTINCT
            rs.osm_way_id,
            rs.segment_index
        FROM osm.osm_nodes n
        JOIN road_segments_staging rs
            ON ST_DWithin(rs.geom::geography, n.geom::geography, 10)
        WHERE n.railway = 'level_crossing'
    )
    UPDATE road_segments_staging rs
    SET has_rail_crossing = TRUE
    FROM tagged_level_crossings t
    WHERE rs.osm_way_id = t.osm_way_id
      AND rs.segment_index = t.segment_index;
END;
$$;
