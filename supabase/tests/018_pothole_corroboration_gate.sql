-- B165 — pothole corroboration gate: candidate status, exact reporter marks,
-- and distinct-device promotion to active
-- (P1-2, docs/reviews/2026-06-11-backend-prelaunch-review.md;
-- docs/implementation/15-device-attestation-and-trust.md).
--
-- Fixture geography: all points sit inside slippy tile z14 x5279 y5925
-- (lon -64.0063..-63.9844, lat 44.4965..44.5122) so get_tile visibility can
-- be asserted directly. Timestamps are now()-relative because readings
-- partitions only exist for the migration-run month onward, and because the
-- confirm_fixed quorum window is anchored to now().

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(38);

DELETE FROM pothole_actions
WHERE action_id IN (
    '00000000-0000-0000-0000-00000000c901'::UUID,
    '00000000-0000-0000-0000-00000000c902'::UUID,
    '00000000-0000-0000-0000-00000000c903'::UUID,
    '00000000-0000-0000-0000-00000000c904'::UUID,
    '00000000-0000-0000-0000-00000000c905'::UUID,
    '00000000-0000-0000-0000-00000000c906'::UUID,
    '00000000-0000-0000-0000-00000000c907'::UUID
);

-- Delete potholes before road_segments (segment FK is ON DELETE SET NULL);
-- the radius clause also catches manual potholes created with NULL segment.
-- pothole_reporter_marks rows cascade with their pothole.
DELETE FROM pothole_reports
WHERE segment_id = '00000000-0000-0000-0000-000000002201'::UUID
   OR ST_DWithin(
       geom::geography,
       ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography,
       300
   );

DELETE FROM readings
WHERE batch_id IN (
    '00000000-0000-0000-0000-00000000b701'::UUID,
    '00000000-0000-0000-0000-00000000b702'::UUID,
    '00000000-0000-0000-0000-00000000b703'::UUID,
    '00000000-0000-0000-0000-00000000b704'::UUID,
    '00000000-0000-0000-0000-00000000b705'::UUID
);

DELETE FROM road_segments
WHERE osm_way_id = 990002;

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
    '00000000-0000-0000-0000-000000002201',
    990002,
    0,
    ST_GeomFromText('LINESTRING(-64.0010 44.5000,-63.9990 44.5000)', 4326),
    160.0,
    'Corroboration Gate Road',
    'primary',
    'asphalt',
    'Halifax',
    FALSE,
    FALSE,
    FALSE,
    90.00
);

-- Schema sanity.
SELECT has_table('pothole_reporter_marks', 'pothole_reporter_marks table exists');
SELECT col_is_pk(
    'pothole_reporter_marks',
    ARRAY['pothole_id', 'device_token_hash'],
    'reporter marks are unique per (pothole, device)'
);
SELECT ok(
    NOT has_table_privilege('anon', 'pothole_reporter_marks', 'SELECT'),
    'anon cannot read reporter marks (token hashes stay private)'
);

-- 1. A single device's sensor batch creates a non-public candidate.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000bb901', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b701', decode('e1', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 3.00, ST_GeomFromText('POINT(-64.00000 44.50000)', 4326), now() - INTERVAL '3 hours');

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-00000000b701'::UUID)$$,
    'single-device sensor fold succeeds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    'candidate',
    'a single device sensor batch creates a candidate, not an active pothole'
);

-- 2. Candidates are invisible on every public read surface.
SELECT is(
    (SELECT COUNT(*)::INT FROM get_potholes_in_bbox(-64.0010, 44.4990, -63.9990, 44.5010)),
    0,
    'candidate pothole is invisible to get_potholes_in_bbox'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM get_top_potholes(100) tp
        WHERE tp.id = (
            SELECT id FROM pothole_reports
            WHERE segment_id = '00000000-0000-0000-0000-000000002201'
              AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
        )
    ),
    'candidate pothole is invisible to get_top_potholes'
);

SELECT is(
    octet_length(get_tile(14, 5279, 5925)),
    0,
    'candidate pothole emits no bytes on the z14 tile'
);

-- 3. Repeat batches from the same device never promote.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000bb902', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b702', decode('e1', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 3.20, ST_GeomFromText('POINT(-64.00002 44.50001)', 4326), now() - INTERVAL '2 hours');

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-00000000b702'::UUID)$$,
    'same-device second sensor batch folds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    'candidate',
    'a second batch from the same device never promotes'
);

SELECT is(
    (
        SELECT unique_reporters::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    '1',
    'unique_reporters is exact under repeated same-device batches'
);

SELECT is(
    (
        SELECT confirmation_count::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    '2',
    'confirmation_count still tracks every sensor hit'
);

-- 4. A second distinct device within 15 m / 90 days promotes to active.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000bb903', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b703', decode('e2', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 2.80, ST_GeomFromText('POINT(-64.00001 44.49999)', 4326), now() - INTERVAL '1 hour');

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-00000000b703'::UUID)$$,
    'distinct-device corroborating batch folds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    'active',
    'a second distinct device promotes the candidate to active'
);

SELECT is(
    (
        SELECT unique_reporters::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    '2',
    'unique_reporters counts exactly two distinct devices'
);

SELECT is(
    (
        SELECT COUNT(*)::TEXT FROM pothole_reporter_marks
        WHERE pothole_id = (
            SELECT id FROM pothole_reports
            WHERE segment_id = '00000000-0000-0000-0000-000000002201'
              AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
        )
    ),
    '2',
    'reporter marks hold one row per distinct device across all batches'
);

-- 5. Promotion makes it visible on every public read surface.
SELECT is(
    (SELECT COUNT(*)::INT FROM get_potholes_in_bbox(-64.0010, 44.4990, -63.9990, 44.5010)),
    1,
    'promoted pothole appears in get_potholes_in_bbox'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM get_top_potholes(100) tp
        WHERE tp.id = (
            SELECT id FROM pothole_reports
            WHERE segment_id = '00000000-0000-0000-0000-000000002201'
              AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
        )
    ),
    'promoted pothole appears in get_top_potholes'
);

SELECT cmp_ok(
    octet_length(get_tile(14, 5279, 5925)),
    '>',
    0,
    'promoted pothole renders on the z14 tile'
);

-- 6. Two distinct devices in one batch publish immediately.
INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000bb904', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b704', decode('f1', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 2.50, ST_GeomFromText('POINT(-63.99950 44.50000)', 4326), now() - INTERVAL '40 minutes'),
    ('00000000-0000-0000-0000-0000000bb905', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b704', decode('f2', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 2.60, ST_GeomFromText('POINT(-63.99952 44.50000)', 4326), now() - INTERVAL '39 minutes');

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-00000000b704'::UUID)$$,
    'two-device single batch folds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-63.99951, 44.5000), 4326)::geography, 15)
    ),
    'active',
    'a cluster carrying two distinct devices inserts as active directly'
);

SELECT is(
    (
        SELECT unique_reporters::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-63.99951, 44.5000), 4326)::geography, 15)
    ),
    '2',
    'two-device cluster records both reporters'
);

-- 7. Manual reports create candidates, not active potholes.
SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-00000000c901'::UUID,
            decode('a1', 'hex'),
            'manual_report',
            44.50040,
            -64.00000,
            5.0,
            now() - INTERVAL '26 hours',
            NULL
        )->>'status'
    ),
    'candidate',
    'a manual report from one device creates a candidate'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5004), 4326)::geography, 10)
    ),
    'candidate',
    'the manual pothole row holds candidate status'
);

-- 8. The same device cannot self-corroborate the manual path.
SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-00000000c902'::UUID,
            decode('a1', 'hex'),
            'manual_report',
            44.50040,
            -64.00000,
            5.0,
            now() - INTERVAL '30 minutes',
            NULL
        )->>'status'
    ),
    'candidate',
    'a repeat manual report from the same device never promotes'
);

SELECT is(
    (
        SELECT unique_reporters::TEXT FROM pothole_reports
        WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5004), 4326)::geography, 10)
    ),
    '1',
    'same-device manual repeat does not inflate unique_reporters'
);

-- 9. A different device's manual report corroborates and promotes.
SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-00000000c903'::UUID,
            decode('a2', 'hex'),
            'manual_report',
            44.50041,
            -64.00001,
            5.0,
            now() - INTERVAL '25 minutes',
            NULL
        )->>'status'
    ),
    'active',
    'a manual report from a second device promotes the candidate'
);

SELECT is(
    (
        SELECT unique_reporters::TEXT FROM pothole_reports
        WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5004), 4326)::geography, 10)
    ),
    '2',
    'manual corroboration counts both distinct devices'
);

-- 10. confirm_present from a second device promotes a candidate.
SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-00000000c904'::UUID,
            decode('b1', 'hex'),
            'manual_report',
            44.49960,
            -64.00000,
            5.0,
            now() - INTERVAL '20 minutes',
            NULL
        )->>'status'
    ),
    'candidate',
    'second manual fixture starts as a candidate'
);

SELECT is(
    (
        SELECT apply_pothole_action(
            '00000000-0000-0000-0000-00000000c905'::UUID,
            decode('b2', 'hex'),
            'confirm_present',
            44.49960,
            -64.00000,
            5.0,
            now() - INTERVAL '10 minutes',
            (
                SELECT id FROM pothole_reports
                WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.4996), 4326)::geography, 10)
            )
        )->>'status'
    ),
    'active',
    'confirm_present from a second device promotes the candidate'
);

-- 11. The existing confirm_fixed two-device quorum still resolves.
SELECT lives_ok(
    $$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-00000000c906'::UUID,
        decode('c1', 'hex'),
        'confirm_fixed',
        44.49960,
        -64.00000,
        5.0,
        now() - INTERVAL '5 minutes',
        (
            SELECT id FROM pothole_reports
            WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.4996), 4326)::geography, 10)
        )
    )
    $$,
    'first confirm_fixed succeeds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.4996), 4326)::geography, 10)
    ),
    'active',
    'one fixed vote does not resolve the pothole'
);

SELECT lives_ok(
    $$
    SELECT apply_pothole_action(
        '00000000-0000-0000-0000-00000000c907'::UUID,
        decode('c2', 'hex'),
        'confirm_fixed',
        44.49960,
        -64.00000,
        5.0,
        now() - INTERVAL '4 minutes',
        (
            SELECT id FROM pothole_reports
            WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.4996), 4326)::geography, 10)
        )
    )
    $$,
    'second distinct confirm_fixed succeeds'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.4996), 4326)::geography, 10)
    ),
    'resolved',
    'two distinct fixed votes still resolve the pothole'
);

-- 12. Grandfathering: a pre-migration single-reporter active pothole stays
--     active through sensor folding and the expiry sweep; a stale candidate
--     expires on the normal 90-day cycle.
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
) VALUES
    (
        '00000000-0000-0000-0000-000000002301',
        '00000000-0000-0000-0000-000000002201',
        ST_GeomFromText('POINT(-63.99900 44.50000)', 4326),
        2.00,
        now() - INTERVAL '30 days',
        now() - INTERVAL '1 day',
        1,
        1,
        'active',
        0
    ),
    (
        '00000000-0000-0000-0000-000000002302',
        '00000000-0000-0000-0000-000000002201',
        ST_GeomFromText('POINT(-63.99850 44.50000)', 4326),
        2.00,
        now() - INTERVAL '95 days',
        now() - INTERVAL '91 days',
        1,
        1,
        'candidate',
        0
    );

INSERT INTO readings (
    id, segment_id, batch_id, device_token_hash, roughness_rms, speed_kmh,
    heading_degrees, gps_accuracy_m, is_pothole, pothole_magnitude, location, recorded_at
) VALUES
    ('00000000-0000-0000-0000-0000000bb906', '00000000-0000-0000-0000-000000002201', '00000000-0000-0000-0000-00000000b705', decode('e9', 'hex'), 1.00, 60.0, 90.0, 5.0, TRUE, 2.50, ST_GeomFromText('POINT(-63.99901 44.50000)', 4326), now() - INTERVAL '10 minutes');

SELECT lives_ok(
    $$SELECT fold_pothole_candidates('00000000-0000-0000-0000-00000000b705'::UUID)$$,
    'sensor batch near a grandfathered pothole folds'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000002301'),
    'active',
    'grandfathered single-reporter active pothole is never demoted'
);

SELECT is(
    (SELECT unique_reporters::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000002301'),
    '2',
    'mark-based reporter accounting still accrues on grandfathered potholes'
);

SELECT lives_ok(
    $$SELECT expire_unconfirmed_potholes()$$,
    'expiry sweep runs'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000002301'),
    'active',
    'recently confirmed grandfathered pothole survives the expiry sweep'
);

SELECT is(
    (SELECT status::TEXT FROM pothole_reports WHERE id = '00000000-0000-0000-0000-000000002302'),
    'expired',
    'stale candidates expire on the normal 90-day cycle'
);

SELECT is(
    (
        SELECT status::TEXT FROM pothole_reports
        WHERE segment_id = '00000000-0000-0000-0000-000000002201'
          AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-64.0000, 44.5000), 4326)::geography, 15)
    ),
    'active',
    'recently corroborated pothole survives the expiry sweep'
);

SELECT * FROM finish();
