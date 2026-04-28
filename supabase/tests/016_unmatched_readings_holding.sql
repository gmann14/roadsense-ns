CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(13);

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
SELECT lives_ok(
    $$
    SELECT ingest_reading_batch(
        '00000000-0000-0000-0000-00000000ee01'::UUID,
        decode('eeee', 'hex'),
        '[{"lat":44.0500,"lng":-61.5000,"roughness_rms":0.05,"speed_kmh":60,"heading":90,"gps_accuracy_m":5,"is_pothole":false,"pothole_magnitude":null,"recorded_at":"2026-04-27T11:59:00Z"}]'::JSONB,
        '2026-04-27T12:00:00Z'::TIMESTAMPTZ,
        '0.1.0 (test)',
        'iOS test'
    )
    $$,
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

SELECT * FROM finish();
