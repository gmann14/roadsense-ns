CREATE TABLE IF NOT EXISTS segment_aggregates (
    segment_id UUID PRIMARY KEY REFERENCES road_segments(id) ON DELETE CASCADE,
    avg_roughness_score NUMERIC(5,3),
    roughness_category roughness_category NOT NULL DEFAULT 'unscored',
    total_readings INTEGER NOT NULL DEFAULT 0,
    unique_contributors INTEGER NOT NULL DEFAULT 0,
    confidence confidence_level NOT NULL DEFAULT 'low',
    last_reading_at TIMESTAMPTZ,
    pothole_count INTEGER NOT NULL DEFAULT 0,
    trend trend_direction NOT NULL DEFAULT 'stable',
    score_last_30d NUMERIC(5,3),
    score_30_60d NUMERIC(5,3),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_aggregates_score ON segment_aggregates (avg_roughness_score DESC);
CREATE INDEX IF NOT EXISTS idx_aggregates_category ON segment_aggregates (roughness_category);
CREATE INDEX IF NOT EXISTS idx_aggregates_confidence ON segment_aggregates (confidence);

