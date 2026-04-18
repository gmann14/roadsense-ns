CREATE TABLE IF NOT EXISTS road_segments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT road_segments_way_segment_unique UNIQUE (osm_way_id, segment_index)
);

CREATE INDEX IF NOT EXISTS idx_segments_geom ON road_segments USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_segments_geog ON road_segments USING GIST ((geom::geography));
CREATE INDEX IF NOT EXISTS idx_segments_municipality ON road_segments (municipality);
CREATE INDEX IF NOT EXISTS idx_segments_way ON road_segments (osm_way_id);
CREATE INDEX IF NOT EXISTS idx_segments_type ON road_segments (road_type);

