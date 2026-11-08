CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(12);

DELETE FROM pothole_reports
WHERE id = '00000000-0000-0000-0000-000000001801'::UUID;

DELETE FROM segment_aggregates
WHERE segment_id IN (
    '00000000-0000-0000-0000-000000001701'::UUID,
    '00000000-0000-0000-0000-000000001702'::UUID,
    '00000000-0000-0000-0000-000000001703'::UUID,
    '00000000-0000-0000-0000-000000001704'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (980001, 980002, 980003, 980004);

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
        '00000000-0000-0000-0000-000000001701',
        980001,
        0,
        ST_GeomFromText('LINESTRING(-63.5600 44.6550,-63.5588 44.6550)', 4326),
        100.0,
        'Tile High Confidence Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000001702',
        980002,
        0,
        ST_GeomFromText('LINESTRING(-63.1010 44.7000,-63.0990 44.7000)', 4326),
        150.0,
        'Tile Low Confidence Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000001703',
        980003,
        0,
        ST_GeomFromText('LINESTRING(-64.3500 44.3800,-64.3488 44.3800)', 4326),
        90.0,
        'Tile Local Road',
        'residential',
        'asphalt',
        'District of Lunenburg',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000001704',
        980004,
        0,
        ST_GeomFromText('LINESTRING(-63.3006 44.9000,-63.2994 44.9000)', 4326),
        95.0,
        'Tile Two Contributor Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    );

INSERT INTO segment_aggregates (
    segment_id,
    avg_roughness_score,
    roughness_category,
    total_readings,
    unique_contributors,
    confidence,
    last_reading_at,
    pothole_count,
    trend,
    score_last_30d,
    score_30_60d
) VALUES
    (
        '00000000-0000-0000-0000-000000001701',
        0.810,
        'rough',
        24,
        12,
        'high',
        now() - INTERVAL '1 hour',
        1,
        'stable',
        0.800,
        0.770
    ),
    (
        '00000000-0000-0000-0000-000000001702',
        0.920,
        'rough',
        3,
        3,
        'low',
        now() - INTERVAL '2 hours',
        0,
        'stable',
        0.910,
        0.900
    ),
    (
        '00000000-0000-0000-0000-000000001703',
        0.710,
        'rough',
        3,
        1,
        'low',
        now() - INTERVAL '30 minutes',
        0,
        'stable',
        0.700,
        0.690
    ),
    (
        '00000000-0000-0000-0000-000000001704',
        0.650,
        'rough',
        5,
        2,
        'low',
        now() - INTERVAL '3 hours',
        0,
        'stable',
        0.640,
        0.630
    );

INSERT INTO pothole_reports (
    id,
    segment_id,
    geom,
    magnitude,
    first_reported_at,
    last_confirmed_at,
    confirmation_count,
    unique_reporters,
    status
) VALUES (
    '00000000-0000-0000-0000-000000001801',
    '00000000-0000-0000-0000-000000001701',
    ST_GeomFromText('POINT(-63.5594 44.6550)', 4326),
    2.70,
    now() - INTERVAL '10 days',
    now() - INTERVAL '1 day',
    4,
    3,
    'active'
);

SELECT has_function(
    'public',
    'get_tile',
    ARRAY['integer', 'integer', 'integer'],
    'get_tile function exists'
);

SELECT lives_ok(
    $$SELECT get_tile(14, 5299, 5915)$$,
    'get_tile succeeds for a populated Halifax tile'
);

SELECT cmp_ok(
    octet_length(get_tile(14, 5299, 5915)),
    '>',
    0,
    'tile returns MVT bytes for visible segments'
);

SELECT cmp_ok(
    octet_length(get_tile(14, 5320, 5912)),
    '>',
    0,
    'a low-confidence segment with three distinct contributors is still emitted'
);

-- P0-5 (2026-10-18 review): the k-anonymity floor is back in get_tile. A
-- segment driven by fewer than three distinct devices is never published,
-- whatever its confidence tier or zoom.
SELECT is(
    octet_length(get_tile(14, 5311, 5900)),
    0,
    'a segment with only two distinct contributors is not published'
);

SELECT is(
    octet_length(get_tile(14, 5263, 5933)),
    0,
    'a single-contributor residential segment is not published even at street zoom'
);

-- Zoom rules (20260424213000 onward): z < 6 is empty, z 6-11 shows the
-- arterial network only.
SELECT cmp_ok(
    octet_length(get_tile(7, 41, 46)),
    '>',
    0,
    'province-scale z7 tiles include scored arterial segments'
);

SELECT is(
    octet_length(get_tile(5, 10, 11)),
    0,
    'zoom levels below 6 return an empty tile'
);

SELECT is(
    octet_length(get_tile(10, 328, 370)),
    0,
    'default-zoom tiles leave out local roads (and sub-k segments)'
);

SELECT ok(
    has_function_privilege('service_role', 'public.get_tile(integer,integer,integer)', 'EXECUTE'),
    'service_role can execute get_tile'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.get_tile(integer,integer,integer)', 'EXECUTE'),
    'anon cannot execute get_tile directly'
);

SELECT ok(
    position('sa.unique_contributors >= 3' IN pg_get_functiondef('public.get_tile(integer,integer,integer)'::regprocedure)) > 0
    AND position('sa.confidence != ''low''' IN pg_get_functiondef('public.get_tile(integer,integer,integer)'::regprocedure)) = 0,
    'get_tile enforces the contributor floor in-function but not a confidence floor'
);

SELECT * FROM finish();
