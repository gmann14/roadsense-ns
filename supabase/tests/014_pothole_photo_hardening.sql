CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(2);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'pothole_reports'
          AND indexname = 'idx_potholes_geog'
          AND indexdef ILIKE '%USING gist (((geom)::geography))%'
    ),
    'pothole_reports has a geography index for photo approval lookups'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'public.moderation_pothole_photo_queue'::regclass
          AND COALESCE(array_to_string(reloptions, ','), '') LIKE '%security_invoker=true%'
    ),
    'moderation_pothole_photo_queue runs with security_invoker enabled'
);

SELECT * FROM finish();
