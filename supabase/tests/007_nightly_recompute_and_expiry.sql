CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(19);

DO $$
DECLARE
    v_offset INTEGER;
    v_start DATE;
    v_end DATE;
    v_part_name TEXT;
BEGIN
    FOR v_offset IN -2..0 LOOP
        v_start := (date_trunc('month', now()) + make_interval(months => v_offset))::DATE;
        v_end := (v_start + INTERVAL '1 month')::DATE;
        v_part_name := format('readings_%s', to_char(v_start, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF readings FOR VALUES FROM (%L) TO (%L)',
            v_part_name,
            v_start,
            v_end
        );
    END LOOP;
END;
$$;

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-000000001101'::UUID,
    '00000000-0000-0000-0000-000000001102'::UUID
);

DELETE FROM segment_aggregates
WHERE segment_id IN (
    '00000000-0000-0000-0000-000000001201'::UUID,
    '00000000-0000-0000-0000-000000001202'::UUID
);

DELETE FROM pothole_reports
WHERE id IN (
    '00000000-0000-0000-0000-000000001301'::UUID,
    '00000000-0000-0000-0000-000000001302'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (970001, 970002);

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
        '00000000-0000-0000-0000-000000001201',
        970001,
        0,
        ST_GeomFromText('LINESTRING(-63.5600 44.6550,-63.5588 44.6550)', 4326),
        100.0,
        'Nightly Trend Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000001202',
        970002,
        0,
        ST_GeomFromText('LINESTRING(-63.5500 44.6560,-63.5488 44.6560)', 4326),
        100.0,
        'Targeted Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    );

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location,
    recorded_at, uploaded_at
)
SELECT
    ('00000000-0000-0000-0000-' || lpad(gs::TEXT, 12, '0'))::UUID,
    '00000000-0000-0000-0000-000000001201'::UUID,
    '00000000-0000-0000-0000-000000001101'::UUID,
    decode(lpad(to_hex(gs), 2, '0'), 'hex'),
    CASE
        WHEN gs = 1 THEN 0.01
        WHEN gs BETWEEN 2 AND 5 THEN 0.20
        WHEN gs BETWEEN 6 AND 9 THEN 0.30
        WHEN gs BETWEEN 10 AND 14 THEN 1.20
        ELSE 2.50
    END,
    50.0,
    90.0,
    5.0,
    (gs = 14),
    CASE
        WHEN gs = 14 THEN 2.50
        WHEN gs = 15 THEN 3.50
        ELSE NULL
    END,
    ST_GeomFromText('POINT(-63.5594 44.6550)', 4326),
    CASE
        WHEN gs BETWEEN 1 AND 5 THEN now() - INTERVAL '40 days'
        WHEN gs BETWEEN 6 AND 9 THEN now() - INTERVAL '10 days'
        ELSE now() - INTERVAL '5 days'
    END,
    now() - INTERVAL '1 hour'
FROM generate_series(1, 15) AS gs;

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location,
    recorded_at, uploaded_at
)
VALUES
    ('00000000-0000-0000-0000-000000001401', '00000000-0000-0000-0000-000000001202', '00000000-0000-0000-0000-000000001102', decode('aa', 'hex'), 0.40, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5494 44.6560)', 4326), now() - INTERVAL '2 days', now() - INTERVAL '1 hour'),
    ('00000000-0000-0000-0000-000000001402', '00000000-0000-0000-0000-000000001202', '00000000-0000-0000-0000-000000001102', decode('aa', 'hex'), 0.50, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.54935 44.6560)', 4326), now() - INTERVAL '1 day', now() - INTERVAL '1 hour'),
    ('00000000-0000-0000-0000-000000001403', '00000000-0000-0000-0000-000000001202', '00000000-0000-0000-0000-000000001102', decode('aa', 'hex'), 0.60, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.54930 44.6560)', 4326), now() - INTERVAL '12 hours', now() - INTERVAL '1 hour'),
    ('00000000-0000-0000-0000-000000001404', '00000000-0000-0000-0000-000000001202', '00000000-0000-0000-0000-000000001102', decode('bb', 'hex'), 1.20, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.54925 44.6560)', 4326), now() - INTERVAL '6 hours', now() - INTERVAL '1 hour');

SELECT lives_ok(
    $$SELECT nightly_recompute_aggregates(ARRAY['00000000-0000-0000-0000-000000001201'::UUID, '00000000-0000-0000-0000-000000001202'::UUID])$$,
    'nightly recompute succeeds on an explicit touched-segment subset'
);

SELECT is(
    (SELECT total_readings::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001201'),
    '13',
    'nightly recompute trims the extreme low and high outliers when n >= 10'
);

SELECT is(
    (SELECT unique_contributors::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001202'),
    '2',
    'nightly recompute caps each device to three readings per segment per week'
);

SELECT is(
    (SELECT pothole_count::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001201'),
    '1',
    'nightly recompute carries pothole_count through the trimmed dataset'
);

SELECT is(
    (SELECT trend::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001201'),
    'worsening',
    'trend becomes worsening when recent readings exceed the prior 30-day window by >10%'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001201'),
    'high',
    'ten or more contributors yield high confidence after recompute'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001202'),
    'low',
    'two contributors remain in the low confidence tier after recompute'
);

SELECT cmp_ok(
    (SELECT avg_roughness_score FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000001201'),
    '>',
    0.60::NUMERIC,
    'recency weighting biases the recomputed score toward the newer rougher readings'
);

INSERT INTO pothole_reports (
    id, segment_id, geom, magnitude, first_reported_at, last_confirmed_at,
    confirmation_count, unique_reporters, status
) VALUES
    (
        '00000000-0000-0000-0000-000000001301',
        '00000000-0000-0000-0000-000000001201',
        ST_GeomFromText('POINT(-63.5594 44.6550)', 4326),
        2.80,
        now() - INTERVAL '120 days',
        now() - INTERVAL '91 days',
        2,
        2,
        'active'
    ),
    (
        '00000000-0000-0000-0000-000000001302',
        '00000000-0000-0000-0000-000000001202',
        ST_GeomFromText('POINT(-63.5494 44.6560)', 4326),
        2.20,
        now() - INTERVAL '30 days',
        now() - INTERVAL '10 days',
        1,
        1,
        'active'
    );

SELECT lives_ok(
    $$SELECT expire_unconfirmed_potholes()$$,
    'expire_unconfirmed_potholes succeeds'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001301'),
    'expired',
    'potholes older than 90 days are expired'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001302'),
    'active',
    'recently confirmed potholes remain active'
);

SELECT lives_ok(
    $$SELECT expire_unconfirmed_potholes()$$,
    'pothole expiry is idempotent'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001301'),
    'expired',
    'expired pothole stays expired on rerun'
);

SELECT has_function(
    'public',
    'nightly_recompute_aggregates',
    ARRAY['uuid[]'],
    'nightly_recompute_aggregates function exists'
);

SELECT has_function(
    'public',
    'expire_unconfirmed_potholes',
    ARRAY[]::TEXT[],
    'expire_unconfirmed_potholes function exists'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'create-next-readings-partition'
    ),
    'cron registration exists for create-next-readings-partition'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'nightly-aggregate-recompute'
    ),
    'cron registration exists for nightly-aggregate-recompute'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'pothole-expiry'
    ),
    'cron registration exists for pothole-expiry'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'rate-limit-gc'
    ),
    'cron registration exists for rate-limit-gc'
);

SELECT * FROM finish();
