-- B166 — exact unique-contributor accounting for the incremental path
-- (P1-3, docs/reviews/2026-06-11-backend-prelaunch-review.md;
-- docs/implementation/15-device-attestation-and-trust.md).
--
-- Timestamps are now()-relative because readings partitions only exist for
-- the migration-run month onward.

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(21);

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000a601'::UUID,
    '00000000-0000-0000-0000-00000000a602'::UUID,
    '00000000-0000-0000-0000-00000000a603'::UUID,
    '00000000-0000-0000-0000-00000000a604'::UUID,
    '00000000-0000-0000-0000-00000000a605'::UUID,
    '00000000-0000-0000-0000-00000000a606'::UUID
);

DELETE FROM segment_contributor_marks
WHERE segment_id = '00000000-0000-0000-0000-000000002101'::UUID;

DELETE FROM segment_aggregates
WHERE segment_id = '00000000-0000-0000-0000-000000002101'::UUID;

DELETE FROM road_segments
WHERE osm_way_id = 990001;

INSERT INTO road_segments (
    id,
    osm_way_id,
    segment_index,
    geom,
    length_m,
    road_name,
    road_type,
    surface_type,
    municipality,
    has_speed_bump,
    has_rail_crossing,
    is_parking_aisle,
    bearing_degrees
) VALUES (
    '00000000-0000-0000-0000-000000002101',
    990001,
    0,
    ST_GeomFromText('LINESTRING(-63.9010 44.8000,-63.8990 44.8000)', 4326),
    160.0,
    'Contributor Dedupe Road',
    'primary',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.00
);

-- Schema sanity.
SELECT has_table('segment_contributor_marks', 'segment_contributor_marks table exists');
SELECT col_is_pk(
    'segment_contributor_marks',
    ARRAY['segment_id', 'device_token_hash'],
    'marks are unique per (segment, device)'
);
SELECT ok(
    NOT has_table_privilege('anon', 'segment_contributor_marks', 'SELECT'),
    'anon cannot read contributor marks (token hashes stay private)'
);

-- 1. P1-3 reproduction: one device, three batches, same segment, same day.
--    unique_contributors must stay 1 and confidence must stay low through the
--    incremental path (pre-B166 it read 3/medium).
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000aa901', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a601', decode('d1', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.9004 44.8000)', 4326), now() - INTERVAL '3 hours');

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-00000000a601'::UUID)$$,
    'first incremental fold succeeds'
);

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000aa902', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a602', decode('d1', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.9003 44.8000)', 4326), now() - INTERVAL '2 hours'),
    ('00000000-0000-0000-0000-0000000aa903', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a603', decode('d1', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.9002 44.8000)', 4326), now() - INTERVAL '1 hour');

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-00000000a602'::UUID)$$,
    'second same-device batch folds'
);
SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-00000000a603'::UUID)$$,
    'third same-device batch folds'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '1',
    'three same-device batches keep unique_contributors at 1 (P1-3 closed)'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    'low',
    'a single device cannot raise confidence through the incremental path'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM segment_contributor_marks WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '1',
    'repeat batches leave exactly one mark per device'
);

-- 2. A genuinely distinct second device counts.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000aa904', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a604', decode('d2', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.9001 44.8000)', 4326), now() - INTERVAL '55 minutes');

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-00000000a604'::UUID)$$,
    'distinct-device batch folds'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '2',
    'a distinct second device increments unique_contributors to 2'
);

-- 3. A device first counted by the nightly recompute must not re-increment
--    via a later incremental batch: the recompute seeds its mark.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000aa905', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a605', decode('d3', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.9000 44.8000)', 4326), now() - INTERVAL '50 minutes');

SELECT lives_ok(
    $$SELECT nightly_recompute_aggregates(ARRAY['00000000-0000-0000-0000-000000002101'::UUID])$$,
    'nightly recompute succeeds over the fixture segment'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '3',
    'nightly recompute counts all three devices from readings'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM segment_contributor_marks
        WHERE segment_id = '00000000-0000-0000-0000-000000002101'
          AND device_token_hash = decode('d3', 'hex')
    ),
    'nightly recompute seeds a mark for the device it counted'
);

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000aa906', '00000000-0000-0000-0000-000000002101', '00000000-0000-0000-0000-00000000a606', decode('d3', 'hex'), 0.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.8999 44.8000)', 4326), now() - INTERVAL '45 minutes');

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-00000000a606'::UUID)$$,
    'already-counted device batch folds'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '3',
    'a device already counted by the nightly recompute does not re-increment via a later batch'
);

-- 4. GC removes marks older than the 6-month reading-retention window; the
--    nightly recompute remains the overriding source of truth afterward.
UPDATE segment_contributor_marks
SET first_seen_at = now() - INTERVAL '7 months'
WHERE segment_id = '00000000-0000-0000-0000-000000002101'
  AND device_token_hash = decode('d1', 'hex');

DELETE FROM segment_contributor_marks WHERE first_seen_at < now() - INTERVAL '6 months';

SELECT is(
    (SELECT COUNT(*)::TEXT FROM segment_contributor_marks WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '2',
    'GC sweep removes marks past the 6-month retention window'
);

SELECT lives_ok(
    $$SELECT nightly_recompute_aggregates(ARRAY['00000000-0000-0000-0000-000000002101'::UUID])$$,
    'nightly recompute runs after the GC sweep'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '3',
    'nightly recompute restores the true contributor count after GC'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM segment_contributor_marks WHERE segment_id = '00000000-0000-0000-0000-000000002101'),
    '3',
    'nightly recompute re-seeds the GCed mark while readings are retained'
);

-- 5. The GC job is registered (the Deno scheduler mirrors it on Railway).
SELECT ok(
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'segment-contributor-marks-gc'),
    'segment-contributor-marks-gc job is registered'
);

SELECT * FROM finish();
