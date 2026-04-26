CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(25);

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000e501'::UUID,
    '00000000-0000-0000-0000-00000000e502'::UUID,
    '00000000-0000-0000-0000-00000000e503'::UUID
);

DELETE FROM processed_batches
WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000e501'::UUID,
    '00000000-0000-0000-0000-00000000e502'::UUID,
    '00000000-0000-0000-0000-00000000e503'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (950001, 950002);

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
) VALUES
    (
        '00000000-0000-0000-0000-00000000f001',
        950001,
        0,
        ST_GeomFromText('LINESTRING(-63.5800 44.6490,-63.5788 44.6490)', 4326),
        100.0,
        'Paved Test Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-00000000f002',
        950002,
        0,
        ST_GeomFromText('LINESTRING(-63.5900 44.6510,-63.5888 44.6510)', 4326),
        100.0,
        'Gravel Test Road',
        'track',
        'gravel',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    );

CREATE TEMP TABLE tmp_ingest_result AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-00000000e501'::UUID,
    decode('aa', 'hex'),
    '[
        {
            "lat": 44.6490,
            "lng": -63.5794,
            "roughness_rms": 0.12,
            "speed_kmh": 52.0,
            "heading": 90.0,
            "gps_accuracy_m": 6.0,
            "recorded_at": "2026-04-25T13:00:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        },
        {
            "lat": 44.6510,
            "lng": -63.5894,
            "roughness_rms": 0.95,
            "speed_kmh": 48.0,
            "heading": 90.0,
            "gps_accuracy_m": 7.0,
            "recorded_at": "2026-04-25T13:01:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        },
        {
            "lat": 42.9000,
            "lng": -64.5000,
            "roughness_rms": 0.50,
            "speed_kmh": 55.0,
            "heading": 90.0,
            "gps_accuracy_m": 5.0,
            "recorded_at": "2026-04-25T13:02:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        },
        {
            "lat": 44.6490,
            "lng": -63.5794,
            "roughness_rms": 0.50,
            "speed_kmh": 55.0,
            "heading": 90.0,
            "gps_accuracy_m": 25.0,
            "recorded_at": "2026-04-25T13:03:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        },
        {
            "lat": 44.6490,
            "lng": -63.7000,
            "roughness_rms": 0.50,
            "speed_kmh": 55.0,
            "heading": 90.0,
            "gps_accuracy_m": 5.0,
            "recorded_at": "2026-04-25T13:04:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        },
        {
            "lat": 44.6490,
            "lng": -63.5794,
            "roughness_rms": 0.50,
            "speed_kmh": 55.0,
            "heading": 90.0,
            "gps_accuracy_m": 5.0,
            "recorded_at": "2026-04-01T13:05:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        }
    ]'::JSONB,
    '2026-04-25T13:10:00Z'::TIMESTAMPTZ,
    '0.1.0 (1)',
    'iOS 18.0'
) AS payload;

SELECT is(
    (SELECT (payload->>'accepted')::INTEGER FROM tmp_ingest_result),
    1,
    'ingest_reading_batch accepts the single paved in-bounds reading'
);

SELECT is(
    (SELECT (payload->>'rejected')::INTEGER FROM tmp_ingest_result),
    5,
    'ingest_reading_batch soft-rejects the remaining readings'
);

SELECT is(
    (SELECT payload->>'duplicate' FROM tmp_ingest_result),
    'false',
    'first ingest result is not marked duplicate'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'unpaved' FROM tmp_ingest_result),
    '1',
    'rejected_reasons counts unpaved readings'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'out_of_bounds' FROM tmp_ingest_result),
    '1',
    'rejected_reasons counts out_of_bounds readings'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'low_quality' FROM tmp_ingest_result),
    '1',
    'rejected_reasons counts low_quality readings'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'no_segment_match' FROM tmp_ingest_result),
    '1',
    'rejected_reasons counts no_segment_match readings'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'stale_timestamp' FROM tmp_ingest_result),
    '1',
    'rejected_reasons counts stale_timestamp readings'
);

SELECT is(
    (SELECT COUNT(*)::INTEGER FROM readings WHERE batch_id = '00000000-0000-0000-0000-00000000e501'::UUID),
    1,
    'only accepted readings are persisted'
);

SELECT is(
    (
        SELECT segment_id::TEXT
        FROM readings
        WHERE batch_id = '00000000-0000-0000-0000-00000000e501'::UUID
        LIMIT 1
    ),
    '00000000-0000-0000-0000-00000000f001',
    'accepted reading is matched to the paved segment'
);

SELECT is(
    (
        SELECT accepted_count::TEXT
        FROM processed_batches
        WHERE batch_id = '00000000-0000-0000-0000-00000000e501'::UUID
    ),
    '1',
    'processed_batches stores accepted_count'
);

SELECT is(
    (
        SELECT rejected_reasons->>'unpaved'
        FROM processed_batches
        WHERE batch_id = '00000000-0000-0000-0000-00000000e501'::UUID
    ),
    '1',
    'processed_batches persists rejected_reasons for duplicate replay'
);

SELECT is(
    (
        SELECT total_readings::TEXT
        FROM segment_aggregates
        WHERE segment_id = '00000000-0000-0000-0000-00000000f001'::UUID
    ),
    '1',
    'accepted readings are folded into segment_aggregates'
);

SELECT is(
    (
        SELECT roughness_category::TEXT
        FROM segment_aggregates
        WHERE segment_id = '00000000-0000-0000-0000-00000000f001'::UUID
    ),
    'rough',
    'aggregate category reflects the accepted reading score'
);

CREATE TEMP TABLE tmp_duplicate_result AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-00000000e501'::UUID,
    decode('aa', 'hex'),
    '[]'::JSONB,
    '2026-04-25T13:10:00Z'::TIMESTAMPTZ,
    '0.1.0 (1)',
    'iOS 18.0'
) AS payload;

SELECT is(
    (SELECT payload->>'duplicate' FROM tmp_duplicate_result),
    'true',
    'duplicate batch replays instead of reprocessing'
);

SELECT is(
    (SELECT (payload->>'accepted')::INTEGER FROM tmp_duplicate_result),
    1,
    'duplicate batch replays original accepted count'
);

SELECT is(
    (SELECT COUNT(*)::INTEGER FROM readings WHERE batch_id = '00000000-0000-0000-0000-00000000e501'::UUID),
    1,
    'duplicate replay does not insert additional readings'
);

CREATE TEMP TABLE tmp_cross_batch_duplicate_result AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-00000000e503'::UUID,
    decode('aa', 'hex'),
    '[
        {
            "lat": 44.6490,
            "lng": -63.5794,
            "roughness_rms": 0.12,
            "speed_kmh": 52.0,
            "heading": 90.0,
            "gps_accuracy_m": 6.0,
            "recorded_at": "2026-04-25T13:00:00Z",
            "is_pothole": false,
            "pothole_magnitude": null
        }
    ]'::JSONB,
    '2026-04-25T13:10:00Z'::TIMESTAMPTZ,
    '0.1.0 (1)',
    'iOS 18.0'
) AS payload;

SELECT is(
    (SELECT (payload->>'accepted')::INTEGER FROM tmp_cross_batch_duplicate_result),
    0,
    'cross-batch duplicate physical readings are not accepted again'
);

SELECT is(
    (SELECT payload->'rejected_reasons'->>'duplicate_reading' FROM tmp_cross_batch_duplicate_result),
    '1',
    'cross-batch duplicate physical readings are counted as duplicate_reading'
);

SELECT is(
    (SELECT COUNT(*)::INTEGER FROM readings WHERE device_token_hash = decode('aa', 'hex') AND recorded_at = '2026-04-25T13:00:00Z'::TIMESTAMPTZ),
    1,
    'cross-batch duplicate suppression prevents extra reading rows'
);

SELECT is(
    (
        SELECT total_readings::TEXT
        FROM segment_aggregates
        WHERE segment_id = '00000000-0000-0000-0000-00000000f001'::UUID
    ),
    '1',
    'cross-batch duplicate suppression prevents aggregate double-counting'
);

SELECT throws_ok(
    $$SELECT ingest_reading_batch(
        '00000000-0000-0000-0000-00000000e502'::UUID,
        decode('bb', 'hex'),
        '{"not":"an-array"}'::JSONB,
        '2026-04-25T13:10:00Z'::TIMESTAMPTZ,
        '0.1.0 (1)',
        'iOS 18.0'
    )$$,
    NULL,
    'p_readings must be a JSON array',
    'malformed payloads hard-fail before processing'
);

SELECT ok(
    POSITION(
        'pg_advisory_xact_lock' IN pg_get_functiondef(
            'public.ingest_reading_batch(uuid,bytea,jsonb,timestamp with time zone,text,text)'::regprocedure
        )
    ) > 0,
    'ingest_reading_batch serializes duplicate retries with an advisory lock'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.ingest_reading_batch(uuid,bytea,jsonb,timestamp with time zone,text,text)', 'EXECUTE'),
    'anon cannot execute ingest_reading_batch'
);

SELECT ok(
    has_function_privilege('service_role', 'public.ingest_reading_batch(uuid,bytea,jsonb,timestamp with time zone,text,text)', 'EXECUTE'),
    'service_role can execute ingest_reading_batch'
);

SELECT * FROM finish();
