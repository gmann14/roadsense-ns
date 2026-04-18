ALTER TABLE road_segments ENABLE ROW LEVEL SECURITY;
ALTER TABLE segment_aggregates ENABLE ROW LEVEL SECURITY;
ALTER TABLE readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pothole_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon read aggregates" ON segment_aggregates;
CREATE POLICY "anon read aggregates"
    ON segment_aggregates
    FOR SELECT
    TO anon
    USING (true);

DROP POLICY IF EXISTS "anon read road_segments" ON road_segments;
CREATE POLICY "anon read road_segments"
    ON road_segments
    FOR SELECT
    TO anon
    USING (true);

DROP POLICY IF EXISTS "anon read potholes" ON pothole_reports;
CREATE POLICY "anon read potholes"
    ON pothole_reports
    FOR SELECT
    TO anon
    USING (status = 'active');

