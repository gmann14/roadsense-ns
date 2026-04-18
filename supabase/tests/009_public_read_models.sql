CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(11);

DELETE FROM pothole_reports;
DELETE FROM segment_aggregates;
DELETE FROM road_segments;

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
        '00000000-0000-0000-0000-000000001901',
        990001,
        0,
        ST_GeomFromText('LINESTRING(-63.5800 44.6450,-63.5790 44.6450)', 4326),
        100.0,
        'Stats Road One',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000001902',
        990002,
        0,
        ST_GeomFromText('LINESTRING(-63.5900 44.6460,-63.5890 44.6460)', 4326),
        120.0,
        'Stats Road Two',
        'secondary',
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
) VALUES (
    '00000000-0000-0000-0000-000000001901',
    0.730,
    'rough',
    7,
    4,
    'medium',
    now() - INTERVAL '30 minutes',
    1,
    'stable',
    0.720,
    0.700
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
    '00000000-0000-0000-0000-000000001951',
    '00000000-0000-0000-0000-000000001901',
    ST_GeomFromText('POINT(-63.5795 44.6450)', 4326),
    2.30,
    now() - INTERVAL '7 days',
    now() - INTERVAL '1 day',
    2,
    2,
    'active'
);

REFRESH MATERIALIZED VIEW public_stats_mv;

SELECT ok(
    to_regclass('public.public_stats_mv') IS NOT NULL,
    'public_stats_mv exists'
);

SELECT has_index(
    'public',
    'public_stats_mv',
    'public_stats_mv_singleton',
    'public_stats_mv has the singleton unique index'
);

SELECT cmp_ok(
    (SELECT total_km_mapped FROM public_stats_mv),
    '=',
    0.1::NUMERIC,
    'public_stats_mv reports mapped kilometres from scored segments only'
);

SELECT is(
    (SELECT total_readings::TEXT FROM public_stats_mv),
    '7',
    'public_stats_mv reports total readings'
);

SELECT is(
    (SELECT active_potholes::TEXT FROM public_stats_mv),
    '1',
    'public_stats_mv reports active potholes'
);

SELECT is(
    (SELECT municipalities_covered::TEXT FROM public_stats_mv),
    '1',
    'public_stats_mv reports covered municipalities'
);

SELECT has_function(
    'public',
    'db_healthcheck',
    ARRAY[]::TEXT[],
    'db_healthcheck function exists'
);

SELECT has_function(
    'public',
    'get_potholes_in_bbox',
    ARRAY['double precision', 'double precision', 'double precision', 'double precision'],
    'get_potholes_in_bbox function exists'
);

SELECT ok(
    has_function_privilege('service_role', 'public.db_healthcheck()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.db_healthcheck()', 'EXECUTE'),
    'db_healthcheck is service-role only'
);

SELECT ok(
    has_function_privilege(
        'service_role',
        'public.get_potholes_in_bbox(double precision,double precision,double precision,double precision)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'anon',
        'public.get_potholes_in_bbox(double precision,double precision,double precision,double precision)',
        'EXECUTE'
    ),
    'get_potholes_in_bbox is service-role only'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM cron.job
        WHERE jobname = 'refresh-public-stats-mv'
          AND command = 'REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv'
    ),
    'cron registration exists for concurrent stats refresh'
);

SELECT * FROM finish();
