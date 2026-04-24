CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(10);

SELECT has_type(
    'public',
    'pothole_photo_status',
    'pothole_photo_status enum exists'
);

SELECT has_table(
    'public',
    'pothole_photos',
    'pothole_photos table exists'
);

SELECT has_column(
    'public',
    'pothole_photos',
    'report_id',
    'pothole_photos.report_id exists'
);

SELECT col_type_is(
    'public',
    'pothole_photos',
    'status',
    'pothole_photo_status',
    'pothole_photos.status uses pothole_photo_status'
);

SELECT col_type_is(
    'public',
    'pothole_photos',
    'content_sha256',
    'bytea',
    'pothole_photos.content_sha256 is bytea'
);

SELECT is(
    (
        SELECT relrowsecurity::TEXT
        FROM pg_class
        WHERE oid = 'public.pothole_photos'::regclass
    ),
    'true',
    'pothole_photos has RLS enabled'
);

SELECT is(
    (
        SELECT public::TEXT
        FROM storage.buckets
        WHERE id = 'pothole-photos'
    ),
    'false',
    'pothole-photos bucket is private'
);

SELECT is(
    (
        SELECT file_size_limit::TEXT
        FROM storage.buckets
        WHERE id = 'pothole-photos'
    ),
    '1500000',
    'pothole-photos bucket enforces 1.5MB file limit'
);

SELECT ok(
    (
        SELECT 'image/jpeg' = ANY(allowed_mime_types)
        FROM storage.buckets
        WHERE id = 'pothole-photos'
    ),
    'pothole-photos bucket only allows jpeg uploads'
);

SELECT lives_ok(
    $$SELECT promote_uploaded_pothole_photos();$$,
    'promote_uploaded_pothole_photos is callable'
);

SELECT * FROM finish();
