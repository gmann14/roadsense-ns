CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(13);

-- Fixture timestamps were authored around 2026-06-15. Every fixture time is
-- shifted by the same whole number of days so that 2026-06-15 lands on
-- yesterday (UTC): ordering, time of day and the gaps between fixtures are
-- unchanged, but the data stays inside the ingest freshness, action-window
-- and 6-month retention rules and inside the monthly readings partitions
-- that exist at test time.
CREATE OR REPLACE FUNCTION pg_temp.fixture_ts(p_value TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $fixture$
    SELECT p_value::TIMESTAMPTZ
        + (((now() AT TIME ZONE 'UTC')::DATE - 1) - DATE '2026-06-15') * INTERVAL '1 day'
$fixture$;

CREATE OR REPLACE FUNCTION pg_temp.fixture_jsonb(p_value TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fixture$
DECLARE
    v_match TEXT;
    v_result TEXT := p_value;
BEGIN
    FOR v_match IN
        SELECT DISTINCT (regexp_matches(p_value, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', 'g'))[1]
    LOOP
        v_result := replace(
            v_result,
            v_match,
            to_char(pg_temp.fixture_ts(v_match) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        );
    END LOOP;
    RETURN v_result::JSONB;
END;
$fixture$;

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000a401'::UUID,
    '00000000-0000-0000-0000-00000000a402'::UUID,
    '00000000-0000-0000-0000-00000000a403'::UUID,
    '00000000-0000-0000-0000-00000000a404'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (940001, 940002, 940003);

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
        '00000000-0000-0000-0000-00000000b001',
        940001,
        0,
        ST_GeomFromText('LINESTRING(-63.6000 44.6500,-63.5988 44.6500)', 4326),
        100.0,
        'Reassigned Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-00000000b002',
        940002,
        0,
        ST_GeomFromText('LINESTRING(-63.6200 44.6600,-63.6188 44.6600)', 4326),
        100.0,
        'Stable Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-00000000b003',
        940003,
        0,
        ST_GeomFromText('LINESTRING(-63.6400 44.6700,-63.6388 44.6700)', 4326),
        100.0,
        'Unpaved Road',
        'track',
        'gravel',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    );

INSERT INTO readings (
    id,
    segment_id,
    batch_id,
    device_token_hash,
    roughness_rms,
    speed_kmh,
    heading_degrees,
    gps_accuracy_m,
    is_pothole,
    pothole_magnitude,
    location,
    recorded_at
) VALUES
    (
        '00000000-0000-0000-0000-00000000c001',
        '00000000-0000-0000-0000-00000000d001',
        '00000000-0000-0000-0000-00000000a401',
        decode('01', 'hex'),
        0.75,
        50.0,
        90.0,
        5.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.5994 44.6500)', 4326),
        pg_temp.fixture_ts('2026-06-15T12:00:00Z')
    ),
    (
        '00000000-0000-0000-0000-00000000c002',
        '00000000-0000-0000-0000-00000000b002',
        '00000000-0000-0000-0000-00000000a402',
        decode('02', 'hex'),
        0.35,
        55.0,
        270.0,
        5.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.6194 44.6600)', 4326),
        pg_temp.fixture_ts('2026-06-15T12:10:00Z')
    ),
    (
        '00000000-0000-0000-0000-00000000c003',
        '00000000-0000-0000-0000-00000000d003',
        '00000000-0000-0000-0000-00000000a403',
        decode('03', 'hex'),
        1.10,
        45.0,
        90.0,
        6.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.6394 44.6700)', 4326),
        pg_temp.fixture_ts('2026-06-15T12:20:00Z')
    ),
    (
        '00000000-0000-0000-0000-00000000c004',
        '00000000-0000-0000-0000-00000000d004',
        '00000000-0000-0000-0000-00000000a404',
        decode('04', 'hex'),
        0.60,
        45.0,
        90.0,
        6.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.5994 44.6500)', 4326),
        pg_temp.fixture_ts('2026-06-13T12:00:00Z')
    );

CREATE TEMP TABLE tmp_rematch_result AS
SELECT unnest(rematch_readings_after_segment_refresh(pg_temp.fixture_ts('2026-06-14T00:00:00Z'))) AS touched_segment_id;

SELECT is(
    (SELECT segment_id::TEXT FROM readings WHERE id = '00000000-0000-0000-0000-00000000c001'),
    '00000000-0000-0000-0000-00000000b001',
    'reading rematches onto the new paved segment'
);

SELECT is(
    (SELECT segment_id::TEXT FROM readings WHERE id = '00000000-0000-0000-0000-00000000c002'),
    '00000000-0000-0000-0000-00000000b002',
    'reading on an unchanged segment keeps the same segment_id'
);

SELECT is(
    (SELECT segment_id::TEXT FROM readings WHERE id = '00000000-0000-0000-0000-00000000c003'),
    NULL,
    'reading loses its segment when only an unpaved match remains'
);

SELECT is(
    (SELECT segment_id::TEXT FROM readings WHERE id = '00000000-0000-0000-0000-00000000c004'),
    '00000000-0000-0000-0000-00000000d004',
    'readings older than p_since are left untouched'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM tmp_rematch_result),
    3,
    'touched segment list includes only the changed old and new segment ids'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM tmp_rematch_result
        WHERE touched_segment_id = '00000000-0000-0000-0000-00000000d001'::UUID
    ),
    'touched ids include the old segment for the reassigned reading'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM tmp_rematch_result
        WHERE touched_segment_id = '00000000-0000-0000-0000-00000000b001'::UUID
    ),
    'touched ids include the new segment for the reassigned reading'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM tmp_rematch_result
        WHERE touched_segment_id = '00000000-0000-0000-0000-00000000d003'::UUID
    ),
    'touched ids include the old segment that became unmatched'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM tmp_rematch_result
        WHERE touched_segment_id = '00000000-0000-0000-0000-00000000b002'::UUID
    ),
    'unchanged segments are not returned in the touched list'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.rematch_readings_after_segment_refresh(timestamp with time zone)', 'EXECUTE'),
    'anon cannot execute rematch_readings_after_segment_refresh'
);

SELECT ok(
    has_function_privilege('service_role', 'public.rematch_readings_after_segment_refresh(timestamp with time zone)', 'EXECUTE'),
    'service_role can execute rematch_readings_after_segment_refresh'
);

SELECT lives_ok(
    $$SELECT rematch_readings_after_segment_refresh(pg_temp.fixture_ts('2026-06-14T00:00:00Z'))$$,
    'rematch_readings_after_segment_refresh is idempotent after the first rewrite'
);

SELECT is(
    (SELECT count(*)::INTEGER FROM (
        SELECT unnest(rematch_readings_after_segment_refresh(pg_temp.fixture_ts('2026-06-14T00:00:00Z')))
    ) rerun),
    0,
    'second rematch pass returns no touched segments once the data is reconciled'
);

SELECT * FROM finish();
