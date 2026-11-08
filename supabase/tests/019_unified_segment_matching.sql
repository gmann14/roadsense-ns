CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(15);

-- Fixture timestamps were authored around 2026-07-02. Every fixture time is
-- shifted by the same whole number of days so that 2026-07-02 lands on
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
        + (((now() AT TIME ZONE 'UTC')::DATE - 1) - DATE '2026-07-02') * INTERVAL '1 day'
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

-- P1: rematch_readings_after_segment_refresh, ingest_reading_batch, and
-- replay_unmatched_readings had drifted onto three different matching
-- criteria (flat 20m + strict surface allowlist vs tiered radii + permissive
-- surface reject-list vs a third variant). 20260702150000_unify_segment_matching.sql
-- extracted the shared decision into match_reading_to_segment() and pointed
-- all three callers at it. This suite exercises match_reading_to_segment()
-- directly (the now-single source of truth) plus each of the three callers,
-- and asserts they all treat the same fixture identically: a secondary road
-- at 22m (inside the new 25m secondary tier, outside the old flat 20m) and a
-- segment with surface_type IS NULL (rejected by the old strict allowlist,
-- accepted by the current criteria).

DELETE FROM readings WHERE batch_id IN (
    '00000000-0000-0000-0000-000000019401'::UUID,
    '00000000-0000-0000-0000-000000019402'::UUID
);
DELETE FROM unmatched_readings WHERE batch_id IN (
    '00000000-0000-0000-0000-000000019401'::UUID,
    '00000000-0000-0000-0000-000000019402'::UUID
);
DELETE FROM processed_batches WHERE batch_id IN (
    '00000000-0000-0000-0000-000000019401'::UUID,
    '00000000-0000-0000-0000-000000019402'::UUID
);
DELETE FROM road_segments WHERE osm_way_id IN (990001, 990002);

-- A secondary road, surface_type NULL (unknown), running east-west.
-- Old rematch criteria (flat 20m radius, strict allowlist requiring
-- surface_type IN ('paved','asphalt','concrete','paving_stones')) would
-- reject any point on this segment outright, since NULL is not in the
-- allowlist. Current/unified criteria: secondary tier is 25m, and
-- NULL/unknown surface is accepted.
INSERT INTO road_segments (
    id, osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
) VALUES (
    '00000000-0000-0000-0000-000000019a01',
    990001,
    0,
    ST_GeomFromText('LINESTRING(-63.6500 44.6800,-63.6480 44.6800)', 4326),
    150.0,
    'Unified Match Secondary Road',
    'secondary',
    NULL,
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.00
);

-- A point 22m north of the line's midpoint: inside the new 25m secondary
-- tier, outside the old flat 20m radius that rematch used to enforce.
-- 22m north at ~44.68 degN is roughly 0.000198 degrees latitude.
-- Heading 90 matches the segment's 90-degree bearing exactly.

SELECT is(
    (
        SELECT segment_id::TEXT
        FROM match_reading_to_segment(
            ST_SetSRID(ST_MakePoint(-63.6490, 44.68020), 4326),
            90.0
        )
    ),
    '00000000-0000-0000-0000-000000019a01',
    'match_reading_to_segment accepts a 22m-offset secondary-road point with a NULL surface_type'
);

-- ingest_reading_batch: same point/heading via the JSON payload path.
CREATE TEMP TABLE tmp_unify_ingest AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-000000019401'::UUID,
    decode('19', 'hex'),
    pg_temp.fixture_jsonb('[{"lat":44.68020,"lng":-63.6490,"roughness_rms":0.30,"speed_kmh":45,"heading":90,"gps_accuracy_m":5,"is_pothole":false,"pothole_magnitude":null,"recorded_at":"2026-07-02T12:00:00Z"}]'),
    pg_temp.fixture_ts('2026-07-02T12:01:00Z'),
    '0.1.0 (test)',
    'iOS test'
) AS payload;

SELECT is(
    (SELECT (payload->>'accepted')::INTEGER FROM tmp_unify_ingest),
    1,
    'ingest_reading_batch accepts the 22m-offset NULL-surface secondary-road reading'
);

SELECT is(
    (
        SELECT segment_id::TEXT
        FROM readings
        WHERE batch_id = '00000000-0000-0000-0000-000000019401'::UUID
    ),
    '00000000-0000-0000-0000-000000019a01',
    'ingest_reading_batch matches it to the same segment as match_reading_to_segment'
);

-- rematch_readings_after_segment_refresh: insert the reading directly as
-- unmatched (segment_id NULL), then confirm the rematch pass picks up the
-- same segment for the same point/heading/timestamp.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location,
    recorded_at
) VALUES (
    '00000000-0000-0000-0000-000000019c01',
    NULL,
    '00000000-0000-0000-0000-000000019402'::UUID,
    decode('19', 'hex'),
    0.30,
    45.0,
    90.0,
    5.0,
    FALSE,
    NULL,
    ST_SetSRID(ST_MakePoint(-63.6490, 44.68020), 4326),
    pg_temp.fixture_ts('2026-07-02T13:00:00Z')
);

SELECT lives_ok(
    $$SELECT rematch_readings_after_segment_refresh(pg_temp.fixture_ts('2026-07-02T12:59:00Z'))$$,
    'rematch_readings_after_segment_refresh runs against the fixture'
);

SELECT is(
    (
        SELECT segment_id::TEXT
        FROM readings
        WHERE id = '00000000-0000-0000-0000-000000019c01'
    ),
    '00000000-0000-0000-0000-000000019a01',
    'rematch_readings_after_segment_refresh matches the same 22m-offset NULL-surface reading to the same segment'
);

-- replay_unmatched_readings: put the same point/heading into the holding
-- table directly and confirm replay promotes it to the same segment.
INSERT INTO unmatched_readings (
    batch_id, device_token_hash, location, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude,
    recorded_at, last_match_attempt_at
) VALUES (
    '00000000-0000-0000-0000-000000019402'::UUID,
    decode('19', 'hex'),
    ST_SetSRID(ST_MakePoint(-63.6490, 44.68020), 4326),
    0.30,
    45.0,
    90.0,
    5.0,
    FALSE,
    NULL,
    pg_temp.fixture_ts('2026-07-02T14:00:00Z'),
    NULL
);

SELECT lives_ok(
    $$SELECT replay_unmatched_readings()$$,
    'replay_unmatched_readings runs against the fixture'
);

SELECT is(
    (
        SELECT segment_id::TEXT
        FROM readings
        WHERE device_token_hash = decode('19', 'hex')
          AND recorded_at = pg_temp.fixture_ts('2026-07-02T14:00:00Z')
    ),
    '00000000-0000-0000-0000-000000019a01',
    'replay_unmatched_readings promotes the same 22m-offset NULL-surface reading to the same segment'
);

-- Negative control: an explicitly unpaved secondary road at the same 22m
-- offset must be rejected by all three, so the shared surface-acceptance
-- criteria (not just radius) are exercised identically too.
INSERT INTO road_segments (
    id, osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
) VALUES (
    '00000000-0000-0000-0000-000000019a02',
    990002,
    0,
    ST_GeomFromText('LINESTRING(-63.7500 44.6800,-63.7480 44.6800)', 4326),
    150.0,
    'Unified Match Gravel Secondary Road',
    'secondary',
    'gravel',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.00
);

SELECT is(
    (
        SELECT COUNT(*)::INT
        FROM match_reading_to_segment(
            ST_SetSRID(ST_MakePoint(-63.7490, 44.68020), 4326),
            90.0
        )
    ),
    0,
    'match_reading_to_segment rejects a 22m-offset gravel secondary-road point'
);

CREATE TEMP TABLE tmp_unify_ingest_gravel AS
SELECT ingest_reading_batch(
    '00000000-0000-0000-0000-000000019403'::UUID,
    decode('19', 'hex'),
    pg_temp.fixture_jsonb('[{"lat":44.68020,"lng":-63.7490,"roughness_rms":0.30,"speed_kmh":45,"heading":90,"gps_accuracy_m":5,"is_pothole":false,"pothole_magnitude":null,"recorded_at":"2026-07-02T15:00:00Z"}]'),
    pg_temp.fixture_ts('2026-07-02T15:01:00Z'),
    '0.1.0 (test)',
    'iOS test'
) AS payload;

SELECT is(
    (SELECT payload->'rejected_reasons'->>'unpaved' FROM tmp_unify_ingest_gravel),
    '1',
    'ingest_reading_batch rejects the 22m-offset gravel secondary-road reading as unpaved'
);

DELETE FROM processed_batches WHERE batch_id = '00000000-0000-0000-0000-000000019403'::UUID;

SELECT has_function(
    'public',
    'match_reading_to_segment',
    ARRAY['geometry', 'double precision', 'boolean'],
    'match_reading_to_segment exists with the expected signature'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.match_reading_to_segment(geometry, double precision, boolean)', 'EXECUTE'),
    'anon cannot execute match_reading_to_segment'
);

SELECT ok(
    has_function_privilege('service_role', 'public.match_reading_to_segment(geometry, double precision, boolean)', 'EXECUTE'),
    'service_role can execute match_reading_to_segment'
);

-- Cross-check: the body of all three callers actually references the shared
-- function, so this suite (and future edits) can't silently drift back to
-- copy-pasted criteria.
SELECT ok(
    POSITION('match_reading_to_segment' IN pg_get_functiondef(
        'public.ingest_reading_batch(uuid,bytea,jsonb,timestamp with time zone,text,text)'::regprocedure
    )) > 0,
    'ingest_reading_batch body calls match_reading_to_segment'
);

SELECT ok(
    POSITION('match_reading_to_segment' IN pg_get_functiondef(
        'public.rematch_readings_after_segment_refresh(timestamp with time zone)'::regprocedure
    )) > 0,
    'rematch_readings_after_segment_refresh body calls match_reading_to_segment'
);

SELECT ok(
    POSITION('match_reading_to_segment' IN pg_get_functiondef(
        'public.replay_unmatched_readings(integer,integer)'::regprocedure
    )) > 0,
    'replay_unmatched_readings body calls match_reading_to_segment'
);

SELECT * FROM finish();
