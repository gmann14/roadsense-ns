CREATE TABLE IF NOT EXISTS pothole_photo_blobs (
    report_id UUID PRIMARY KEY REFERENCES pothole_photos(report_id) ON DELETE CASCADE,
    storage_object_path TEXT NOT NULL UNIQUE,
    content_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    content_sha256 BYTEA NOT NULL,
    image_bytes BYTEA NOT NULL,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

REVOKE ALL ON pothole_photo_blobs FROM PUBLIC;
REVOKE ALL ON pothole_photo_blobs FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON pothole_photo_blobs TO service_role;
