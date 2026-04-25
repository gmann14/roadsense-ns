CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(22);

DELETE FROM pothole_actions
WHERE action_id IN (
    '00000000-0000-0000-0000-000000001501'::UUID,
    '00000000-0000-0000-0000-000000001502'::UUID,
    '00000000-0000-0000-0000-000000001503'::UUID,
    '00000000-0000-0000-0000-000000001504'::UUID,
    '00000000-0000-0000-0000-000000001505'::UUID,
    '00000000-0000-0000-0000-000000001506'::UUID,
    '00000000-0000-0000-0000-000000001507'::UUID,
    '00000000-0000-0000-0000-000000001508'::UUID,
    '00000000-0000-0000-0000-000000001509'::UUID,
    '00000000-0000-0000-0000-000000001510'::UUID
);

DELETE FROM pothole_reports
WHERE id IN (
    '00000000-0000-0000-0000-000000001401'::UUID,
    '00000000-0000-0000-0000-000000001402'::UUID
)
   OR segment_id = '00000000-0000-0000-0000-000000001301'::UUID
   OR ST_DWithin(
       geom::geography,
       ST_SetSRID(ST_MakePoint(-63.5752, 44.6488), 4326)::geography,
       50
   );

DELETE FROM road_segments
WHERE id = '00000000-0000-0000-0000-000000001301'::UUID;

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
    '00000000-0000-0000-0000-000000001301',
    961301,
    0,
    ST_GeomFromText('LINESTRING(-63.5756 44.6488,-63.5740 44.6488)', 4326),
    120.0,
    'Pothole Action Road',
    'primary',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.0
);

SELECT lives_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001501'::UUID,
        decode('aa', 'hex'),
        'manual_report',
        44.6488,
        -63.5752,
        6.2,
        '2026-04-21T18:22:00Z'::TIMESTAMPTZ,
        NULL
    )
    $sql$,
    'manual pothole report creates a canonical pothole'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000001301'),
    '1',
    'manual report creates exactly one pothole report'
);

SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-000000001501'::UUID,
            decode('aa', 'hex'),
            'manual_report',
            44.6488,
            -63.5752,
            6.2,
            '2026-04-21T18:22:00Z'::TIMESTAMPTZ,
            NULL
        )->>'pothole_report_id'
    ),
    (SELECT id::TEXT FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000001301'),
    'duplicate action_id returns the same canonical pothole'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM pothole_actions WHERE pothole_report_id = (SELECT id FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000001301')),
    '1',
    'duplicate action_id does not insert a second audit row'
);

SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-000000001502'::UUID,
            decode('aa', 'hex'),
            'manual_report',
            44.64881,
            -63.57519,
            5.5,
            '2026-04-21T19:10:00Z'::TIMESTAMPTZ,
            NULL
        )->>'pothole_report_id'
    ),
    (SELECT id::TEXT FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000001301'),
    'same-device repeat within 24h resolves to the same pothole'
);

SELECT is(
    (SELECT confirmation_count::TEXT FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000001301'),
    '1',
    'same-device repeat within 24h does not inflate confirmations'
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
    status,
    negative_confirmation_count
) VALUES (
    '00000000-0000-0000-0000-000000001401',
    '00000000-0000-0000-0000-000000001301',
    ST_GeomFromText('POINT(-63.57485 44.64880)', 4326),
    2.10,
    '2026-04-01T00:00:00Z'::TIMESTAMPTZ,
    '2026-04-20T00:00:00Z'::TIMESTAMPTZ,
    3,
    3,
    'active',
    0
)
ON CONFLICT (id) DO NOTHING;

SELECT lives_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001503'::UUID,
        decode('bb', 'hex'),
        'confirm_fixed',
        44.64880,
        -63.57485,
        5.0,
        '2026-04-21T20:00:00Z'::TIMESTAMPTZ,
        '00000000-0000-0000-0000-000000001401'::UUID
    )
    $sql$,
    'first confirm_fixed succeeds'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    'active',
    'one fixed confirmation does not resolve the pothole'
);

SELECT lives_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001504'::UUID,
        decode('cc', 'hex'),
        'confirm_fixed',
        44.64881,
        -63.57484,
        5.0,
        '2026-04-21T20:05:00Z'::TIMESTAMPTZ,
        '00000000-0000-0000-0000-000000001401'::UUID
    )
    $sql$,
    'second distinct confirm_fixed succeeds'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    'resolved',
    'second distinct fixed vote resolves the pothole'
);

SELECT is(
    (SELECT negative_confirmation_count::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    '2',
    'negative confirmation count reflects both fixed votes'
);

SELECT throws_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001505'::UUID,
        decode('dd', 'hex'),
        'confirm_present',
        44.6520,
        -63.5700,
        6.0,
        '2026-04-21T20:10:00Z'::TIMESTAMPTZ,
        '00000000-0000-0000-0000-000000001401'::UUID
    )
    $sql$,
    'P0001',
    'stale_target',
    'follow-up actions reject stale targets'
);

SELECT lives_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001506'::UUID,
        decode('ee', 'hex'),
        'manual_report',
        44.64880,
        -63.57485,
        4.0,
        '2026-04-21T21:00:00Z'::TIMESTAMPTZ,
        NULL
    )
    $sql$,
    'manual report near resolved pothole reactivates it'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    'active',
    'positive confirmation reactivates the same pothole'
);

SELECT is(
    (
        SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001507'::UUID,
        decode('ee', 'hex'),
        'manual_report',
        44.64880,
        -63.57485,
            4.0,
            '2026-04-21T21:30:00Z'::TIMESTAMPTZ,
            NULL
        )->>'status'
    ),
    'active',
    'same-device duplicate after reactivation returns active status without double counting'
);

SELECT is(
    (SELECT confirmation_count::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    '4',
    'reactivation increments confirmation count exactly once'
);

SELECT throws_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001509'::UUID,
        decode('ab', 'hex'),
        'manual_report',
        44.64880,
        -63.57485,
        4.0,
        '2026-04-21T21:40:00Z'::TIMESTAMPTZ,
        NULL,
        2.70,
        NULL
    )
    $sql$,
    '22023',
    'sensor_backed_fields_required_together',
    'sensor-backed SQL fields must be provided together'
);

SELECT throws_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001510'::UUID,
        decode('ab', 'hex'),
        'confirm_present',
        44.64880,
        -63.57485,
        4.0,
        '2026-04-21T21:40:00Z'::TIMESTAMPTZ,
        '00000000-0000-0000-0000-000000001401'::UUID,
        2.70,
        '2026-04-21T21:39:54Z'::TIMESTAMPTZ
    )
    $sql$,
    '22023',
    'sensor_backed_manual_report_only',
    'sensor-backed SQL fields are manual-report only'
);

SELECT lives_ok(
    $sql$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-000000001508'::UUID,
        decode('ab', 'hex'),
        'manual_report',
        44.64880,
        -63.57485,
        4.0,
        '2026-04-21T21:45:00Z'::TIMESTAMPTZ,
        NULL,
        2.70,
        '2026-04-21T21:44:54Z'::TIMESTAMPTZ
    )
    $sql$,
    'manual report can carry sensor-backed severity'
);

SELECT is(
    (SELECT magnitude::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000001401'),
    '2.70',
    'sensor-backed manual report raises pothole magnitude'
);

SELECT is(
    (
        SELECT sensor_backed_magnitude_g::TEXT
        FROM pothole_actions
        WHERE action_id = '00000000-0000-0000-0000-000000001508'
    ),
    '2.70',
    'sensor-backed magnitude is preserved on the action audit row'
);

SELECT has_function(
    'public',
    'apply_pothole_action',
    ARRAY['uuid', 'bytea', 'pothole_action_type', 'double precision', 'double precision', 'numeric', 'timestamp with time zone', 'uuid'],
    'apply_pothole_action exists with the expected signature'
);

SELECT * FROM finish();
