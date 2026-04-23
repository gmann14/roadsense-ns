CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(18);

DELETE FROM pothole_photos
WHERE report_id IN (
    '00000000-0000-4000-8000-000000002101'::UUID,
    '00000000-0000-4000-8000-000000002102'::UUID,
    '00000000-0000-4000-8000-000000002103'::UUID
);

DELETE FROM pothole_reports
WHERE id IN (
    '00000000-0000-4000-8000-000000002201'::UUID
);

DELETE FROM road_segments
WHERE id = '00000000-0000-4000-8000-000000002301'::UUID;

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
    '00000000-0000-4000-8000-000000002301',
    962301,
    0,
    ST_GeomFromText('LINESTRING(-63.5758 44.6487,-63.5740 44.6487)', 4326),
    140.0,
    'Pothole Photo Road',
    'primary',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.0
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
    negative_confirmation_count,
    has_photo
) VALUES (
    '00000000-0000-4000-8000-000000002201',
    '00000000-0000-4000-8000-000000002301',
    ST_GeomFromText('POINT(-63.57520 44.64870)', 4326),
    2.30,
    '2026-04-01T00:00:00Z'::TIMESTAMPTZ,
    '2026-04-20T00:00:00Z'::TIMESTAMPTZ,
    3,
    3,
    'active',
    0,
    false
);

INSERT INTO pothole_photos (
    report_id,
    device_token_hash,
    segment_id,
    geom,
    accuracy_m,
    captured_at,
    submitted_at,
    uploaded_at,
    status,
    storage_object_path,
    content_sha256,
    content_type,
    byte_size
) VALUES
(
    '00000000-0000-4000-8000-000000002101',
    decode(repeat('ab', 32), 'hex'),
    '00000000-0000-4000-8000-000000002301',
    ST_GeomFromText('POINT(-63.57555 44.64870)', 4326),
    4.8,
    '2026-04-21T18:22:00Z'::TIMESTAMPTZ,
    '2026-04-21T18:23:00Z'::TIMESTAMPTZ,
    '2026-04-21T18:24:00Z'::TIMESTAMPTZ,
    'pending_moderation',
    'pending/00000000-0000-4000-8000-000000002101.jpg',
    decode(repeat('cd', 32), 'hex'),
    'image/jpeg',
    320000
),
(
    '00000000-0000-4000-8000-000000002102',
    decode(repeat('ef', 32), 'hex'),
    '00000000-0000-4000-8000-000000002301',
    ST_GeomFromText('POINT(-63.57518 44.64870)', 4326),
    5.0,
    '2026-04-21T19:22:00Z'::TIMESTAMPTZ,
    '2026-04-21T19:23:00Z'::TIMESTAMPTZ,
    '2026-04-21T19:24:00Z'::TIMESTAMPTZ,
    'pending_moderation',
    'pending/00000000-0000-4000-8000-000000002102.jpg',
    decode(repeat('01', 32), 'hex'),
    'image/jpeg',
    330000
),
(
    '00000000-0000-4000-8000-000000002103',
    decode(repeat('23', 32), 'hex'),
    '00000000-0000-4000-8000-000000002301',
    ST_GeomFromText('POINT(-63.57500 44.64869)', 4326),
    5.4,
    '2026-04-21T20:22:00Z'::TIMESTAMPTZ,
    '2026-04-21T20:23:00Z'::TIMESTAMPTZ,
    '2026-04-21T20:24:00Z'::TIMESTAMPTZ,
    'pending_moderation',
    'pending/00000000-0000-4000-8000-000000002103.jpg',
    decode(repeat('45', 32), 'hex'),
    'image/jpeg',
    340000
);

SELECT has_column(
    'public',
    'pothole_reports',
    'has_photo',
    'pothole_reports.has_photo exists'
);

SELECT has_function(
    'public',
    'approve_pothole_photo',
    ARRAY['uuid', 'text', 'text'],
    'approve_pothole_photo exists with expected signature'
);

SELECT has_function(
    'public',
    'reject_pothole_photo',
    ARRAY['uuid', 'text', 'text'],
    'reject_pothole_photo exists with expected signature'
);

SELECT has_view(
    'public',
    'moderation_pothole_photo_queue',
    'moderation queue view exists'
);

SELECT lives_ok(
    $sql$
    SELECT approve_pothole_photo(
        '00000000-0000-4000-8000-000000002101'::UUID,
        'mod-1',
        'published/00000000-0000-4000-8000-000000002101.jpg'
    )
    $sql$,
    'approve_pothole_photo approves a pending moderation photo'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_photos WHERE report_id = '00000000-0000-4000-8000-000000002101'),
    'approved',
    'approved photo transitions to approved status'
);

SELECT is(
    (SELECT storage_object_path FROM pothole_photos WHERE report_id = '00000000-0000-4000-8000-000000002101'),
    'published/00000000-0000-4000-8000-000000002101.jpg',
    'approved photo stores the published object path'
);

SELECT ok(
    (
        SELECT pr.has_photo
        FROM pothole_reports pr
        JOIN pothole_photos pp
          ON pp.pothole_report_id = pr.id
        WHERE pp.report_id = '00000000-0000-4000-8000-000000002101'
    ),
    'approving a new photo creates a pothole report with has_photo = true'
);

SELECT ok(
    (
        SELECT pothole_report_id IS NOT NULL
        FROM pothole_photos
        WHERE report_id = '00000000-0000-4000-8000-000000002101'
    ),
    'approved photo links back to a canonical pothole report'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM moderation_pothole_photo_queue),
    '2',
    'approved photo no longer appears in the moderation queue'
);

SELECT lives_ok(
    $sql$
    SELECT approve_pothole_photo(
        '00000000-0000-4000-8000-000000002102'::UUID,
        'mod-2',
        'published/00000000-0000-4000-8000-000000002102.jpg'
    )
    $sql$,
    'approving a nearby photo can fold into an existing pothole cluster'
);

SELECT is(
    (SELECT pothole_report_id::TEXT FROM pothole_photos WHERE report_id = '00000000-0000-4000-8000-000000002102'),
    '00000000-0000-4000-8000-000000002201',
    'approved nearby photo links to the existing canonical pothole'
);

SELECT is(
    (SELECT confirmation_count::TEXT FROM pothole_reports WHERE id = '00000000-0000-4000-8000-000000002201'),
    '4',
    'approved nearby photo increments confirmation_count on the existing pothole'
);

SELECT lives_ok(
    $sql$
    SELECT reject_pothole_photo(
        '00000000-0000-4000-8000-000000002103'::UUID,
        'mod-3',
        'contains a license plate'
    )
    $sql$,
    'reject_pothole_photo rejects a pending moderation photo'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_photos WHERE report_id = '00000000-0000-4000-8000-000000002103'),
    'rejected',
    'rejected photo transitions to rejected status'
);

SELECT is(
    (SELECT rejection_reason FROM pothole_photos WHERE report_id = '00000000-0000-4000-8000-000000002103'),
    'contains a license plate',
    'rejected photo stores the moderation reason'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM moderation_pothole_photo_queue),
    '0',
    'queue view excludes approved and rejected photos'
);

SELECT throws_ok(
    $sql$
    SELECT approve_pothole_photo(
        '00000000-0000-4000-8000-000000002103'::UUID,
        'mod-4',
        'published/00000000-0000-4000-8000-000000002103.jpg'
    )
    $sql$,
    'P0001',
    'invalid_photo_state',
    'approve_pothole_photo rejects invalid moderation states'
);

SELECT * FROM finish();
