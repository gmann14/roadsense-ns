CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(17);

-- Cleanup any previous fixture state.
DELETE FROM unmatched_readings WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000ee01'::UUID,
    '00000000-0000-0000-0000-00000000ee02'::UUID
);
DELETE FROM readings WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000ee01'::UUID,
    '00000000-0000-0000-0000-00000000ee02'::UUID
);
DELETE FROM processed_batches WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000ee01'::UUID,
    '00000000-0000-0000-0000-00000000ee02'::UUID
);
DELETE FROM road_segments WHERE osm_way_id = 970001;

-- Schema sanity.
SELECT has_table('unmatched_readings', 'unmatched_readings table exists');
SELECT col_not_null('unmatched_readings', 'batch_id', 'batch_id NOT NULL');
SELECT col_not_null('unmatched_readings', 'location', 'location NOT NULL');
SELECT col_not_null('unmatched_readings', 'recorded_at', 'recorded_at NOT NULL');

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'unmatched_readings'
          AND indexname = 'idx_unmatched_readings_geog'
    ),
    'unmatched_readings has a geography GIST index for replay matching'
);

-- 1. Submit a reading that has no matching road_segments → it should land in
--    unmatched_readings, NOT readings, and the batch should still be 200 with
--    rejected_reasons.no_segment_match.
--
-- Timestamps are built relative to now() (not hardcoded) so this test does
-- not go stale — ingest_reading_batch rejects readings recorded_at more than
-- 7 days in the past as 'stale_timestamp', independent of this test's own
-- logic. This block previously used a hardcoded 2026-04-27 literal, which
-- aged past that 7-day window and made the reading get rejected as
-- 'stale_timestamp' before segment-matching ever ran (see the ee02 block
-- below, which already uses this pattern).
SELECT lives_ok(
    format(
        $$
        SELECT ingest_reading_batch(
            '00000000-0000-0000-0000-00000000ee01'::UUID,
            decode('eeee', 'hex'),
            '[{"lat":44.0500,"lng":-61.5000,"roughness_rms":0.05,"speed_kmh":60,"heading":90,"gps_accuracy_m":5,"is_pothole":false,"pothole_magnitude":null,"recorded_at":"%s"}]'::JSONB,
            '%s'::TIMESTAMPTZ,
            '0.1.0 (test)',
            'iOS test'
        )
        $$,
        to_char(now() - INTERVAL '1 hour', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        to_char(now() - INTERVAL '1 hour' + INTERVAL '1 minute', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ),
    'ingest succeeds even when no road_segments match'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM unmatched_readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee01'::UUID),
    1,
    'no_segment_match reading lands in unmatched_readings holding table'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee01'::UUID),
    0,
    'no_segment_match reading is NOT inserted into readings'
);

-- 2. Add a road_segments row covering the held reading, then call replay.
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
    '00000000-0000-0000-0000-00000000fe01',
    970001,
    0,
    ST_GeomFromText('LINESTRING(-61.5010 44.0500,-61.4990 44.0500)', 4326),
    180.0,
    'Replay Coverage Road',
    'primary',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.00
);

SELECT lives_ok(
    $$ SELECT replay_unmatched_readings() $$,
    'replay_unmatched_readings runs without error after segments are added'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee01'::UUID),
    1,
    'replay promoted the previously-unmatched row into readings'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM unmatched_readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee01'::UUID),
    0,
    'unmatched_readings holding row is removed after promotion'
);

-- 3. Calling replay a second time when the row is already in readings must be
--    a safe no-op.
SELECT lives_ok(
    $$ SELECT replay_unmatched_readings() $$,
    'replay is idempotent — second call does not duplicate the promoted row'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee01'::UUID),
    1,
    'replay did not double-insert on second run'
);

-- P0: heading_degrees was NOT NULL on unmatched_readings
-- (20260428001647_unmatched_readings_holding_table.sql) even though heading
-- is nullable everywhere else in the pipeline (the upload-readings gateway
-- explicitly allows `heading: null`, readings.heading_degrees is nullable).
-- A single null-heading reading that failed segment match would raise a
-- not-null violation on the INSERT INTO unmatched_readings inside
-- ingest_reading_batch, aborting the WHOLE transaction — including any other
-- readings in the same up-to-1000-row batch that matched fine — and since
-- processed_batches never got written, the client would retry the same batch
-- forever. Fixed in 20260702120500_unmatched_readings_heading_nullable.sql.
SELECT ok(
    NOT (
        SELECT attnotnull
        FROM pg_attribute
        WHERE attrelid = 'public.unmatched_readings'::regclass
          AND attname = 'heading_degrees'
    ),
    'unmatched_readings.heading_degrees no longer rejects NULL'
);

-- Reproduction: a batch with one reading that has heading = NULL and lands
-- far from any road_segment (no_segment_match), mixed with one ordinary
-- reading that matches fine. Before the fix, the NULL-heading row's INSERT
-- into unmatched_readings raised a not-null violation and rolled back the
-- ENTIRE batch (including the reading that should have been accepted), and
-- since processed_batches is only written at the end of the function, the
-- batch was never marked processed — the client would retry forever.
--
-- Timestamps are built relative to now() (not hardcoded) so this test does
-- not go stale — ingest_reading_batch rejects readings recorded_at more than
-- 7 days in the past as 'stale_timestamp', independent of this test's own
-- logic.
DELETE FROM unmatched_readings WHERE batch_id = '00000000-0000-0000-0000-00000000ee02'::UUID;
DELETE FROM readings WHERE batch_id = '00000000-0000-0000-0000-00000000ee02'::UUID;
DELETE FROM processed_batches WHERE batch_id = '00000000-0000-0000-0000-00000000ee02'::UUID;

CREATE TEMP TABLE tmp_ee02_ingest_result AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-00000000ee02'::UUID,
    decode('ee02', 'hex'),
    -- 44.0700/-61.5200 is deliberately far from every other fixture segment
    -- in this file (including the 970001 replay-coverage road added above at
    -- 44.0500/-61.5010..-61.4990), so this reading has no legitimate match
    -- and must land in unmatched_readings regardless of its NULL heading.
    jsonb_build_array(
        jsonb_build_object(
            'lat', 44.0700, 'lng', -61.5200, 'roughness_rms', 0.05, 'speed_kmh', 60,
            'heading', NULL, 'gps_accuracy_m', 5, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '1 hour', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        jsonb_build_object(
            'lat', 44.6488, 'lng', -63.5748, 'roughness_rms', 0.05, 'speed_kmh', 60,
            'heading', 90, 'gps_accuracy_m', 5, 'is_pothole', false, 'pothole_magnitude', NULL,
            'recorded_at', to_char(now() - INTERVAL '1 hour' + INTERVAL '1 second', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )
    ),
    now(),
    '0.1.0 (test)',
    'iOS test'
) AS payload;

SELECT ok(
    (SELECT payload IS NOT NULL FROM tmp_ee02_ingest_result),
    'a batch containing a NULL-heading no-segment-match reading does not abort the whole transaction'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM processed_batches
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee02'::UUID),
    1,
    'the batch is recorded as processed (client will not retry forever)'
);

SELECT is(
    (SELECT COUNT(*)::INT
     FROM unmatched_readings
     WHERE batch_id = '00000000-0000-0000-0000-00000000ee02'::UUID
       AND heading_degrees IS NULL),
    1,
    'the NULL-heading reading is held in unmatched_readings with heading_degrees NULL'
);

