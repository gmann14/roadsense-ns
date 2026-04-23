DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'pothole_photo_status'
    ) THEN
        CREATE TYPE pothole_photo_status AS ENUM (
            'pending_upload',
            'pending_moderation',
            'approved',
            'rejected',
            'expired'
        );
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS pothole_photos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID NOT NULL UNIQUE,
    device_token_hash BYTEA NOT NULL,
    segment_id UUID REFERENCES road_segments(id) ON DELETE SET NULL,
    pothole_report_id UUID REFERENCES pothole_reports(id) ON DELETE SET NULL,
    geom GEOMETRY(POINT, 4326) NOT NULL,
    accuracy_m NUMERIC(5,2),
    captured_at TIMESTAMPTZ NOT NULL,
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    uploaded_at TIMESTAMPTZ,
    reviewed_at TIMESTAMPTZ,
    reviewed_by TEXT,
    status pothole_photo_status NOT NULL DEFAULT 'pending_upload',
    storage_object_path TEXT NOT NULL,
    content_sha256 BYTEA NOT NULL,
    content_type TEXT NOT NULL DEFAULT 'image/jpeg',
    byte_size INTEGER NOT NULL,
    rejection_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_pothole_photos_geom ON pothole_photos USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_pothole_photos_status ON pothole_photos (status);
CREATE INDEX IF NOT EXISTS idx_pothole_photos_device ON pothole_photos (device_token_hash, submitted_at DESC);

ALTER TABLE pothole_photos ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pothole_photos TO service_role;
GRANT INSERT, UPDATE, DELETE ON pothole_photos TO service_role;
REVOKE ALL ON pothole_photos FROM anon;

DROP POLICY IF EXISTS "service role manages pothole photos" ON pothole_photos;
CREATE POLICY "service role manages pothole photos"
    ON pothole_photos
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('pothole-photos', 'pothole-photos', false, 1500000, ARRAY['image/jpeg'])
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE OR REPLACE FUNCTION promote_uploaded_pothole_photos()
RETURNS INTEGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, storage
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    WITH promoted AS (
        UPDATE pothole_photos pp
        SET status = 'pending_moderation',
            uploaded_at = COALESCE(pp.uploaded_at, now())
        FROM storage.objects so
        WHERE pp.status = 'pending_upload'
          AND so.bucket_id = 'pothole-photos'
          AND so.name = pp.storage_object_path
        RETURNING pp.report_id
    )
    SELECT COUNT(*)::INTEGER
    INTO v_count
    FROM promoted;

    RETURN COALESCE(v_count, 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION promote_uploaded_pothole_photos() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION promote_uploaded_pothole_photos() TO service_role;

DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid
    INTO v_job_id
    FROM cron.job
    WHERE jobname = 'roadsense-promote-pothole-photos';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
END
$$;

SELECT cron.schedule(
    'roadsense-promote-pothole-photos',
    '* * * * *',
    $$SELECT promote_uploaded_pothole_photos();$$
);
