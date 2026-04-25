CREATE INDEX IF NOT EXISTS idx_osm_nodes_speed_bump_geog
    ON osm.osm_nodes
    USING GIST ((geom::geography))
    WHERE traffic_calming = 'bump';

CREATE INDEX IF NOT EXISTS idx_osm_nodes_level_crossing_geog
    ON osm.osm_nodes
    USING GIST ((geom::geography))
    WHERE railway = 'level_crossing';
