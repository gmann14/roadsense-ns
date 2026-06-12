-- Restore the unmatched-readings holding insert lost in a later ingest rewrite
-- (NEW-1, docs/reviews/2026-06-11-backend-prelaunch-review.md).
--
-- 20260428001647_unmatched_readings_holding_table.sql created the
-- `unmatched_readings` holding table and rewrote `ingest_reading_batch` so
-- `no_segment_match` rejections are preserved for replay via
-- `replay_unmatched_readings(...)` instead of being silently discarded.
--
-- 20260505130000_tiered_segment_match_radius.sql then redefined
-- `ingest_reading_batch` from an older body to add road-class-tiered match
-- radii, accidentally dropping the holding insert: since 2026-05-05, readings
-- rejected as `no_segment_match` have been discarded again, while the holding
-- table and replay RPC sat unused. (20260612090000_clamp_pothole_ingest_bounds
-- only redefines `fold_pothole_candidates`, so the 20260505130000 body is the
-- current last-write-wins definition.)
--
-- This migration re-creates the 20260505130000 body verbatim, with exactly the
-- holding-flow pieces from 20260428001647 restored:
-- 1. `v_held_for_retry` counter declaration.
-- 2. The `INSERT INTO unmatched_readings ... WHERE final_rejection_reason =
--    'no_segment_match'` block after the accepted-readings insert (same
--    columns, `last_match_attempt_at = now()`).
-- 3. `held_for_retry` in the fresh-batch response JSON.
--
-- No other behavior changes: tiered radii, top-5 KNN candidates, cross-batch
-- dedupe, and the unpaved post-filter are untouched. The `unmatched_readings`
-- table, its indexes/grants, the 90-day retention sweep, and
-- `replay_unmatched_readings(...)` all still exist from 20260428001647 and are
-- not redefined here. Covered by supabase/tests/016_unmatched_readings_holding.sql.

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
                rs.road_type,
                ST_Distance(rs.geom::geography, t.geom::geography) AS distance_m,
                ABS(
                    ((COALESCE(t.heading, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
                ) AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 50)
              AND rs.is_parking_aisle = FALSE
            ORDER BY rs.geom::geography <-> t.geom::geography
            LIMIT 5
        ) candidates
        WHERE candidates.distance_m <= CASE
                WHEN candidates.road_type IN (
                    'motorway', 'trunk', 'primary',
                    'motorway_link', 'trunk_link', 'primary_link'
                ) THEN 45
                WHEN candidates.road_type IN (
                    'secondary', 'tertiary',
                    'secondary_link', 'tertiary_link'
                ) THEN 25
                ELSE 20
            END
          AND (candidates.heading_diff <= 45 OR candidates.heading_diff >= 135)
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

    -- Rejections that are not "no_segment_match" stay rejected. The unpaved /
    -- low_quality / out_of_bounds / future_timestamp / stale_timestamp /
    -- duplicate_reading cases are deliberate filters, not coverage gaps.
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
        heading,
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
