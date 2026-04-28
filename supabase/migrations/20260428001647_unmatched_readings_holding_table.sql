-- Unmatched-readings holding table.
--
-- Before this migration, ingest_reading_batch silently dropped readings whose
-- nearest road_segment was further than 20 m / not paired by heading. The
-- rejection reason was logged in processed_batches.rejected_reasons but the
-- raw sample data was gone. So a drive in an unmapped area (e.g. a fresh OSM
-- region not yet imported, a brand-new subdivision) lost data permanently.
--
-- After this migration, those rows are written to unmatched_readings instead.
-- The replay_unmatched_readings(...) RPC re-attempts segment matching against
-- the current road_segments table; rows that now match are promoted into the
-- regular readings table (with the original batch_id so per-batch reporting
-- stays accurate) and deleted from the holding table. Rows that still cannot
-- match stay in the holding table for the next OSM refresh.
--
-- Retention: 90 days. The holding table is for stale-OSM recovery, not for
-- long-term storage of bad data.

CREATE TABLE IF NOT EXISTS unmatched_readings (
    id BIGSERIAL PRIMARY KEY,
    batch_id UUID NOT NULL,
    device_token_hash BYTEA NOT NULL,
    location GEOMETRY(POINT, 4326) NOT NULL,
    roughness_rms NUMERIC NOT NULL,
    speed_kmh NUMERIC NOT NULL,
    heading_degrees NUMERIC NOT NULL,
    gps_accuracy_m NUMERIC NOT NULL,
    is_pothole BOOLEAN NOT NULL DEFAULT FALSE,
    pothole_magnitude NUMERIC,
    recorded_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_match_attempt_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_unmatched_readings_geog
    ON unmatched_readings USING GIST ((location::geography));

CREATE INDEX IF NOT EXISTS idx_unmatched_readings_device_recorded_at
    ON unmatched_readings (device_token_hash, recorded_at);

CREATE INDEX IF NOT EXISTS idx_unmatched_readings_created_at
    ON unmatched_readings (created_at);

ALTER TABLE unmatched_readings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON unmatched_readings FROM anon;
REVOKE ALL ON unmatched_readings FROM authenticated;
REVOKE ALL ON SEQUENCE unmatched_readings_id_seq FROM anon;
REVOKE ALL ON SEQUENCE unmatched_readings_id_seq FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON unmatched_readings TO service_role;
GRANT USAGE, SELECT, UPDATE ON SEQUENCE unmatched_readings_id_seq TO service_role;

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
                ST_Distance(rs.geom::geography, t.geom::geography) AS distance_m,
                ABS(
                    ((COALESCE(t.heading, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
                ) AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, t.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
            ORDER BY rs.geom::geography <-> t.geom::geography
            LIMIT 3
        ) candidates
        WHERE candidates.distance_m <= 20
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

CREATE OR REPLACE FUNCTION replay_unmatched_readings(
    p_max_rows INTEGER DEFAULT 50000,
    p_min_age_seconds INTEGER DEFAULT 0
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_promoted INTEGER := 0;
    v_still_unmatched INTEGER := 0;
    v_purged INTEGER := 0;
    v_affected_batches UUID[];
BEGIN
    IF p_max_rows IS NULL OR p_max_rows <= 0 THEN
        p_max_rows := 50000;
    END IF;

    DROP TABLE IF EXISTS tmp_replay_candidates;
    DROP TABLE IF EXISTS tmp_replay_matched;
    DROP TABLE IF EXISTS tmp_replay_promoted;

    -- Snapshot the working set so concurrent inserts don't make us loop
    -- forever. Most-recent-first so we re-bring up the freshest data first
    -- (a long-stale row is more likely to be deduped against an existing
    -- accepted row anyway).
    CREATE TEMP TABLE tmp_replay_candidates ON COMMIT DROP AS
    SELECT u.*, ST_SetSRID(u.location, 4326) AS geom
    FROM unmatched_readings u
    WHERE u.created_at <= now() - make_interval(secs => p_min_age_seconds)
    ORDER BY u.created_at DESC
    LIMIT p_max_rows;

    -- Re-attempt the segment match using the same logic as ingest_reading_batch.
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
                ABS(
                    ((COALESCE(c.heading_degrees, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
                ) AS heading_diff
            FROM road_segments rs
            WHERE ST_DWithin(rs.geom::geography, c.geom::geography, 25)
              AND rs.is_parking_aisle = FALSE
              AND rs.surface_type NOT IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand')
            ORDER BY rs.geom::geography <-> c.geom::geography
            LIMIT 3
        ) candidates
        WHERE candidates.distance_m <= 20
          AND (candidates.heading_diff <= 45 OR candidates.heading_diff >= 135)
        ORDER BY candidates.distance_m
        LIMIT 1
    ) m ON TRUE;

    -- Identify the rows that newly match AND are not already in readings (so a
    -- prior successful ingest from the same device + recorded_at + 0.5m doesn't
    -- get a duplicate row). Snapshot eligible unmatched_ids into their own temp
    -- table so we can safely INSERT then DELETE without losing track of which
    -- rows were promoted.
    DROP TABLE IF EXISTS tmp_replay_promoted_ids;
    CREATE TEMP TABLE tmp_replay_promoted_ids ON COMMIT DROP AS
    SELECT rm.unmatched_id
    FROM tmp_replay_matched rm
    WHERE rm.segment_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM readings existing
          WHERE existing.device_token_hash = rm.device_token_hash
            AND existing.recorded_at = rm.recorded_at
            AND ST_DWithin(existing.location::geography, rm.geom::geography, 0.5)
      );

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
    INNER JOIN tmp_replay_promoted_ids p ON p.unmatched_id = rm.unmatched_id;

    GET DIAGNOSTICS v_promoted = ROW_COUNT;

    SELECT COALESCE(array_agg(DISTINCT rm.batch_id), ARRAY[]::UUID[])
    INTO v_affected_batches
    FROM tmp_replay_matched rm
    INNER JOIN tmp_replay_promoted_ids p ON p.unmatched_id = rm.unmatched_id;

    -- Delete promoted rows from the holding table.
    DELETE FROM unmatched_readings u
    USING tmp_replay_promoted_ids p
    WHERE u.id = p.unmatched_id;

    -- Mark still-unmatched rows so we can prefer freshly-arrived rows on the
    -- next pass, but leave them for the next OSM refresh cycle.
    UPDATE unmatched_readings u
    SET last_match_attempt_at = now()
    FROM tmp_replay_matched rm
    WHERE u.id = rm.unmatched_id
      AND rm.segment_id IS NULL;

    SELECT COUNT(*) INTO v_still_unmatched
    FROM tmp_replay_matched
    WHERE segment_id IS NULL;

    -- Recompute aggregates for batches that gained rows.
    IF cardinality(v_affected_batches) > 0 THEN
        FOR i IN 1 .. cardinality(v_affected_batches) LOOP
            PERFORM update_segment_aggregates_from_batch(v_affected_batches[i]);
        END LOOP;
    END IF;

    -- Retention sweep: drop unmatched rows older than 90 days. They've had
    -- multiple chances to be replayed and the road clearly isn't coming.
    DELETE FROM unmatched_readings WHERE created_at < now() - INTERVAL '90 days';
    GET DIAGNOSTICS v_purged = ROW_COUNT;

    RETURN json_build_object(
        'promoted', v_promoted,
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
