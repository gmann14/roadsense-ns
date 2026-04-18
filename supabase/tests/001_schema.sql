CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(31);

SELECT has_extension('postgis', 'postgis extension should be installed');
SELECT has_extension('pgcrypto', 'pgcrypto extension should be installed');
SELECT has_extension('pg_cron', 'pg_cron extension should be installed');

SELECT has_type('public', 'roughness_category', 'roughness_category enum exists');
SELECT has_type('public', 'confidence_level', 'confidence_level enum exists');
SELECT has_type('public', 'pothole_status', 'pothole_status enum exists');
SELECT has_type('public', 'trend_direction', 'trend_direction enum exists');

SELECT has_table('public', 'road_segments', 'road_segments table exists');
SELECT has_table('public', 'segment_aggregates', 'segment_aggregates table exists');
SELECT has_table('public', 'readings', 'readings table exists');
SELECT has_table('public', 'pothole_reports', 'pothole_reports table exists');
SELECT has_table('public', 'processed_batches', 'processed_batches table exists');
SELECT has_table('public', 'rate_limits', 'rate_limits table exists');

SELECT col_is_pk('public', 'road_segments', 'id', 'road_segments.id is primary key');
SELECT col_is_pk('public', 'segment_aggregates', 'segment_id', 'segment_aggregates.segment_id is primary key');
SELECT col_type_is('public', 'readings', 'device_token_hash', 'bytea', 'readings.device_token_hash is bytea');
SELECT col_type_is('public', 'processed_batches', 'rejected_reasons', 'jsonb', 'processed_batches.rejected_reasons is jsonb');
SELECT col_type_is('public', 'rate_limits', 'request_count', 'integer', 'rate_limits.request_count is integer');

SELECT has_index('public', 'road_segments', 'idx_segments_geom', 'road_segments geom index exists');
SELECT has_index('public', 'road_segments', 'idx_segments_geog', 'road_segments geography expression index exists');
SELECT has_index('public', 'segment_aggregates', 'idx_aggregates_score', 'segment_aggregates score index exists');
SELECT has_index('public', 'pothole_reports', 'idx_potholes_geom', 'pothole_reports geom index exists');
SELECT has_index('public', 'processed_batches', 'idx_batches_device', 'processed_batches device index exists');
SELECT has_index('public', 'rate_limits', 'idx_rate_limits_bucket_start', 'rate_limits bucket index exists');

SELECT has_function(
    'public',
    'check_and_bump_rate_limit',
    ARRAY['text', 'timestamp with time zone', 'integer'],
    'rate limit helper exists'
);

SELECT table_privs_are('anon', 'public', 'road_segments', ARRAY['SELECT'], 'anon can read road_segments only');
SELECT table_privs_are('anon', 'public', 'segment_aggregates', ARRAY['SELECT'], 'anon can read segment_aggregates only');
SELECT table_privs_are('anon', 'public', 'pothole_reports', ARRAY['SELECT'], 'anon can read pothole_reports only');
SELECT table_privs_are('anon', 'public', 'processed_batches', ARRAY[]::text[], 'anon cannot touch processed_batches');
SELECT table_privs_are('anon', 'public', 'rate_limits', ARRAY[]::text[], 'anon cannot touch rate_limits');

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_class
        WHERE relname LIKE 'readings_%'
    ),
    'initial readings partitions exist'
);

SELECT * FROM finish();

