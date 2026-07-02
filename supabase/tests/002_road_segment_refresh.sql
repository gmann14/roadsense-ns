CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(22);

TRUNCATE road_segments_staging;
DELETE FROM road_segments
WHERE osm_way_id IN (900001, 900002, 900003, 900004);

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
        '00000000-0000-0000-0000-000000000101',
        900001,
        0,
        ST_GeomFromText('LINESTRING(-63.60 44.60,-63.599 44.601)', 4326),
        50.0,
        'Old Road',
        'residential',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        45.00
    ),
    (
        '00000000-0000-0000-0000-000000000102',
        900002,
        0,
        ST_GeomFromText('LINESTRING(-63.61 44.61,-63.609 44.611)', 4326),
        50.0,
        'Delete Me',
        'service',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    );

INSERT INTO road_segments_staging (
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
        900001,
        0,
        ST_GeomFromText('LINESTRING(-63.60 44.60,-63.598 44.602)', 4326),
        62.5,
        'Updated Road',
        'primary',
        'concrete',
        'Halifax',
        TRUE,
        FALSE,
        FALSE,
        123.45
    ),
    (
        900003,
        0,
        ST_GeomFromText('LINESTRING(-63.62 44.62,-63.619 44.621)', 4326),
        48.5,
        'New Road',
        'secondary',
        'asphalt',
        'Dartmouth',
        FALSE,
        TRUE,
        FALSE,
        270.00
    );

SELECT lives_ok(
    $$SELECT apply_road_segment_refresh()$$,
    'apply_road_segment_refresh runs successfully'
);

SELECT is(
    (SELECT id::text FROM road_segments WHERE osm_way_id = 900001 AND segment_index = 0),
    '00000000-0000-0000-0000-000000000101',
    'existing segment keeps its stable id'
);

SELECT is(
    (SELECT road_name FROM road_segments WHERE osm_way_id = 900001 AND segment_index = 0),
    'Updated Road',
    'existing segment attributes are updated'
);

SELECT is(
    (SELECT road_type FROM road_segments WHERE osm_way_id = 900001 AND segment_index = 0),
    'primary',
    'road_type is refreshed from staging'
);

SELECT is(
    (SELECT surface_type FROM road_segments WHERE osm_way_id = 900001 AND segment_index = 0),
    'concrete',
    'surface_type is refreshed from staging'
);

SELECT is(
    (SELECT has_speed_bump::text FROM road_segments WHERE osm_way_id = 900001 AND segment_index = 0),
    'true',
    'feature flags are refreshed from staging'
);

SELECT is(
    (SELECT municipality FROM road_segments WHERE osm_way_id = 900003 AND segment_index = 0),
    'Dartmouth',
    'new staged segment is inserted'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM road_segments
        WHERE osm_way_id = 900003
          AND segment_index = 0
    ),
    'new segment exists after refresh'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM road_segments
        WHERE osm_way_id = 900002
          AND segment_index = 0
    ),
    'segments missing from staging are deleted'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_class
        WHERE relname = 'road_segments_staging'
    ),
    'road_segments_staging exists'
);

SELECT has_index(
    'public',
    'road_segments_staging',
    'idx_segments_staging_geom',
    'staging geom index exists'
);

SELECT has_index(
    'public',
    'road_segments_staging',
    'idx_segments_staging_geog',
    'staging geography expression index exists'
);

SELECT has_function(
    'public',
    'apply_road_segment_refresh',
    ARRAY[]::TEXT[],
    'apply_road_segment_refresh function exists'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.apply_road_segment_refresh()', 'EXECUTE'),
    'anon cannot execute apply_road_segment_refresh'
);

SELECT ok(
    has_function_privilege('service_role', 'public.apply_road_segment_refresh()', 'EXECUTE'),
    'service_role can execute apply_road_segment_refresh'
);

-- P0 (lower severity): road_segments_staging held no sensitive data but was
-- also missing RLS/anon-revoke like every other operational table. Fixed in
-- 20260702120000_pothole_actions_rls.sql.
SELECT ok(
    (
        SELECT relrowsecurity
        FROM pg_class
        WHERE relnamespace = 'public'::regnamespace
          AND relname = 'road_segments_staging'
    ),
    'road_segments_staging has row level security enabled'
);

SELECT ok(
    NOT has_table_privilege('anon', 'public.road_segments_staging', 'SELECT'),
    'anon cannot read road_segments_staging'
);

SELECT ok(
    NOT has_table_privilege('anon', 'public.road_segments_staging', 'INSERT'),
    'anon cannot write road_segments_staging'
);

-- P0: apply_road_segment_refresh() used to DELETE FROM road_segments WHERE
-- NOT EXISTS (... staging ...) unconditionally. An empty or drastically
-- truncated road_segments_staging (failed import, script run out of order)
-- would therefore wipe the whole road network. At this point in the test
-- file, road_segments holds exactly the two rows left by the merge test
-- above (900001, 900003) — populate a road_segments row count comparable to
-- a "real" network relative to that, so the >50% drop threshold is exercised
-- meaningfully.
DELETE FROM road_segments WHERE osm_way_id BETWEEN 900010 AND 900019;
INSERT INTO road_segments (
    osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
)
SELECT
    900010 + gs,
    0,
    ST_GeomFromText('LINESTRING(-63.60 44.60,-63.599 44.601)', 4326),
    50.0,
    'Guard Fixture Road ' || gs,
    'residential',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    45.00
FROM generate_series(0, 7) AS gs;

-- Case 1: staging is completely empty → must raise, must not delete anything.
TRUNCATE road_segments_staging;

SELECT throws_ok(
    $$SELECT apply_road_segment_refresh()$$,
    'P0001',
    NULL,
    'apply_road_segment_refresh raises when road_segments_staging is empty'
);

SELECT ok(
    (SELECT COUNT(*) FROM road_segments WHERE osm_way_id BETWEEN 900010 AND 900019) = 8,
    'road_segments is untouched after the empty-staging guard fires'
);

-- Case 2: staging has far fewer rows than road_segments (a truncated/corrupt
-- import) → must also raise rather than deleting the difference.
INSERT INTO road_segments_staging (
    osm_way_id, segment_index, geom, length_m, road_name, road_type,
    surface_type, municipality, has_speed_bump, has_rail_crossing,
    is_parking_aisle, bearing_degrees
) VALUES (
    900010, 0,
    ST_GeomFromText('LINESTRING(-63.60 44.60,-63.598 44.602)', 4326),
    50.0, 'Guard Fixture Road 0', 'residential', 'asphalt', 'Halifax',
    FALSE, FALSE, FALSE, 45.00
);

SELECT throws_ok(
    $$SELECT apply_road_segment_refresh()$$,
    'P0001',
    NULL,
    'apply_road_segment_refresh raises when staging has collapsed to well under half of road_segments'
);

SELECT ok(
    (SELECT COUNT(*) FROM road_segments WHERE osm_way_id BETWEEN 900010 AND 900019) = 8,
    'road_segments is untouched after the truncated-import guard fires'
);

-- Cleanup the guard fixtures so they do not leak into later assertions in
-- this file (none currently follow, but keep the file self-contained).
DELETE FROM road_segments WHERE osm_way_id BETWEEN 900010 AND 900019;
TRUNCATE road_segments_staging;

SELECT * FROM finish();

