CREATE INDEX IF NOT EXISTS idx_potholes_geog
    ON pothole_reports
    USING GIST ((geom::geography));

ALTER VIEW moderation_pothole_photo_queue
    SET (security_invoker = true);
