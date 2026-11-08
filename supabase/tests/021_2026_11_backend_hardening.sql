-- 2026-11 backend hardening (docs/reviews/2026-10-18-full-codebase-review.md):
-- migrations 20261108090000 .. 20261108150000.
--
-- Covers: the k-anonymity floor and day-granular public timestamps (P0-5),
-- stats data_updated_at, retention sweeps and the readings purge, the
-- scheduler run ledger, the nightly-recompute watermark and empty-aggregate
-- clearing, replay without double counting, per-reading ingest sanitising
-- (N8), unpaved-nearest matching, pothole-action time/accuracy bounds (N1),
-- the attested-device upsert guard, area lock keys, the uploaded_at index
-- and the segment-refresh finalize step.
--
-- Timestamps are now()-relative: readings partitions only exist around the
-- run month, and the freshness / action windows are anchored to now().

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(73);

-- Partitions for the 7-month-old purge fixture and the "3 days ago" fixtures.
DO $$
DECLARE
    v_offset INTEGER;
    v_start DATE;
BEGIN
    FOR v_offset IN -7..0 LOOP
        v_start := (date_trunc('month', now()) + make_interval(months => v_offset))::DATE;
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF readings FOR VALUES FROM (%L) TO (%L)',
            format('readings_%s', to_char(v_start, 'YYYY_MM')),
            v_start,
            (v_start + INTERVAL '1 month')::DATE
        );
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Cleanup (the suite shares one database and is not transaction-wrapped).
-- ---------------------------------------------------------------------------
DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0021-00000000b001'::UUID,
    '00000000-0000-0000-0021-00000000b002'::UUID,
    '00000000-0000-0000-0021-00000000b005'::UUID,
    '00000000-0000-0000-0021-00000000b006'::UUID,
    '00000000-0000-0000-0021-00000000b007'::UUID
);
DELETE FROM unmatched_readings
WHERE batch_id IN (
    '00000000-0000-0000-0021-00000000b002'::UUID,
    '00000000-0000-0000-0021-00000000b003'::UUID
);
DELETE FROM processed_batches
WHERE batch_id IN (
    '00000000-0000-0000-0021-00000000b001'::UUID,
    '00000000-0000-0000-0021-00000000b002'::UUID,
    '00000000-0000-0000-0021-00000000d001'::UUID,
    '00000000-0000-0000-0021-00000000d002'::UUID
);
DELETE FROM pothole_actions
WHERE action_id IN (
    '00000000-0000-0000-0021-00000000c001'::UUID,
    '00000000-0000-0000-0021-00000000c002'::UUID,
    '00000000-0000-0000-0021-00000000c003'::UUID,
    '00000000-0000-0000-0021-00000000c004'::UUID
);
DELETE FROM pothole_reports
WHERE id = '00000000-0000-0000-0021-0000000000f1'::UUID
   OR ST_DWithin(
       geom::geography,
       ST_SetSRID(ST_MakePoint(-62.0000, 45.5300), 4326)::geography,
       5000
   );
DELETE FROM segment_contributor_marks
WHERE segment_id::TEXT LIKE '00000000-0000-0000-0021-%';
DELETE FROM segment_aggregates
WHERE segment_id::TEXT LIKE '00000000-0000-0000-0021-%';
DELETE FROM road_segments
WHERE osm_way_id BETWEEN 992101 AND 992199
   OR id::TEXT LIKE '00000000-0000-0000-0021-%';
DELETE FROM rate_limits WHERE key LIKE 'test021:%';
DELETE FROM token_challenges WHERE challenge_hash IN (decode('21c1', 'hex'), decode('21c2', 'hex'));
DELETE FROM feedback_submissions
WHERE id IN ('00000000-0000-0000-0021-00000000e001'::UUID, '00000000-0000-0000-0021-00000000e002'::UUID);
DELETE FROM attested_devices WHERE key_id_hash = decode('21a1', 'hex');
DELETE FROM scheduler_job_runs WHERE job_name LIKE 'test021-%';

-- Fixture segments. S2 (…02) is inserted later so its reading starts unmatched.
INSERT INTO road_segments (
    id, osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
) VALUES
    ('00000000-0000-0000-0021-000000000001', 992101, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5000,-61.9990 45.5000)', 4326), 156.0,
     'Replay Matched Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000003', 992103, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5200,-61.9990 45.5200)', 4326), 156.0,
     'Paved Farther Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000004', 992104, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.52015,-61.9990 45.52015)', 4326), 156.0,
     'Gravel Nearer Road', 'residential', 'gravel', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000005', 992105, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5300,-61.9990 45.5300)', 4326), 156.0,
     'Purge Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000006', 992106, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5400,-61.9990 45.5400)', 4326), 156.0,
     'Watermark Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000007', 992107, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5500,-61.9990 45.5500)', 4326), 156.0,
     'Aged Out Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000008', 992108, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5600,-61.9990 45.5600)', 4326), 156.0,
     'Two Contributor Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0),
    ('00000000-0000-0000-0021-000000000009', 992109, 0,
     ST_GeomFromText('LINESTRING(-62.0010 45.5700,-61.9990 45.5700)', 4326), 156.0,
     'Ingest Sanitising Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0);

-- ===========================================================================
-- 1. Schema objects
-- ===========================================================================
SELECT has_index('public', 'readings', 'idx_readings_uploaded_at', 'readings has an uploaded_at index on the partitioned parent');
SELECT has_table('public', 'scheduler_job_runs', 'scheduler_job_runs exists');
SELECT has_table('public', 'aggregate_recompute_state', 'aggregate_recompute_state exists');
SELECT ok(
    NOT has_table_privilege('anon', 'scheduler_job_runs', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'scheduler_job_runs', 'SELECT'),
    'scheduler_job_runs is not readable by anon/authenticated'
);
SELECT ok(
    NOT has_function_privilege('anon', 'public.run_retention_sweeps()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.purge_expired_readings()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.finalize_road_segment_refresh(timestamp with time zone)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.finalize_road_segment_refresh(timestamp with time zone)', 'EXECUTE'),
    'retention, purge and refresh-finalize functions are service_role only'
);
SELECT ok(
    (SELECT bool_and(EXISTS (SELECT 1 FROM cron.job WHERE jobname = j))
     FROM unnest(ARRAY['purge-expired-readings', 'replay-unmatched-readings', 'retention-sweeps']) AS j),
    'purge, replay and retention jobs are registered with cron'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname IN ('rate-limit-gc', 'segment-contributor-marks-gc')),
    'the jobs folded into retention-sweeps are unscheduled'
);

-- ===========================================================================
-- 2. Public read models: k-anonymity and day-granular timestamps (P0-5)
-- ===========================================================================
SELECT ok(
    position('sa.updated_at' IN pg_get_functiondef('public.get_coverage_tile(integer,integer,integer)'::regprocedure)) = 0,
    'coverage tiles no longer carry the to-the-second updated_at'
);

INSERT INTO pothole_reports (
    id, segment_id, geom, magnitude, first_reported_at, last_confirmed_at,
    confirmation_count, unique_reporters, status
) VALUES (
    '00000000-0000-0000-0021-0000000000f1',
    '00000000-0000-0000-0021-000000000009',
    ST_GeomFromText('POINT(-62.0000 45.5700)', 4326),
    2.40,
    date_trunc('day', now(), 'UTC') - INTERVAL '10 days' + INTERVAL '13 hours 37 minutes 12 seconds',
    date_trunc('day', now(), 'UTC') - INTERVAL '2 days' + INTERVAL '8 hours 5 minutes',
    100000,
    3,
    'active'
);

SELECT is(
    (SELECT first_reported_at FROM get_potholes_in_bbox(-62.01, 45.56, -61.99, 45.58)
     WHERE id = '00000000-0000-0000-0021-0000000000f1'),
    date_trunc('day', now(), 'UTC') - INTERVAL '10 days',
    'get_potholes_in_bbox returns first_reported_at as a UTC day'
);
SELECT is(
    (SELECT last_confirmed_at FROM get_potholes_in_bbox(-62.01, 45.56, -61.99, 45.58)
     WHERE id = '00000000-0000-0000-0021-0000000000f1'),
    date_trunc('day', now(), 'UTC') - INTERVAL '2 days',
    'get_potholes_in_bbox returns last_confirmed_at as a UTC day'
);
SELECT is(
    (SELECT first_reported_at FROM get_top_potholes(100) WHERE id = '00000000-0000-0000-0021-0000000000f1'),
    date_trunc('day', now(), 'UTC') - INTERVAL '10 days',
    'get_top_potholes returns first_reported_at as a UTC day'
);
SELECT is(
    (SELECT last_confirmed_at FROM get_top_potholes(100) WHERE id = '00000000-0000-0000-0021-0000000000f1'),
    date_trunc('day', now(), 'UTC') - INTERVAL '2 days',
    'get_top_potholes returns last_confirmed_at as a UTC day'
);

-- k = 2 segment with the newest reading anywhere: must not move data_updated_at.
INSERT INTO segment_aggregates (
    segment_id, avg_roughness_score, roughness_category, total_readings,
    unique_contributors, confidence, last_reading_at, pothole_count, trend
) VALUES (
    '00000000-0000-0000-0021-000000000008', 0.900, 'rough', 4, 2, 'low',
    now() + INTERVAL '3 days', 0, 'stable'
);

REFRESH MATERIALIZED VIEW public_stats_mv;
REFRESH MATERIALIZED VIEW public_worst_segments_mv;

SELECT has_column('public', 'public_stats_mv', 'data_updated_at', 'public_stats_mv exposes data_updated_at');
SELECT is(
    (SELECT data_updated_at FROM public_stats_mv),
    (SELECT date_trunc('day', MAX(sa.last_reading_at), 'UTC')
     FROM segment_aggregates sa
     JOIN road_segments rs ON rs.id = sa.segment_id
     WHERE sa.total_readings > 0 AND sa.unique_contributors >= 3),
    'data_updated_at is the UTC day of the newest reading on a k>=3 segment'
);
SELECT ok(
    COALESCE((SELECT data_updated_at < date_trunc('day', now() + INTERVAL '3 days', 'UTC') FROM public_stats_mv), TRUE),
    'a sub-k segment does not move data_updated_at'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM public_worst_segments_mv
        WHERE last_reading_at IS DISTINCT FROM date_trunc('day', last_reading_at, 'UTC')
    ),
    'public_worst_segments_mv publishes last_reading_at as a UTC day'
);

-- ===========================================================================
-- 3. Ingest sanitising (N8)
-- ===========================================================================
CREATE TEMP TABLE tmp_n8 AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0021-00000000b001'::UUID,
    decode('e1', 'hex'),
    jsonb_build_array(
        jsonb_build_object('lat', 45.5700, 'lng', -62.0006, 'roughness_rms', 0.30, 'speed_kmh', 50,
            'heading', 400, 'gps_accuracy_m', 5, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '61 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        jsonb_build_object('lat', 45.5700, 'lng', -62.0004, 'roughness_rms', 0.30, 'speed_kmh', 50,
            'heading', 90, 'gps_accuracy_m', -1, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '62 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        jsonb_build_object('lat', 45.5700, 'lng', -62.0002, 'roughness_rms', 0.30, 'speed_kmh', 50,
            'heading', 90, 'gps_accuracy_m', 5, 'is_pothole', true, 'pothole_magnitude', 9.5,
            'recorded_at', to_char(now() - INTERVAL '63 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        jsonb_build_object('lat', 45.5700, 'lng', -62.0000, 'roughness_rms', 0.30, 'speed_kmh', 50,
            'heading', 90, 'gps_accuracy_m', 5, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '64 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    ),
    now(),
    '0.1.0 (1)',
    'iOS 18.0'
)::JSONB AS payload;

SELECT is((SELECT (payload->>'accepted')::INTEGER FROM tmp_n8), 2,
    'out-of-range heading is accepted; bad readings do not fail the batch');
SELECT is((SELECT payload->'rejected_reasons'->>'low_quality' FROM tmp_n8), '2',
    'negative accuracy and >8 g magnitude are rejected per reading as low_quality');
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM readings
     WHERE batch_id = '00000000-0000-0000-0021-00000000b001' AND heading_degrees IS NULL),
    1,
    'a heading outside [0,360) is stored as NULL'
);

-- ===========================================================================
-- 4. Unpaved-nearest matching (pre-20260702150000 semantics restored)
-- ===========================================================================
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM match_reading_to_segment(ST_SetSRID(ST_MakePoint(-62.0000, 45.52012), 4326), 90, TRUE)),
    0,
    'nearest road unpaved: no paved fallback to a farther segment'
);
SELECT is(
    (SELECT segment_id::TEXT FROM match_reading_to_segment(ST_SetSRID(ST_MakePoint(-62.0000, 45.52012), 4326), 90, FALSE)),
    '00000000-0000-0000-0021-000000000004',
    'without the paved requirement the nearest (gravel) segment matches'
);
SELECT is(
    (SELECT segment_id::TEXT FROM match_reading_to_segment(ST_SetSRID(ST_MakePoint(-62.0000, 45.51990), 4326), 720, TRUE)),
    '00000000-0000-0000-0021-000000000003',
    'an out-of-range heading falls back to the segment bearing instead of raising'
);

-- ===========================================================================
-- 5. Replay: only newly matched readings are folded
-- ===========================================================================
CREATE TEMP TABLE tmp_replay_ingest AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0021-00000000b002'::UUID,
    decode('e2', 'hex'),
    jsonb_build_array(
        jsonb_build_object('lat', 45.5000, 'lng', -62.0005, 'roughness_rms', 0.40, 'speed_kmh', 50,
            'heading', 90, 'gps_accuracy_m', 5, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '50 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
        jsonb_build_object('lat', 45.5100, 'lng', -62.0005, 'roughness_rms', 1.40, 'speed_kmh', 50,
            'heading', 90, 'gps_accuracy_m', 5, 'is_pothole', true, 'pothole_magnitude', 2.5,
            'recorded_at', to_char(now() - INTERVAL '49 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    ),
    now(),
    '0.1.0 (1)',
    'iOS 18.0'
)::JSONB AS payload;

SELECT is(
    (SELECT (payload->>'accepted')::INTEGER || '/' || (payload->>'held_for_retry') FROM tmp_replay_ingest),
    '1/1',
    'replay fixture: one reading matched, one held for retry'
);

INSERT INTO road_segments (
    id, osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
) VALUES (
    '00000000-0000-0000-0021-000000000002', 992102, 0,
    ST_GeomFromText('LINESTRING(-62.0010 45.5100,-61.9990 45.5100)', 4326), 156.0,
    'Replay New Road', 'primary', 'asphalt', 'Antigonish', FALSE, FALSE, FALSE, 90.0
);

SELECT lives_ok($$SELECT replay_unmatched_readings()$$, 'replay_unmatched_readings runs');

SELECT is(
    (SELECT total_readings FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000001'),
    1,
    'replay does not re-add the batch''s already-matched reading'
);
SELECT is(
    (SELECT total_readings FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000002'),
    1,
    'replay folds the promoted reading into its new segment'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM unmatched_readings WHERE batch_id = '00000000-0000-0000-0021-00000000b002'),
    0,
    'the promoted reading leaves the holding table'
);
SELECT ok(
    EXISTS (
        SELECT 1 FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0021-000000000002'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-62.0005, 45.5100), 4326)::geography, 15)
    ),
    'a promoted pothole reading is folded into a pothole candidate'
);

-- ===========================================================================
-- 6. Pothole action bounds (N1)
-- ===========================================================================
SELECT throws_ok(
    $$SELECT apply_pothole_action('00000000-0000-0000-0021-00000000c001'::UUID, decode('e3', 'hex'),
        'manual_report', 45.5400, -62.0000, 5.0, now() + INTERVAL '10 minutes', NULL)$$,
    '22023',
    'recorded_at_out_of_window',
    'an action recorded more than 5 minutes in the future is rejected'
);
SELECT throws_ok(
    $$SELECT apply_pothole_action('00000000-0000-0000-0021-00000000c002'::UUID, decode('e3', 'hex'),
        'manual_report', 45.5400, -62.0000, 5.0, now() - INTERVAL '31 days', NULL)$$,
    '22023',
    'recorded_at_out_of_window',
    'an action recorded more than 30 days ago is rejected'
);
SELECT lives_ok(
    $$SELECT apply_pothole_action('00000000-0000-0000-0021-00000000c003'::UUID, decode('e3', 'hex'),
        'manual_report', 45.5400, -62.0000, 5000, now() + INTERVAL '2 minutes', NULL)$$,
    'a slightly-future action with an oversized accuracy is accepted'
);
SELECT ok(
    (SELECT recorded_at <= now() FROM pothole_actions WHERE action_id = '00000000-0000-0000-0021-00000000c003'),
    'a slightly-future recorded_at is clamped to now()'
);
SELECT is(
    (SELECT accuracy_m FROM pothole_actions WHERE action_id = '00000000-0000-0000-0021-00000000c003'),
    999.99::NUMERIC,
    'accuracy is clamped to fit NUMERIC(5,2)'
);
SELECT ok(
    (SELECT last_confirmed_at <= now() FROM pothole_reports
     WHERE id = (SELECT pothole_report_id FROM pothole_actions WHERE action_id = '00000000-0000-0000-0021-00000000c003')),
    'the pothole created by the action never gets a future last_confirmed_at'
);

-- ===========================================================================
-- 7. Attested device upsert guard
-- ===========================================================================
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('21a1', 'hex'), 'ios', decode('aa01', 'hex'), 5, 'attested', decode('21b1', 'hex'))$$,
    'first attestation inserts the device'
);
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('21a1', 'hex'), 'ios', decode('bb02', 'hex'), 2, 'attested', decode('21b2', 'hex'))$$,
    'a conflicting attestation for the same key id is accepted as a rotation'
);
SELECT is(
    (SELECT public_key FROM attested_devices WHERE key_id_hash = decode('21a1', 'hex')),
    decode('aa01', 'hex'),
    'the attested public key is never overwritten'
);
SELECT is(
    (SELECT sign_count FROM attested_devices WHERE key_id_hash = decode('21a1', 'hex')),
    5::BIGINT,
    'a lower sign_count never rolls the stored counter back'
);
SELECT is(
    (SELECT current_token_hash FROM attested_devices WHERE key_id_hash = decode('21a1', 'hex')),
    decode('21b2', 'hex'),
    'token rotation still happens on conflict'
);
SELECT is(
    (SELECT (upsert_attested_device(decode('21a1', 'hex'), 'ios', decode('cc03', 'hex'), 9, 'attested', decode('21b3', 'hex'))).sign_count),
    9::BIGINT,
    'a higher sign_count moves the counter forward'
);

-- ===========================================================================
-- 8. Retention sweeps
-- ===========================================================================
INSERT INTO rate_limits (key, bucket_start, request_count) VALUES
    ('test021:old', now() - INTERVAL '3 days', 1),
    ('test021:new', now() - INTERVAL '1 hour', 1);
INSERT INTO processed_batches (
    batch_id, device_token_hash, reading_count, accepted_count, rejected_count,
    rejected_reasons, processed_at, client_sent_at
) VALUES
    ('00000000-0000-0000-0021-00000000d001', decode('e4', 'hex'), 0, 0, 0, '{}', now() - INTERVAL '181 days', now() - INTERVAL '181 days'),
    ('00000000-0000-0000-0021-00000000d002', decode('e4', 'hex'), 0, 0, 0, '{}', now() - INTERVAL '1 day', now() - INTERVAL '1 day');
INSERT INTO token_challenges (challenge_hash, created_at, expires_at, client_ip) VALUES
    (decode('21c1', 'hex'), now() - INTERVAL '2 hours', now() - INTERVAL '2 hours' + INTERVAL '5 minutes', '198.51.100.1'),
    (decode('21c2', 'hex'), now(), now() + INTERVAL '5 minutes', '198.51.100.2');
INSERT INTO feedback_submissions (id, created_at, source, category, message, client_ip) VALUES
    ('00000000-0000-0000-0021-00000000e001', now() - INTERVAL '31 days', 'web', 'bug', 'retention sweep fixture (old)', '203.0.113.7'),
    ('00000000-0000-0000-0021-00000000e002', now() - INTERVAL '1 day', 'web', 'bug', 'retention sweep fixture (new)', '203.0.113.8');
INSERT INTO unmatched_readings (
    batch_id, device_token_hash, location, roughness_rms, speed_kmh, heading_degrees,
    gps_accuracy_m, is_pothole, pothole_magnitude, recorded_at, created_at
) VALUES (
    '00000000-0000-0000-0021-00000000b003', decode('e4', 'hex'),
    ST_SetSRID(ST_MakePoint(-62.5, 45.9), 4326), 0.3, 50, 90, 5, FALSE, NULL,
    now() - INTERVAL '91 days', now() - INTERVAL '91 days'
);
INSERT INTO pothole_actions (
    action_id, device_token_hash, geom, accuracy_m, action_type, recorded_at, created_at
) VALUES (
    '00000000-0000-0000-0021-00000000c004', decode('e4', 'hex'),
    ST_SetSRID(ST_MakePoint(-62.5, 45.9), 4326), 5, 'manual_report',
    now() - INTERVAL '7 months', now() - INTERVAL '7 months'
);

CREATE TEMP TABLE tmp_sweeps AS SELECT run_retention_sweeps() AS result;

SELECT ok(
    (SELECT result ?& ARRAY['unmatched_readings', 'feedback_client_ips_cleared', 'token_challenges',
        'processed_batches', 'pothole_actions', 'pothole_reporter_marks', 'segment_contributor_marks', 'rate_limits']
     FROM tmp_sweeps),
    'run_retention_sweeps reports a count per table'
);
SELECT is(
    (SELECT string_agg(key, ',' ORDER BY key) FROM rate_limits WHERE key LIKE 'test021:%'),
    'test021:new',
    'rate_limits older than 2 days are deleted, recent buckets kept'
);
SELECT is(
    (SELECT string_agg(batch_id::TEXT, ',') FROM processed_batches
     WHERE batch_id IN ('00000000-0000-0000-0021-00000000d001', '00000000-0000-0000-0021-00000000d002')),
    '00000000-0000-0000-0021-00000000d002',
    'processed_batches older than 180 days are deleted'
);
SELECT is(
    (SELECT encode(challenge_hash, 'hex') FROM token_challenges
     WHERE challenge_hash IN (decode('21c1', 'hex'), decode('21c2', 'hex'))),
    '21c2',
    'expired token challenges (and their client_ip) are deleted'
);
SELECT is(
    (SELECT client_ip FROM feedback_submissions WHERE id = '00000000-0000-0000-0021-00000000e001'),
    NULL,
    'feedback client_ip is cleared after 30 days'
);
SELECT is(
    (SELECT client_ip FROM feedback_submissions WHERE id = '00000000-0000-0000-0021-00000000e002'),
    '203.0.113.8',
    'recent feedback keeps its client_ip'
);
SELECT ok(
    EXISTS (SELECT 1 FROM feedback_submissions WHERE id = '00000000-0000-0000-0021-00000000e001'),
    'the feedback message itself is kept'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM unmatched_readings WHERE batch_id = '00000000-0000-0000-0021-00000000b003'),
    0,
    'unmatched readings older than 90 days are deleted'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM pothole_actions WHERE action_id = '00000000-0000-0000-0021-00000000c004'),
    0,
    'pothole actions older than 6 months are deleted'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM pothole_actions WHERE action_id = '00000000-0000-0000-0021-00000000c003'),
    1,
    'recent pothole actions are kept'
);

-- ===========================================================================
-- 9. Readings purge recomputes what it touched
-- ===========================================================================
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES (
    '00000000-0000-0000-0021-0000000aa501', '00000000-0000-0000-0021-000000000005',
    '00000000-0000-0000-0021-00000000b005', decode('e5', 'hex'), 0.8, 50, 90, 5, FALSE, NULL,
    ST_SetSRID(ST_MakePoint(-62.0000, 45.5300), 4326), now() - INTERVAL '7 months'
);
INSERT INTO segment_aggregates (
    segment_id, avg_roughness_score, roughness_category, total_readings,
    unique_contributors, confidence, last_reading_at, pothole_count, trend
) VALUES (
    '00000000-0000-0000-0021-000000000005', 0.800, 'rough', 1, 3, 'medium',
    now() - INTERVAL '7 months', 0, 'stable'
);

CREATE TEMP TABLE tmp_purge AS SELECT purge_expired_readings() AS result;

SELECT ok(
    (SELECT (result->>'deleted_readings')::INTEGER >= 1 FROM tmp_purge),
    'purge_expired_readings reports deleted readings'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM readings WHERE batch_id = '00000000-0000-0000-0021-00000000b005'),
    0,
    'readings older than 6 months are deleted'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000005'),
    0,
    'a segment left with no retained readings loses its public aggregate'
);

-- ===========================================================================
-- 10. Nightly recompute: watermark and aged-out aggregates
-- ===========================================================================
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location,
    recorded_at, uploaded_at
) VALUES (
    '00000000-0000-0000-0021-0000000aa601', '00000000-0000-0000-0021-000000000006',
    '00000000-0000-0000-0021-00000000b006', decode('e6', 'hex'), 0.5, 50, 90, 5, FALSE, NULL,
    ST_SetSRID(ST_MakePoint(-62.0000, 45.5400), 4326),
    now() - INTERVAL '3 days', now() - INTERVAL '3 days'
);
INSERT INTO segment_aggregates (
    segment_id, avg_roughness_score, roughness_category, total_readings,
    unique_contributors, confidence, last_reading_at, pothole_count, trend
) VALUES (
    '00000000-0000-0000-0021-000000000007', 0.700, 'rough', 5, 3, 'medium',
    now() - INTERVAL '7 months', 0, 'stable'
);
-- A reading still pointing at a segment a refresh deleted (no FK on the
-- partitioned readings table) must not abort the run.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location,
    recorded_at, uploaded_at
) VALUES (
    '00000000-0000-0000-0021-0000000aa701', '00000000-0000-0000-0021-0000000000ff',
    '00000000-0000-0000-0021-00000000b007', decode('e7', 'hex'), 0.5, 50, 90, 5, FALSE, NULL,
    ST_SetSRID(ST_MakePoint(-62.0000, 45.5450), 4326),
    now() - INTERVAL '2 hours', now() - INTERVAL '2 hours'
);
INSERT INTO aggregate_recompute_state (singleton, last_full_run_started_at)
VALUES (TRUE, now() - INTERVAL '4 days')
ON CONFLICT (singleton) DO UPDATE SET last_full_run_started_at = EXCLUDED.last_full_run_started_at;

SELECT lives_ok($$SELECT nightly_recompute_aggregates()$$, 'full nightly recompute runs');

SELECT is(
    (SELECT total_readings FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000006'),
    1,
    'uploads since the last full run (beyond 24 h) are recomputed'
);
SELECT lives_ok(
    $$SELECT nightly_recompute_aggregates(ARRAY['00000000-0000-0000-0021-0000000000ff'::UUID])$$,
    'an explicit recompute of a deleted segment id is a no-op, not an FK error'
);
SELECT is(
    (SELECT COUNT(*)::INTEGER FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000007'),
    0,
    'an aggregate whose readings all aged out is cleared'
);
SELECT ok(
    (SELECT last_full_run_started_at > now() - INTERVAL '1 minute' FROM aggregate_recompute_state WHERE singleton),
    'the full run advances the watermark'
);

-- ===========================================================================
-- 11. Scheduler run ledger
-- ===========================================================================
SELECT is(scheduler_job_seconds_until_due('test021-job', 3600, 900), 0, 'a never-run job is due');

SELECT lives_ok(
    $$SELECT record_scheduler_job_run('test021-job', now(), TRUE, 12, NULL, '{"rows": 3}'::JSONB)$$,
    'record a successful run'
);
SELECT ok(
    scheduler_job_seconds_until_due('test021-job', 3600, 900) BETWEEN 3590 AND 3600,
    'after a success the job is due one interval after it started'
);
SELECT lives_ok(
    $$SELECT record_scheduler_job_run('test021-job', now(), FALSE, 7, repeat('x', 5000), NULL)$$,
    'record a failed run'
);
SELECT lives_ok(
    $$SELECT record_scheduler_job_run('test021-job', now(), FALSE, 7, 'second failure', NULL)$$,
    'record a second failed run'
);
SELECT is(
    (SELECT last_status || ':' || consecutive_failures || ':' || (last_success_at IS NOT NULL)
     FROM scheduler_job_runs WHERE job_name = 'test021-job'),
    'error:2:true',
    'failures increment consecutive_failures and keep last_success_at'
);
SELECT ok(
    scheduler_job_seconds_until_due('test021-job', 3600, 900) BETWEEN 1 AND 900,
    'a failed job is retried after the retry window, not the full interval'
);
SELECT lives_ok(
    $$SELECT record_scheduler_job_run('test021-job2', now(), FALSE, 7, repeat('y', 5000), NULL)$$,
    'record a failure with a long error'
);
SELECT is(
    (SELECT char_length(last_error) FROM scheduler_job_runs WHERE job_name = 'test021-job2'),
    1000,
    'stored error text is truncated'
);
SELECT lives_ok(
    $$SELECT record_scheduler_job_run('test021-job', now(), TRUE, 9, NULL, NULL)$$,
    'record a recovery'
);
SELECT is(
    (SELECT last_status || ':' || consecutive_failures FROM scheduler_job_runs WHERE job_name = 'test021-job'),
    'ok:0',
    'a success resets consecutive_failures'
);

-- ===========================================================================
-- 12. Pothole area lock keys
-- ===========================================================================
SELECT ok(
    (SELECT COUNT(*) BETWEEN 1 AND 4 FROM pothole_area_lock_keys(ST_SetSRID(ST_MakePoint(-62.00004, 45.50004), 4326))),
    'a point maps to between one and four area lock keys'
);
SELECT ok(
    EXISTS (
        SELECT k FROM pothole_area_lock_keys(ST_SetSRID(ST_MakePoint(-62.00049, 45.50000), 4326)) AS k
        INTERSECT
        SELECT k FROM pothole_area_lock_keys(ST_SetSRID(ST_MakePoint(-62.00031, 45.50000), 4326)) AS k
    ),
    'two points 14 m apart (inside the 15 m fold radius) share a lock key'
);

-- ===========================================================================
-- 13. Segment refresh finalize (runs last: it re-seeds all contributor marks)
-- ===========================================================================
CREATE TEMP TABLE tmp_finalize AS SELECT finalize_road_segment_refresh() AS result;

SELECT ok(
    (SELECT result ?& ARRAY['segments_touched_by_rematch', 'segments_recomputed', 'potholes_reanchored'] FROM tmp_finalize),
    'finalize_road_segment_refresh reports what it did'
);
SELECT is(
    (SELECT total_readings FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0021-000000000002'),
    1,
    'finalize recomputes from readings without double counting'
);

SELECT * FROM finish();
