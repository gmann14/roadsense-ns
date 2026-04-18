CREATE TABLE IF NOT EXISTS pothole_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    segment_id UUID REFERENCES road_segments(id) ON DELETE SET NULL,
    geom GEOMETRY(POINT, 4326) NOT NULL,
    magnitude NUMERIC(4,2) NOT NULL,
    first_reported_at TIMESTAMPTZ NOT NULL,
    last_confirmed_at TIMESTAMPTZ NOT NULL,
    confirmation_count INTEGER NOT NULL DEFAULT 1,
    unique_reporters INTEGER NOT NULL DEFAULT 1,
    status pothole_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_potholes_geom ON pothole_reports USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_potholes_segment ON pothole_reports (segment_id);
CREATE INDEX IF NOT EXISTS idx_potholes_status ON pothole_reports (status);

