-- P1: three divergent segment-matching implementations.
--
-- `rematch_readings_after_segment_refresh` (20260418123010_rematch_readings_after_refresh.sql,
-- never updated since) used a flat 20m radius and a strict surface allowlist
-- (COALESCE(surface_type,'unknown') IN ('paved','asphalt','concrete','paving_stones')).
-- The current `ingest_reading_batch` (20260612120000_restore_unmatched_readings_holding_insert.sql)
-- uses tiered radii (45m motorway/trunk/primary[+_link], 25m secondary/tertiary[+_link],
-- 20m everything else) and only rejects explicit unpaved surfaces
-- (gravel/dirt/unpaved/ground/sand), treating NULL/unknown as acceptable.
-- `replay_unmatched_readings` (20260428001647_unmatched_readings_holding_table.sql)
-- has a third variant that matches ingest's radii but applies the unpaved
-- filter inside the candidate CTE instead of as a post-filter. Net effect:
-- running the documented refresh -> rematch pipeline detaches readings that
-- ingest would have legitimately matched (e.g. a secondary road at 22m, or a
-- segment with surface_type NULL), because rematch is still on the old,
-- stricter 2026-04 criteria.
--
-- Fix: extract the matching *criteria* (candidate pool, tiered accept radius,
-- heading tolerance, surface acceptance) into one shared SQL function,
-- `match_reading_to_segment`, and have all three callers use it for the
-- "which segment, if any, does this point/heading match" decision. Only the
-- matching criteria are unified here — what each caller does with the match
-- (insert vs UPDATE vs promote-and-delete, aggregate folding, dedupe, batch
-- accounting, etc.) is untouched.
--
-- The shared criteria adopted are ingest_reading_batch's current (most
-- recently reviewed/updated) behavior, since it is what actually decides
-- whether client-submitted readings enter the system today:
--   - Candidate pool: within 50m, not a parking aisle, nearest 5 by distance.
--   - Accept radius, tiered by road_type: 45m for motorway/trunk/primary
--     (+ _link variants), 25m for secondary/tertiary (+ _link variants),
--     20m otherwise.
--   - Heading: within 45 degrees of the segment bearing, either direction of
--     travel (candidates.heading_diff <= 45 OR >= 135), using the reading's
--     own heading, falling back to the segment bearing when the reading has
--     no heading (see 20260702120500_unmatched_readings_heading_nullable.sql
--     for why a NULL reading heading must be tolerated here).
--   - Surface: reject only explicit unpaved surfaces (gravel, dirt, unpaved,
--     ground, sand); NULL/unknown/other values are acceptable matches.
--   - Nearest accepted candidate wins.

CREATE OR REPLACE FUNCTION match_reading_to_segment(
    p_geom geometry,
    p_heading double precision,
    p_require_paved BOOLEAN DEFAULT TRUE
) RETURNS TABLE (
    segment_id UUID,
    distance_m double precision,
    surface_type TEXT
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT candidates.segment_id, candidates.distance_m, candidates.surface_type
    FROM (
        SELECT
            rs.id AS segment_id,
            rs.surface_type,
            rs.road_type,
            ST_Distance(rs.geom::geography, p_geom::geography) AS distance_m,
            ABS(
                ((COALESCE(p_heading, rs.bearing_degrees) - rs.bearing_degrees + 540)::INT % 360) - 180
            ) AS heading_diff
        FROM road_segments rs
        WHERE ST_DWithin(rs.geom::geography, p_geom::geography, 50)
          AND rs.is_parking_aisle = FALSE
        ORDER BY rs.geom::geography <-> p_geom::geography
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
      AND (
          NOT p_require_paved
          OR COALESCE(candidates.surface_type, 'unknown') NOT IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand')
      )
    ORDER BY candidates.distance_m
    LIMIT 1;
$$;

COMMENT ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) IS
    'Single source of truth for "which road_segment does this point + heading match", shared by ingest_reading_batch, rematch_readings_after_segment_refresh, and replay_unmatched_readings. Tiered accept radius by road_type (45m motorway/trunk/primary, 25m secondary/tertiary, 20m else) and +-45 degree heading tolerance (either direction) are always applied. With p_require_paved (the default), explicit unpaved surfaces (gravel/dirt/unpaved/ground/sand) are excluded from candidates; NULL/unknown is always accepted. Callers that need to distinguish "no segment nearby at all" from "the nearest segment is unpaved" (for rejection-reason reporting) can call again with p_require_paved := FALSE. See 20260702150000_unify_segment_matching.sql for why this exists — the three call sites had drifted to different, inconsistent criteria.';

REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM anon;
REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM authenticated;
GRANT EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) TO service_role;

-- ingest_reading_batch: same accepted/rejected/held-for-retry accounting and
-- surrounding batch logic as 20260612120000, but the per-reading candidate
-- match now comes from match_reading_to_segment(). To keep the 'unpaved' vs
-- 'no_segment_match' rejection-reason distinction (used in
-- processed_batches.rejected_reasons), readings with no paved match get a
-- second, any-surface lookup via the same shared function
-- (p_require_paved := FALSE) purely for labeling — it does not change what
-- gets inserted into readings.
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
        -- Any-surface fallback lookup, used only to distinguish the
        -- 'unpaved' rejection reason from 'no_segment_match' below when the
        -- paved-only match (m) misses. It never changes what gets inserted
        -- into readings — only rejection-reason labeling in
        -- processed_batches.rejected_reasons.
        m_any.segment_id AS any_surface_segment_id
    FROM tmp_batch_readings t
    LEFT JOIN LATERAL match_reading_to_segment(t.geom, t.heading::double precision) m
        ON t.rejection_reason IS NULL
    LEFT JOIN LATERAL match_reading_to_segment(t.geom, t.heading::double precision, FALSE) m_any
        ON t.rejection_reason IS NULL AND m.segment_id IS NULL
    ORDER BY t.recorded_at;

    CREATE TEMP TABLE tmp_final ON COMMIT DROP AS
    SELECT
        t.*,
        m.segment_id,
        m.distance_m,
        CASE
            WHEN t.rejection_reason IS NOT NULL THEN t.rejection_reason
            WHEN EXISTS (
                SELECT 1
                FROM readings existing
                WHERE existing.device_token_hash = p_device_token_hash
                  AND existing.recorded_at = t.recorded_at
                  AND ST_DWithin(existing.location::geography, t.geom::geography, 0.5)
            ) THEN 'duplicate_reading'
            WHEN m.segment_id IS NULL AND m.any_surface_segment_id IS NOT NULL THEN 'unpaved'
            WHEN m.segment_id IS NULL THEN 'no_segment_match'
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

-- replay_unmatched_readings: same snapshot/promote/purge/retention logic as
-- 20260428001647, but the candidate match now comes from
-- match_reading_to_segment() instead of its own inline copy of the criteria.
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

    -- Re-attempt the segment match using the same shared criteria as
    -- ingest_reading_batch (match_reading_to_segment).
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
        m.distance_m
    FROM tmp_replay_candidates c
    LEFT JOIN LATERAL match_reading_to_segment(c.geom, c.heading_degrees::double precision) m ON TRUE;

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

-- rematch_readings_after_segment_refresh: same touched-segment
-- diff/UPDATE/RETURN logic as 20260418123010, but the candidate match now
-- comes from match_reading_to_segment() instead of its own inline
-- flat-20m/strict-surface-allowlist copy of the criteria.
CREATE OR REPLACE FUNCTION rematch_readings_after_segment_refresh(
    p_since TIMESTAMPTZ DEFAULT now() - INTERVAL '6 months'
)
RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_touched UUID[];
BEGIN
    WITH matched AS (
        SELECT
            r.recorded_at AS reading_recorded_at,
            r.id AS reading_id,
            r.segment_id AS old_segment_id,
            m.segment_id AS new_segment_id
        FROM readings r
        LEFT JOIN LATERAL match_reading_to_segment(r.location, r.heading_degrees::double precision) m ON TRUE
        WHERE r.recorded_at >= p_since
    ),
    changed AS (
        SELECT *
        FROM matched
        WHERE old_segment_id IS DISTINCT FROM new_segment_id
    ),
    upd AS (
        UPDATE readings r
        SET segment_id = c.new_segment_id
        FROM changed c
        WHERE r.recorded_at = c.reading_recorded_at
          AND r.id = c.reading_id
        RETURNING c.old_segment_id, c.new_segment_id
    )
    SELECT ARRAY(
        SELECT DISTINCT sid
        FROM (
            SELECT old_segment_id AS sid FROM upd
            UNION
            SELECT new_segment_id AS sid FROM upd
        ) touched
        WHERE sid IS NOT NULL
    ) INTO v_touched;

    RAISE NOTICE 'rematch_readings_after_segment_refresh: % segments touched',
        COALESCE(array_length(v_touched, 1), 0);

    RETURN COALESCE(v_touched, ARRAY[]::UUID[]);
END;
$$;

COMMENT ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) IS
    'Re-matches readings.segment_id for recorded_at >= p_since against the current road_segments (post-refresh), using the shared match_reading_to_segment() criteria (previously a stale flat-20m/strict-surface-allowlist copy that had drifted from ingest_reading_batch — see 20260702150000_unify_segment_matching.sql). Returns the distinct set of segment_ids whose reading membership changed (old and/or new), so callers can target aggregate recompute at just the touched segments.';

REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM anon;
REVOKE EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) FROM authenticated;
GRANT EXECUTE ON FUNCTION rematch_readings_after_segment_refresh(TIMESTAMPTZ) TO service_role;
