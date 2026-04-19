CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(14);

DELETE FROM segment_aggregates
WHERE segment_id IN (
    '00000000-0000-0000-0000-000000001901'::UUID,
    '00000000-0000-0000-0000-000000001902'::UUID,
    '00000000-0000-0000-0000-000000002101'::UUID,
    '00000000-0000-0000-0000-000000002102'::UUID,
    '00000000-0000-0000-0000-000000002103'::UUID,
    '00000000-0000-0000-0000-000000002104'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (990001, 990002, 991001, 991002, 991003, 991004);

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
        '00000000-0000-0000-0000-000000002101',
        991001,
        0,
        ST_GeomFromText('LINESTRING(-63.5600 44.6550,-63.5588 44.6550)', 4326),
        100.0,
        'Coverage None Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000002102',
        991002,
        0,
        ST_GeomFromText('LINESTRING(-63.5598 44.6553,-63.5586 44.6553)', 4326),
        100.0,
        'Coverage Emerging Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000002103',
        991003,
        0,
        ST_GeomFromText('LINESTRING(-63.5596 44.6556,-63.5584 44.6556)', 4326),
        100.0,
        'Coverage Published Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000002104',
        991004,
        0,
        ST_GeomFromText('LINESTRING(-63.5594 44.6559,-63.5582 44.6559)', 4326),
        100.0,
        'Coverage Strong Road',
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
        '00000000-0000-0000-0000-000000002102',
        0.410,
        'fair',
        2,
        2,
        'low',
        now() - INTERVAL '3 hours',
        0,
        'stable',
        0.410,
        0.400
    ),
    (
        '00000000-0000-0000-0000-000000002103',
        0.720,
        'rough',
        11,
        5,
        'medium',
        now() - INTERVAL '2 hours',
        1,
        'stable',
        0.710,
        0.700
    ),
    (
        '00000000-0000-0000-0000-000000002104',
        1.240,
        'very_rough',
        22,
        12,
        'high',
        now() - INTERVAL '1 hour',
        3,
        'worsening',
        1.250,
        1.100
    );

SELECT has_function(
    'public',
    'get_coverage_tile',
    ARRAY['integer', 'integer', 'integer'],
    'get_coverage_tile exists'
);

SELECT lives_ok(
    $$SELECT get_coverage_tile(14, 5299, 5915)$$,
    'get_coverage_tile succeeds for a Halifax tile'
);

SELECT cmp_ok(
    octet_length(get_coverage_tile(14, 5299, 5915)),
    '>',
    0,
    'coverage tile returns bytes when matching roads exist'
);

SELECT is(
    octet_length(get_coverage_tile(9, 331, 369)),
    0,
    'coverage tile returns empty bytes below zoom 10'
);

SELECT ok(
    position('''none''' IN lower(pg_get_functiondef('public.get_coverage_tile(integer,integer,integer)'::regprocedure))) > 0
    AND position('''emerging''' IN lower(pg_get_functiondef('public.get_coverage_tile(integer,integer,integer)'::regprocedure))) > 0
    AND position('''published''' IN lower(pg_get_functiondef('public.get_coverage_tile(integer,integer,integer)'::regprocedure))) > 0
    AND position('''strong''' IN lower(pg_get_functiondef('public.get_coverage_tile(integer,integer,integer)'::regprocedure))) > 0,
    'get_coverage_tile derives the documented coverage levels in-function'
);

SELECT ok(
    has_function_privilege('service_role', 'public.get_coverage_tile(integer,integer,integer)', 'EXECUTE'),
    'service_role can execute get_coverage_tile'
);

SELECT ok(
    NOT has_function_privilege('anon', 'public.get_coverage_tile(integer,integer,integer)', 'EXECUTE'),
    'anon cannot execute get_coverage_tile directly'
);

REFRESH MATERIALIZED VIEW public_worst_segments_mv;

SELECT ok(
    to_regclass('public.public_worst_segments_mv') IS NOT NULL,
    'public_worst_segments_mv exists'
);

SELECT has_index(
    'public',
    'public_worst_segments_mv',
    'idx_public_worst_segments_mv_segment_id',
    'public_worst_segments_mv has unique segment_id index'
);

SELECT is(
    (SELECT count(*)::TEXT FROM public_worst_segments_mv),
    '2',
    'worst-segments MV includes only published paved segments'
);

SELECT is(
    (SELECT segment_id::TEXT FROM public_worst_segments_mv ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC LIMIT 1),
    '00000000-0000-0000-0000-000000002104',
    'worst-segments MV ranks the roughest published road first'
);

SELECT is(
    (
        SELECT string_agg(segment_id::TEXT, ',' ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC)
        FROM public_worst_segments_mv
        WHERE municipality = 'Halifax'
    ),
    '00000000-0000-0000-0000-000000002104,00000000-0000-0000-0000-000000002103',
    'worst-segments MV sorts using the documented ranking order'
);

SELECT ok(
    has_table_privilege('service_role', 'public.public_worst_segments_mv', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.public_worst_segments_mv', 'SELECT'),
    'public_worst_segments_mv is service-role readable only'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM cron.job
        WHERE jobname = 'refresh-public-worst-segments-mv'
          AND command = 'REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv'
    ),
    'cron registration exists for concurrent worst-segments refresh'
);

SELECT * FROM finish();
