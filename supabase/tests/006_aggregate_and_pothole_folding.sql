CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(18);

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-000000000601'::UUID,
    '00000000-0000-0000-0000-000000000602'::UUID,
    '00000000-0000-0000-0000-000000000603'::UUID,
    '00000000-0000-0000-0000-000000000604'::UUID
);

DELETE FROM pothole_reports
WHERE id = '00000000-0000-0000-0000-000000000701'::UUID
   OR segment_id IN (
        '00000000-0000-0000-0000-000000000801'::UUID,
        '00000000-0000-0000-0000-000000000802'::UUID
   );

DELETE FROM segment_aggregates
WHERE segment_id IN (
    '00000000-0000-0000-0000-000000000801'::UUID,
    '00000000-0000-0000-0000-000000000802'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id IN (960001, 960002);

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
        '00000000-0000-0000-0000-000000000801',
        960001,
        0,
        ST_GeomFromText('LINESTRING(-63.5700 44.6520,-63.5688 44.6520)', 4326),
        100.0,
        'Aggregate Road',
        'primary',
        'asphalt',
        'Halifax',
        FALSE,
        FALSE,
        FALSE,
        90.00
    ),
    (
        '00000000-0000-0000-0000-000000000802',
        960002,
        0,
        ST_GeomFromText('LINESTRING(-63.5695 44.6530,-63.5665 44.6530)', 4326),
        250.0,
        'Pothole Road',
        'primary',
        'asphalt',
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
        '00000000-0000-0000-0000-000000000901',
        '00000000-0000-0000-0000-000000000801',
        '00000000-0000-0000-0000-000000000601',
        decode('01', 'hex'),
        0.04,
        50.0,
        90.0,
        5.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.5694 44.6520)', 4326),
        '2026-04-18T14:00:00Z'::TIMESTAMPTZ
    ),
    (
        '00000000-0000-0000-0000-000000000902',
        '00000000-0000-0000-0000-000000000801',
        '00000000-0000-0000-0000-000000000601',
        decode('02', 'hex'),
        0.04,
        50.0,
        90.0,
        5.0,
        FALSE,
        NULL,
        ST_GeomFromText('POINT(-63.5693 44.6520)', 4326),
        '2026-04-18T14:01:00Z'::TIMESTAMPTZ
    );

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-000000000601'::UUID)$$,
    'first aggregate fold succeeds'
);

SELECT is(
    (SELECT avg_roughness_score::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    '0.040',
    'initial aggregate average is the batch mean'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'low',
    'two contributors remain in the low confidence tier'
);

SELECT is(
    (SELECT roughness_category::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'smooth',
    'score below 0.05 maps to smooth'
);

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-000000000903', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000602', decode('03', 'hex'), 0.15, 50.0, 90.0, 5.0, TRUE, 2.10, ST_GeomFromText('POINT(-63.5692 44.6520)', 4326), '2026-04-18T14:02:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-000000000904', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000602', decode('04', 'hex'), 0.15, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5691 44.6520)', 4326), '2026-04-18T14:03:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-000000000905', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000602', decode('05', 'hex'), 0.15, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5690 44.6520)', 4326), '2026-04-18T14:04:00Z'::TIMESTAMPTZ);

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-000000000602'::UUID)$$,
    'second aggregate fold succeeds'
);

SELECT is(
    (SELECT avg_roughness_score::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    '0.106',
    'weighted rolling average is applied on incremental fold'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'medium',
    'five contributors move the segment to medium confidence'
);

SELECT is(
    (SELECT roughness_category::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'rough',
    'score between 0.09 and 0.14 maps to rough'
);

SELECT is(
    (SELECT pothole_count::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    '1',
    'pothole_count tracks pothole-flagged readings'
);

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-000000000906', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000603', decode('06', 'hex'), 0.22, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5689 44.6520)', 4326), '2026-04-18T14:05:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-000000000907', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000603', decode('07', 'hex'), 0.22, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5688 44.6520)', 4326), '2026-04-18T14:06:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-000000000908', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000603', decode('08', 'hex'), 0.22, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5687 44.6520)', 4326), '2026-04-18T14:07:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-000000000909', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000603', decode('09', 'hex'), 0.22, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5686 44.6520)', 4326), '2026-04-18T14:08:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-00000000090a', '00000000-0000-0000-0000-000000000801', '00000000-0000-0000-0000-000000000603', decode('0a', 'hex'), 0.22, 50.0, 90.0, 5.0, FALSE, NULL, ST_GeomFromText('POINT(-63.5685 44.6520)', 4326), '2026-04-18T14:09:00Z'::TIMESTAMPTZ);

SELECT lives_ok(
    $$SELECT update_segment_aggregates_from_batch('00000000-0000-0000-0000-000000000603'::UUID)$$,
    'third aggregate fold succeeds'
);

SELECT is(
    (SELECT confidence::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'high',
    'ten contributors move the segment to high confidence'
);

SELECT is(
    (SELECT roughness_category::TEXT FROM segment_aggregates WHERE segment_id = '00000000-0000-0000-0000-000000000801'),
    'very_rough',
    'score at or above 0.14 maps to very_rough'
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
    '00000000-0000-0000-0000-000000000701',
    '00000000-0000-0000-0000-000000000802',
    ST_GeomFromText('POINT(-63.5690 44.6530)', 4326),
    2.50,
    '2026-03-01T00:00:00Z'::TIMESTAMPTZ,
    '2026-04-10T00:00:00Z'::TIMESTAMPTZ,
    1,
    1,
    'active'
);

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-00000000090b', '00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000604', decode('0b', 'hex'), 1.40, 50.0, 90.0, 5.0, TRUE, 2.80, ST_GeomFromText('POINT(-63.5690 44.6530)', 4326), '2026-04-18T15:00:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-00000000090c', '00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000604', decode('0c', 'hex'), 1.50, 50.0, 90.0, 5.0, TRUE, 3.10, ST_GeomFromText('POINT(-63.56895 44.6530)', 4326), '2026-04-18T15:01:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-00000000090d', '00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000604', decode('0d', 'hex'), 1.20, 50.0, 90.0, 5.0, TRUE, 2.20, ST_GeomFromText('POINT(-63.5670 44.6530)', 4326), '2026-04-18T15:02:00Z'::TIMESTAMPTZ),
    ('00000000-0000-0000-0000-00000000090e', '00000000-0000-0000-0000-000000000802', '00000000-0000-0000-0000-000000000604', decode('0e', 'hex'), 1.30, 50.0, 90.0, 5.0, TRUE, 2.40, ST_GeomFromText('POINT(-63.56695 44.6530)', 4326), '2026-04-18T15:03:00Z'::TIMESTAMPTZ);

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-000000000604'::UUID)$$,
    'pothole folding succeeds'
);

SELECT is(
    (SELECT confirmation_count::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000000701'),
    '3',
    'existing pothole is confirmed by nearby batch readings'
);

SELECT is(
    (SELECT unique_reporters::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000000701'),
    '3',
    'existing pothole increments unique reporters by distinct confirming devices'
);

SELECT is(
    (SELECT magnitude::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000000701'),
    '3.10',
    'existing pothole magnitude tracks the strongest confirmation'
);

SELECT is(
    (SELECT COUNT(*)::INTEGER FROM pothole_reports WHERE segment_id = '00000000-0000-0000-0000-000000000802'),
    2,
    'far pothole cluster creates a new pothole report'
);

SELECT is(
    (
        SELECT confirmation_count::TEXT
        FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000000802'
          AND id <> '00000000-0000-0000-0000-000000000701'
    ),
    '2',
    'unmatched potholes in one batch cluster into a single new report'
);

SELECT * FROM finish();
