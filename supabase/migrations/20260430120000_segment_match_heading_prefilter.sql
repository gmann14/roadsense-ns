-- Segment-match heading prefilter + legacy heading=0 recovery.
--
-- Problem (Issue 1, 2026-04-30 triage):
-- 88% of readings in the calibration drive were rejected as `no_segment_match`.
-- Two compounding causes:
--   1. iOS LocationService coerced CLLocation.course = -1 (course unknown) to
--      0 (due north) before uploading. The SQL `COALESCE(t.heading, ...)`
--      safety valve never fired because the client never sent NULL. East-west
--      roads systematically rejected as heading_diff ~ 90.
--   2. The lateral subquery picked the 3 nearest segments by planar distance
--      THEN applied the heading filter. At intersections, divided highways,
--      and near service roads, the correct segment is often rank 4+ — the
--      3-slot cap discarded it before heading evaluation.
--
-- Fix:
--   - Push heading constraint into the inner ST_DWithin query so heading-
--     incompatible segments never compete for the candidate slots.
--   - Bump LIMIT 3 → LIMIT 5 for additional headroom in dense road networks.
--   - Add a "single dominant candidate" recovery pass to replay_unmatched_
--     readings. For rows that still don't match strictly but have exactly one
--     candidate segment within 20m (or where the nearest is at least 2x closer
--     than the next-nearest), promote them anyway. This recovers the legacy
--     heading=0 backlog written before the iOS fix.
--
-- iOS-side: ios/RoadSenseNS/Sensors/LocationService.swift now passes
-- location.course through unmodified; the upload payload encodes negative
-- values as JSON null.

CREATE OR REPLACE FUNCTION ingest_reading_batch(
    p_batch_id UUID,
    p_device_token_hash BYTEA,
    p_readings JSONB,
    p_client_sent_at TIMESTAMPTZ,
    p_client_app_version TEXT,
    p_client_os_version TEXT
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_accepted INTEGER := 0;
    v_rejected INTEGER := 0;
    v_held_for_retry INTEGER := 0;
    v_rejected_reasons JSON := '{}'::JSON;
BEGIN
    IF jsonb_typeof(p_readings) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'p_readings must be a JSON array';
    END IF;

    IF jsonb_array_length(p_readings) > 1000 THEN
        RAISE EXCEPTION 'p_readings exceeds 1000 readings';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_batch_id::TEXT, 0));

    IF EXISTS (SELECT 1 FROM processed_batches WHERE batch_id = p_batch_id) THEN
        SELECT accepted_count, rejected_count, rejected_reasons::JSON
        INTO v_accepted, v_rejected, v_rejected_reasons
        FROM processed_batches
        WHERE batch_id = p_batch_id;

        RETURN json_build_object(
            'accepted', v_accepted,
            'rejected', v_rejected,
            'duplicate', TRUE,
            'rejected_reasons', v_rejected_reasons
        );
    END IF;

    DROP TABLE IF EXISTS tmp_batch_readings;
    DROP TABLE IF EXISTS tmp_matched;
    DROP TABLE IF EXISTS tmp_final;

    CREATE TEMP TABLE tmp_batch_readings ON COMMIT DROP AS
    SELECT
        p.reading_idx,
        p.lat,
        p.lng,
        p.roughness_rms,
        p.speed_kmh,
        p.heading,
        p.gps_accuracy_m,
        p.is_pothole,
        p.pothole_magnitude,
        p.recorded_at,
        ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326) AS geom,
        CASE
            WHEN p.lng NOT BETWEEN -66.5 AND -59.5
              OR p.lat NOT BETWEEN 43.3 AND 47.1 THEN 'out_of_bounds'
            WHEN p.recorded_at > now() + INTERVAL '60 seconds' THEN 'future_timestamp'
            WHEN p.recorded_at < now() - INTERVAL '7 days' THEN 'stale_timestamp'
            WHEN p.gps_accuracy_m > 20
              OR p.speed_kmh < 15
              OR p.speed_kmh > 160
              OR p.roughness_rms < 0
              OR p.roughness_rms > 15 THEN 'low_quality'
            ELSE NULL
        END::TEXT AS rejection_reason
    FROM (
        SELECT
            ordinality AS reading_idx,
            (r->>'lat')::NUMERIC AS lat,
            (r->>'lng')::NUMERIC AS lng,
            (r->>'roughness_rms')::NUMERIC AS roughness_rms,
            (r->>'speed_kmh')::NUMERIC AS speed_kmh,
            (r->>'heading')::NUMERIC AS heading,
            (r->>'gps_accuracy_m')::NUMERIC AS gps_accuracy_m,
            COALESCE((r->>'is_pothole')::BOOLEAN, FALSE) AS is_pothole,
            (r->>'pothole_magnitude')::NUMERIC AS pothole_magnitude,
            (r->>'recorded_at')::TIMESTAMPTZ AS recorded_at
        FROM jsonb_array_elements(p_readings) WITH ORDINALITY AS r(r, ordinality)
    ) p;

    -- Heading-aware candidate selection. The heading constraint runs INSIDE
    -- the ST_DWithin query so heading-incompatible segments don't consume the
    -- candidate slots. Slot count bumped 3 → 5 for dense road networks.
    CREATE TEMP TABLE tmp_matched ON COMMIT DROP AS
    SELECT
        t.reading_idx,
        m.segment_id,
        m.distance_m,
        m.heading_diff,
        m.surface_type
    FROM tmp_batch_readings t
    LEFT JOIN LATERAL (
        SELECT *
        FROM (
            SELECT
                rs.id AS segment_id,
                rs.surface_type,
                ST_Distance(rs.geom::geography, t.geom::geography) AS distance_m,
                CASE
                    WHEN t.heading IS NULL THEN 0
                    ELSE ABS(((t.heading - rs.bearing_degrees + 540)::INT % 360) - 180)
                END AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
              AND (
                t.heading IS NULL
                OR ABS(((t.heading - rs.bearing_degrees + 540)::INT % 360) - 180) <= 45
                OR ABS(((t.heading - rs.bearing_degrees + 540)::INT % 360) - 180) >= 135
              )
            ORDER BY rs.geom::geography <-> t.geom::geography
            LIMIT 5
        ) candidates
        WHERE candidates.distance_m <= 20
        ORDER BY candidates.distance_m
        LIMIT 1
    ) m ON t.rejection_reason IS NULL
    ORDER BY t.recorded_at;

    CREATE TEMP TABLE tmp_final ON COMMIT DROP AS
    SELECT
        t.*,
        m.segment_id,
        m.distance_m,
        m.heading_diff,
        CASE
            WHEN t.rejection_reason IS NOT NULL THEN t.rejection_reason
            WHEN EXISTS (
                SELECT 1
                FROM readings existing
                WHERE existing.device_token_hash = p_device_token_hash
                  AND existing.recorded_at = t.recorded_at
                  AND ST_DWithin(existing.location::geography, t.geom::geography, 0.5)
            ) THEN 'duplicate_reading'
            WHEN m.segment_id IS NULL THEN 'no_segment_match'
            WHEN m.surface_type IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand') THEN 'unpaved'
            ELSE NULL
        END::TEXT AS final_rejection_reason
    FROM tmp_batch_readings t
    LEFT JOIN tmp_matched m USING (reading_idx)
    ORDER BY t.recorded_at;

    INSERT INTO readings (
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
    )
    SELECT
        segment_id,
        p_batch_id,
        p_device_token_hash,
        roughness_rms,
        speed_kmh,
        heading,
        gps_accuracy_m,
        is_pothole,
        pothole_magnitude,
        geom,
        recorded_at
    FROM tmp_final
    WHERE final_rejection_reason IS NULL;

    GET DIAGNOSTICS v_accepted = ROW_COUNT;

    INSERT INTO unmatched_readings (
        batch_id,
        device_token_hash,
        location,
        roughness_rms,
        speed_kmh,
        heading_degrees,
        gps_accuracy_m,
        is_pothole,
        pothole_magnitude,
        recorded_at,
        last_match_attempt_at
    )
    SELECT
        p_batch_id,
        p_device_token_hash,
        geom,
        roughness_rms,
        speed_kmh,
        COALESCE(heading, -1),
        gps_accuracy_m,
        is_pothole,
        pothole_magnitude,
        recorded_at,
        now()
    FROM tmp_final
    WHERE final_rejection_reason = 'no_segment_match';

    GET DIAGNOSTICS v_held_for_retry = ROW_COUNT;

    v_rejected := (
        SELECT COUNT(*)
        FROM tmp_final
        WHERE final_rejection_reason IS NOT NULL
    );

    SELECT COALESCE(
        jsonb_object_agg(reason, reason_count ORDER BY reason),
        '{}'::JSONB
    )::JSON
    INTO v_rejected_reasons
    FROM (
        SELECT final_rejection_reason AS reason, COUNT(*) AS reason_count
        FROM tmp_final
        WHERE final_rejection_reason IS NOT NULL
        GROUP BY final_rejection_reason
    ) reasons;

    INSERT INTO processed_batches (
        batch_id,
        device_token_hash,
        reading_count,
        accepted_count,
        rejected_count,
        rejected_reasons,
        client_sent_at,
        client_app_version,
        client_os_version
    ) VALUES (
        p_batch_id,
        p_device_token_hash,
        (SELECT COUNT(*) FROM tmp_final),
        v_accepted,
        v_rejected,
        v_rejected_reasons::JSONB,
        p_client_sent_at,
        p_client_app_version,
        p_client_os_version
    );

    PERFORM update_segment_aggregates_from_batch(p_batch_id);
    PERFORM fold_pothole_candidates(p_batch_id);

    RETURN json_build_object(
        'accepted', v_accepted,
        'rejected', v_rejected,
        'held_for_retry', v_held_for_retry,
        'duplicate', FALSE,
        'rejected_reasons', v_rejected_reasons
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM anon;
REVOKE EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION ingest_reading_batch(UUID, BYTEA, JSONB, TIMESTAMPTZ, TEXT, TEXT) TO service_role;


CREATE OR REPLACE FUNCTION replay_unmatched_readings(
    p_max_rows INTEGER DEFAULT 50000,
    p_min_age_seconds INTEGER DEFAULT 0
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_promoted_strict INTEGER := 0;
    v_promoted_fallback INTEGER := 0;
    v_still_unmatched INTEGER := 0;
    v_purged INTEGER := 0;
    v_affected_batches UUID[];
BEGIN
    IF p_max_rows IS NULL OR p_max_rows <= 0 THEN
        p_max_rows := 50000;
    END IF;

    DROP TABLE IF EXISTS tmp_replay_candidates;
    DROP TABLE IF EXISTS tmp_replay_matched;
    DROP TABLE IF EXISTS tmp_replay_promoted_ids;
    DROP TABLE IF EXISTS tmp_replay_fallback;

    -- Snapshot the working set so concurrent inserts don't make us loop
    -- forever. Most-recent-first so we re-bring up the freshest data first.
    CREATE TEMP TABLE tmp_replay_candidates ON COMMIT DROP AS
    SELECT
        u.id,
        u.batch_id,
        u.device_token_hash,
        u.location,
        u.roughness_rms,
        u.speed_kmh,
        -- Treat -1 as the "course unknown" sentinel; some legacy rows may
        -- have heading_degrees=0 from before the iOS NULL fix.
        CASE WHEN u.heading_degrees < 0 THEN NULL ELSE u.heading_degrees END AS heading_degrees,
        u.gps_accuracy_m,
        u.is_pothole,
        u.pothole_magnitude,
        u.recorded_at,
        ST_SetSRID(u.location, 4326) AS geom
    FROM unmatched_readings u
    WHERE u.created_at <= now() - make_interval(secs => p_min_age_seconds)
    ORDER BY u.created_at DESC
    LIMIT p_max_rows;

    -- Pass 1: strict match with the new heading-aware logic (mirrors
    -- ingest_reading_batch).
    CREATE TEMP TABLE tmp_replay_matched ON COMMIT DROP AS
    SELECT
        c.id AS unmatched_id,
        c.batch_id,
        c.device_token_hash,
        c.geom,
        c.roughness_rms,
        c.speed_kmh,
        c.heading_degrees,
        c.gps_accuracy_m,
        c.is_pothole,
        c.pothole_magnitude,
        c.recorded_at,
        m.segment_id,
        m.distance_m,
        m.heading_diff
    FROM tmp_replay_candidates c
    LEFT JOIN LATERAL (
        SELECT *
        FROM (
            SELECT
                rs.id AS segment_id,
                rs.surface_type,
                ST_Distance(rs.geom::geography, c.geom::geography) AS distance_m,
                CASE
                    WHEN c.heading_degrees IS NULL THEN 0
                    ELSE ABS(((c.heading_degrees - rs.bearing_degrees + 540)::INT % 360) - 180)
                END AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, c.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
              AND rs.surface_type NOT IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand')
              AND (
                c.heading_degrees IS NULL
                OR ABS(((c.heading_degrees - rs.bearing_degrees + 540)::INT % 360) - 180) <= 45
                OR ABS(((c.heading_degrees - rs.bearing_degrees + 540)::INT % 360) - 180) >= 135
              )
            ORDER BY rs.geom::geography <-> c.geom::geography
            LIMIT 5
        ) candidates
        WHERE candidates.distance_m <= 20
        ORDER BY candidates.distance_m
        LIMIT 1
    ) m ON TRUE;

    CREATE TEMP TABLE tmp_replay_promoted_ids ON COMMIT DROP AS
    SELECT rm.unmatched_id, FALSE AS via_fallback
    FROM tmp_replay_matched rm
    WHERE rm.segment_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM readings existing
          WHERE existing.device_token_hash = rm.device_token_hash
            AND existing.recorded_at = rm.recorded_at
            AND ST_DWithin(existing.location::geography, rm.geom::geography, 0.5)
      );

    -- Pass 2 (recovery): for rows that still didn't match, find the nearest
    -- non-parking, non-unpaved road segment within 20m. Accept it only when
    -- it's clearly dominant — either there is no second candidate within 20m,
    -- or the second candidate is at least 2x farther away. This recovers
    -- rows where the legacy iOS bug stamped heading=0 (rejected on E-W roads)
    -- without creating false matches at intersections or divided highways
    -- where the lane is genuinely ambiguous.
    CREATE TEMP TABLE tmp_replay_fallback ON COMMIT DROP AS
    SELECT
        rm.unmatched_id,
        rm.batch_id,
        rm.device_token_hash,
        rm.geom,
        rm.roughness_rms,
        rm.speed_kmh,
        rm.heading_degrees,
        rm.gps_accuracy_m,
        rm.is_pothole,
        rm.pothole_magnitude,
        rm.recorded_at,
        f.segment_id,
        f.distance_m
    FROM tmp_replay_matched rm
    LEFT JOIN LATERAL (
        WITH ranked AS (
            SELECT
                rs.id AS segment_id,
                ST_Distance(rs.geom::geography, rm.geom::geography) AS distance_m,
                ROW_NUMBER() OVER (ORDER BY rs.geom::geography <-> rm.geom::geography) AS rk
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, rm.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
              AND rs.surface_type NOT IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand')
            ORDER BY rs.geom::geography <-> rm.geom::geography
            LIMIT 2
        )
        SELECT
            (SELECT segment_id FROM ranked WHERE rk = 1) AS segment_id,
            (SELECT distance_m FROM ranked WHERE rk = 1) AS distance_m
        WHERE
            (SELECT distance_m FROM ranked WHERE rk = 1) <= 20
            AND (
                (SELECT COUNT(*) FROM ranked) = 1
                OR (SELECT distance_m FROM ranked WHERE rk = 2)
                   >= 2 * (SELECT distance_m FROM ranked WHERE rk = 1)
            )
    ) f ON TRUE
    WHERE rm.segment_id IS NULL
      AND f.segment_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM readings existing
          WHERE existing.device_token_hash = rm.device_token_hash
            AND existing.recorded_at = rm.recorded_at
            AND ST_DWithin(existing.location::geography, rm.geom::geography, 0.5)
      );

    INSERT INTO tmp_replay_promoted_ids (unmatched_id, via_fallback)
    SELECT unmatched_id, TRUE FROM tmp_replay_fallback;

    -- Promote: strict matches first, then fallback rows with their
    -- recovered segment_id.
    INSERT INTO readings (
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
    )
    SELECT
        rm.segment_id,
        rm.batch_id,
        rm.device_token_hash,
        rm.roughness_rms,
        rm.speed_kmh,
        rm.heading_degrees,
        rm.gps_accuracy_m,
        rm.is_pothole,
        rm.pothole_magnitude,
        rm.geom,
        rm.recorded_at
    FROM tmp_replay_matched rm
    INNER JOIN tmp_replay_promoted_ids p
            ON p.unmatched_id = rm.unmatched_id
           AND p.via_fallback = FALSE;

    GET DIAGNOSTICS v_promoted_strict = ROW_COUNT;

    INSERT INTO readings (
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
    )
    SELECT
        f.segment_id,
        f.batch_id,
        f.device_token_hash,
        f.roughness_rms,
        f.speed_kmh,
        f.heading_degrees,
        f.gps_accuracy_m,
        f.is_pothole,
        f.pothole_magnitude,
        f.geom,
        f.recorded_at
    FROM tmp_replay_fallback f;

    GET DIAGNOSTICS v_promoted_fallback = ROW_COUNT;

    SELECT COALESCE(array_agg(DISTINCT batch_id), ARRAY[]::UUID[])
    INTO v_affected_batches
    FROM (
        SELECT rm.batch_id
        FROM tmp_replay_matched rm
        INNER JOIN tmp_replay_promoted_ids p
                ON p.unmatched_id = rm.unmatched_id
               AND p.via_fallback = FALSE
        UNION ALL
        SELECT batch_id FROM tmp_replay_fallback
    ) all_promoted;

    -- Delete promoted rows from the holding table.
    DELETE FROM unmatched_readings u
    USING tmp_replay_promoted_ids p
    WHERE u.id = p.unmatched_id;

    -- Mark still-unmatched rows so we can prefer freshly-arrived rows on the
    -- next pass.
    UPDATE unmatched_readings u
    SET last_match_attempt_at = now()
    FROM tmp_replay_matched rm
    WHERE u.id = rm.unmatched_id
      AND rm.segment_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM tmp_replay_fallback f WHERE f.unmatched_id = rm.unmatched_id
      );

    SELECT COUNT(*) INTO v_still_unmatched
    FROM tmp_replay_matched rm
    WHERE rm.segment_id IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM tmp_replay_fallback f WHERE f.unmatched_id = rm.unmatched_id
      );

    -- Recompute aggregates for batches that gained rows.
    IF cardinality(v_affected_batches) > 0 THEN
        FOR i IN 1 .. cardinality(v_affected_batches) LOOP
            PERFORM update_segment_aggregates_from_batch(v_affected_batches[i]);
        END LOOP;
    END IF;

    -- Retention sweep: drop unmatched rows older than 90 days.
    DELETE FROM unmatched_readings WHERE created_at < now() - INTERVAL '90 days';
    GET DIAGNOSTICS v_purged = ROW_COUNT;

    RETURN json_build_object(
        'promoted', v_promoted_strict + v_promoted_fallback,
        'promoted_strict', v_promoted_strict,
        'promoted_fallback', v_promoted_fallback,
        'still_unmatched', v_still_unmatched,
        'purged_expired', v_purged,
        'affected_batches', v_affected_batches
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION replay_unmatched_readings(INTEGER, INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION replay_unmatched_readings(INTEGER, INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION replay_unmatched_readings(INTEGER, INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION replay_unmatched_readings(INTEGER, INTEGER) TO service_role;
