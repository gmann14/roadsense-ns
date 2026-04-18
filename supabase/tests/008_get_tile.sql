CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(8);

DELETE FROM pothole_reports
WHERE id = '00000000-0000-0000-0000-000000001801'::UUID;

DELETE FROM segment_aggregates
WHERE segment_id IN (
    '00000000-0000-0000-0000-000000001701'::UUID,
    '00000000-0000-0000-0000-000000001702'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (980001, 980002);

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
        2,
        2,
        'low',
        now() - INTERVAL '2 hours',
        0,
        'stable',
        0.910,
        0.900
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
    'high-confidence tile returns MVT bytes'
);

SELECT is(
    octet_length(get_tile(14, 5320, 5912)),
    0,
    'tile containing only low-confidence segments is suppressed'
);

SELECT is(
    octet_length(get_tile(9, 331, 369)),
    0,
    'zoom levels below 10 return an empty tile'
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
    position('sa.confidence != ''low''' IN pg_get_functiondef('public.get_tile(integer,integer,integer)'::regprocedure)) > 0,
    'get_tile enforces low-confidence suppression in the function body'
);

SELECT * FROM finish();
