-- Ingest / matching / aggregation hardening
-- (docs/reviews/2026-10-18-full-codebase-review.md: N8, the unified-matcher
-- behaviour change, replay double-counting, deadlock ordering, pothole
-- find-or-create races, DBSCAN eps, readings(uploaded_at) index).
--
-- Every function below is redefined from its LATEST body; deltas are
-- commented inline as "2026-11 delta".
--
-- 1. match_reading_to_segment (latest: 20260702150000_unify_segment_matching.sql)
--    - Heading outside [0, 360) (or NaN) is treated as "no heading" before
--      the `::INT` cast, so a heading of 1e10 can no longer overflow the cast
--      and 500 the whole batch.
--    - Restores the pre-unification "reject if the nearest acceptable
--      candidate is unpaved" semantics. 20260702150000 filtered unpaved
--      candidates out of the top-5 pool *before* picking the nearest, so a
--      reading on a gravel road could attach to a heading-aligned paved road
--      up to 45 m away. Now the nearest radius+heading-accepted candidate is
--      chosen first and, with p_require_paved, the reading is rejected when
--      that candidate is unpaved.
-- 2. ingest_reading_batch (latest: 20260702150000)
--    - N8: per-reading sanitising instead of whole-batch failure. Heading
--      outside [0, 360) becomes NULL. Negative / NULL GPS accuracy, NULL
--      required fields and pothole magnitudes outside [0, 8] g reject only
--      that reading as `low_quality` (an existing reason code, so client
--      enums keep decoding). Nothing out of range reaches the NUMERIC(5,x)
--      columns any more.
-- 3. update_segment_aggregates_from_batch (latest: 20260612180000)
--    - Body moved to update_segment_aggregates_from_readings(batch,
--      uploaded_since) so replay can fold only the readings it just promoted.
--      The 1-arg function is now a thin wrapper (ingest is unchanged).
--    - Marks insert and aggregate UPSERT process rows in segment_id order so
--      two concurrent batches touching the same segments lock them in the
--      same order (deadlock fix).
-- 4. fold_pothole_candidates (latest: 20260612182000)
--    - Same wrapper split (fold_pothole_candidates_for_readings).
--    - Serialises find-or-create per area with transaction-scoped advisory
--      locks on a ~100 m grid (pothole_area_lock_keys), so two concurrent
--      first reports of the same pothole can no longer each create a
--      single-reporter candidate that never reaches the 2-device gate.
--    - DBSCAN eps is now 15 real metres (EPSG:2961, NAD83(CSRS) / UTM 20N)
--      instead of 15 Web-Mercator units (~10.6 m on the ground at 44.6 N).
-- 5. replay_unmatched_readings (latest: 20260702150000)
--    - Only the readings promoted in this call are added to aggregates (it
--      used to re-add every reading of every affected batch), and promoted
--      pothole readings are now folded into pothole_reports.
--    - Out-of-range legacy values are sanitised before they hit the
--      NUMERIC(5,x) readings columns.
-- 6. readings(uploaded_at) index on the partitioned parent: the nightly
--    recompute selects its targets by uploaded_at.

-- ---------------------------------------------------------------------------
-- 1. match_reading_to_segment
-- ---------------------------------------------------------------------------

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
    SELECT nearest.segment_id, nearest.distance_m, nearest.surface_type
    FROM (
        SELECT candidates.segment_id, candidates.distance_m, candidates.surface_type
        FROM (
            SELECT
                rs.id AS segment_id,
                rs.surface_type,
                rs.road_type,
                ST_Distance(rs.geom::geography, p_geom::geography) AS distance_m,
                -- 2026-11 delta: an out-of-range / NaN heading is "no
                -- heading" (falls back to the segment bearing), so the INT
                -- cast below only ever sees values in [180, 900).
                ABS(
                    ((COALESCE(
                        CASE WHEN p_heading >= 0 AND p_heading < 360 THEN p_heading END,
                        rs.bearing_degrees
                    ) - rs.bearing_degrees + 540)::INT % 360) - 180
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
        ORDER BY candidates.distance_m
        LIMIT 1
    ) nearest
    -- 2026-11 delta: surface is checked on the nearest accepted candidate
    -- (pre-20260702150000 ingest semantics), not used to pre-filter the pool.
    WHERE NOT p_require_paved
       OR COALESCE(nearest.surface_type, 'unknown') NOT IN ('gravel', 'dirt', 'unpaved', 'ground', 'sand');
$$;

COMMENT ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) IS
    'Single source of truth for "which road_segment does this point + heading match", shared by ingest_reading_batch, rematch_readings_after_segment_refresh, and replay_unmatched_readings. Picks the nearest of the 5 closest non-parking-aisle segments that passes the tiered accept radius (45m motorway/trunk/primary, 25m secondary/tertiary, 20m else) and the +-45 degree heading tolerance (either direction; a heading outside [0,360) is treated as missing). With p_require_paved (the default) no row is returned when that nearest candidate is explicitly unpaved (gravel/dirt/unpaved/ground/sand); NULL/unknown surface is accepted. Call again with p_require_paved := FALSE to tell "nearest road is unpaved" from "no road nearby". See 20260702150000 and 20261108110000.';

REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM anon;
REVOKE EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) FROM authenticated;
GRANT EXECUTE ON FUNCTION match_reading_to_segment(geometry, double precision, BOOLEAN) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. update_segment_aggregates_from_readings / _from_batch
-- ---------------------------------------------------------------------------

-- Body of 20260612180000's update_segment_aggregates_from_batch, with two
-- deltas: the optional p_uploaded_since filter (NULL = whole batch, the old
-- behaviour) and segment_id ordering on both writes.
CREATE OR REPLACE FUNCTION update_segment_aggregates_from_readings(
    p_batch_id UUID,
    p_uploaded_since TIMESTAMPTZ DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    WITH new_marks AS (
        INSERT INTO segment_contributor_marks (segment_id, device_token_hash, first_seen_at)
        SELECT r.segment_id, r.device_token_hash, MIN(r.recorded_at)
        FROM readings r
        WHERE r.batch_id = p_batch_id
          AND r.segment_id IS NOT NULL
          AND (p_uploaded_since IS NULL OR r.uploaded_at >= p_uploaded_since)
        GROUP BY r.segment_id, r.device_token_hash
        -- 2026-11 delta: deterministic lock order.
        ORDER BY r.segment_id, r.device_token_hash
        ON CONFLICT (segment_id, device_token_hash) DO NOTHING
        RETURNING segment_id
    ),
    new_mark_counts AS (
        SELECT segment_id, COUNT(*)::INTEGER AS new_contributors
        FROM new_marks
        GROUP BY segment_id
    )
    INSERT INTO segment_aggregates (
        segment_id,
        avg_roughness_score,
        total_readings,
        unique_contributors,
        last_reading_at,
        pothole_count,
        confidence,
        roughness_category
    )
    SELECT
        r.segment_id,
        AVG(r.roughness_rms)::NUMERIC(5,3),
        COUNT(*)::INTEGER,
        COALESCE(nmc.new_contributors, 0),
        MAX(r.recorded_at),
        COUNT(*) FILTER (WHERE r.is_pothole)::INTEGER,
        'low'::confidence_level,
        'unscored'::roughness_category
    FROM readings r
    LEFT JOIN new_mark_counts nmc ON nmc.segment_id = r.segment_id
    WHERE r.batch_id = p_batch_id
      AND r.segment_id IS NOT NULL
      AND (p_uploaded_since IS NULL OR r.uploaded_at >= p_uploaded_since)
    GROUP BY r.segment_id, nmc.new_contributors
    -- 2026-11 delta: deterministic lock order (deadlock fix).
    ORDER BY r.segment_id
    ON CONFLICT (segment_id) DO UPDATE SET
        avg_roughness_score = (
            segment_aggregates.avg_roughness_score *
                (segment_aggregates.total_readings::NUMERIC /
                 NULLIF(segment_aggregates.total_readings + EXCLUDED.total_readings, 0))
            + EXCLUDED.avg_roughness_score *
                (EXCLUDED.total_readings::NUMERIC /
                 NULLIF(segment_aggregates.total_readings + EXCLUDED.total_readings, 0))
        ),
        total_readings = segment_aggregates.total_readings + EXCLUDED.total_readings,
        unique_contributors = segment_aggregates.unique_contributors + EXCLUDED.unique_contributors,
        last_reading_at = GREATEST(segment_aggregates.last_reading_at, EXCLUDED.last_reading_at),
        pothole_count = segment_aggregates.pothole_count + EXCLUDED.pothole_count,
        updated_at = now();

    UPDATE segment_aggregates sa
    SET
        confidence = CASE
            WHEN sa.unique_contributors >= 10 THEN 'high'::confidence_level
            WHEN sa.unique_contributors >= 3 THEN 'medium'::confidence_level
            ELSE 'low'::confidence_level
        END,
        roughness_category = roughness_category_for_score(sa.avg_roughness_score),
        updated_at = now()
    WHERE sa.segment_id IN (
        SELECT DISTINCT segment_id
        FROM readings
        WHERE batch_id = p_batch_id
          AND segment_id IS NOT NULL
          AND (p_uploaded_since IS NULL OR uploaded_at >= p_uploaded_since)
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION update_segment_aggregates_from_readings(UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_segment_aggregates_from_readings(UUID, TIMESTAMPTZ) FROM anon;
REVOKE EXECUTE ON FUNCTION update_segment_aggregates_from_readings(UUID, TIMESTAMPTZ) FROM authenticated;
GRANT EXECUTE ON FUNCTION update_segment_aggregates_from_readings(UUID, TIMESTAMPTZ) TO service_role;

CREATE OR REPLACE FUNCTION update_segment_aggregates_from_batch(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM update_segment_aggregates_from_readings(p_batch_id, NULL);
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. fold_pothole_candidates
-- ---------------------------------------------------------------------------

-- Advisory-lock keys for the ~0.001 degree grid cells (about 80 m x 110 m in
-- NS) touched by a +-0.0005 degree box around a point (about +-40 m of
-- longitude, +-55 m of latitude). Any two points that could match each other
-- or the same pothole (15 m match radius, so at most 30 m apart) share at
-- least one key, which is all that is needed to serialise their
-- find-or-create. At most 4 keys per point.
CREATE OR REPLACE FUNCTION pothole_area_lock_keys(p_geom geometry)
RETURNS SETOF INTEGER
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT DISTINCT hashtext(cx::TEXT || ':' || cy::TEXT)
    FROM generate_series(
             floor((ST_X(p_geom) - 0.0005) / 0.001)::BIGINT,
             floor((ST_X(p_geom) + 0.0005) / 0.001)::BIGINT
         ) AS cx,
         generate_series(
             floor((ST_Y(p_geom) - 0.0005) / 0.001)::BIGINT,
             floor((ST_Y(p_geom) + 0.0005) / 0.001)::BIGINT
         ) AS cy
    WHERE p_geom IS NOT NULL;
$$;

REVOKE EXECUTE ON FUNCTION pothole_area_lock_keys(geometry) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pothole_area_lock_keys(geometry) FROM anon;
REVOKE EXECUTE ON FUNCTION pothole_area_lock_keys(geometry) FROM authenticated;
GRANT EXECUTE ON FUNCTION pothole_area_lock_keys(geometry) TO service_role;

-- Body of 20260612182000's fold_pothole_candidates with three 2026-11
-- deltas: the p_uploaded_since filter, the per-area advisory locks taken (in
-- sorted key order) before the find-or-create statement, and DBSCAN in real
-- metres. Everything else (B165 corroboration gate, reporter marks, P0-1
-- magnitude/speed bounds, 15 m / 90 day matching window) is unchanged.
CREATE OR REPLACE FUNCTION fold_pothole_candidates_for_readings(
    p_batch_id UUID,
    p_uploaded_since TIMESTAMPTZ DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_lock_key INTEGER;
BEGIN
    -- 2026-11 delta: serialise find-or-create with any concurrent fold or
    -- manual report in the same area. Keys are taken in ascending order so
    -- two batches with overlapping areas cannot deadlock on each other. The
    -- find-or-create statement below starts after the locks are held, so in
    -- READ COMMITTED it sees anything a just-finished competitor inserted.
    FOR v_lock_key IN
        SELECT DISTINCT k.key
        FROM readings r
        CROSS JOIN LATERAL pothole_area_lock_keys(r.location) AS k(key)
        WHERE r.batch_id = p_batch_id
          AND r.is_pothole = TRUE
          AND r.segment_id IS NOT NULL
          AND (p_uploaded_since IS NULL OR r.uploaded_at >= p_uploaded_since)
        ORDER BY k.key
    LOOP
        PERFORM pg_advisory_xact_lock(7301, v_lock_key);
    END LOOP;

    WITH batch_candidates AS (
        SELECT
            r.segment_id,
            r.location,
            LEAST(
                GREATEST(COALESCE(r.pothole_magnitude, r.roughness_rms), 0),
                8
            )::NUMERIC(4,2) AS magnitude,
            r.recorded_at,
            r.device_token_hash
        FROM readings r
        WHERE r.batch_id = p_batch_id
          AND (p_uploaded_since IS NULL OR r.uploaded_at >= p_uploaded_since)
          AND r.is_pothole = TRUE
          AND r.speed_kmh >= 45
          AND r.speed_kmh <= 160
          AND (
              r.pothole_magnitude IS NULL
              OR (r.pothole_magnitude > 0 AND r.pothole_magnitude <= 8)
          )
          AND r.segment_id IS NOT NULL
    ),
    matched_existing AS (
        SELECT
            bc.segment_id,
            bc.location,
            bc.magnitude,
            bc.recorded_at,
            bc.device_token_hash,
            pr.id AS pothole_id
        FROM batch_candidates bc
        LEFT JOIN LATERAL (
            SELECT pr.id
            FROM pothole_reports pr
            WHERE pr.status IN ('active', 'candidate')
              AND pr.segment_id = bc.segment_id
              AND pr.last_confirmed_at >= bc.recorded_at - INTERVAL '90 days'
              AND ST_DWithin(pr.geom::geography, bc.location::geography, 15)
            ORDER BY pr.geom::geography <-> bc.location::geography
            LIMIT 1
        ) pr ON TRUE
    ),
    new_marks AS (
        INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
        SELECT DISTINCT me.pothole_id, me.device_token_hash
        FROM matched_existing me
        WHERE me.pothole_id IS NOT NULL
        ON CONFLICT (pothole_id, device_token_hash) DO NOTHING
        RETURNING pothole_id
    ),
    new_mark_counts AS (
        SELECT pothole_id, COUNT(*)::INTEGER AS reporter_count
        FROM new_marks
        GROUP BY pothole_id
    ),
    update_existing AS (
        UPDATE pothole_reports pr
        SET
            last_confirmed_at = GREATEST(pr.last_confirmed_at, agg.last_at),
            confirmation_count = pr.confirmation_count + agg.hit_count,
            unique_reporters = pr.unique_reporters + COALESCE(nmc.reporter_count, 0),
            magnitude = GREATEST(pr.magnitude, agg.max_magnitude),
            status = CASE
                WHEN pr.status = 'candidate'
                 AND pr.unique_reporters + COALESCE(nmc.reporter_count, 0) >= 2
                    THEN 'active'::pothole_status
                ELSE pr.status
            END
        FROM (
            SELECT
                pothole_id,
                COUNT(*)::INTEGER AS hit_count,
                MAX(recorded_at) AS last_at,
                MAX(magnitude) AS max_magnitude
            FROM matched_existing
            WHERE pothole_id IS NOT NULL
            GROUP BY pothole_id
        ) agg
        LEFT JOIN new_mark_counts nmc ON nmc.pothole_id = agg.pothole_id
        WHERE pr.id = agg.pothole_id
        RETURNING pr.id
    ),
    unmatched AS (
        SELECT
            me.segment_id,
            me.location,
            me.magnitude,
            me.recorded_at,
            me.device_token_hash,
            -- 2026-11 delta: cluster in real metres (NAD83(CSRS) / UTM 20N).
            -- 15 units of EPSG:3857 is only ~10.6 m on the ground at 44.6 N.
            ST_ClusterDBSCAN(ST_Transform(me.location, 2961), eps := 15, minpoints := 1)
                OVER (PARTITION BY me.segment_id) AS cluster_id
        FROM matched_existing me
        WHERE me.pothole_id IS NULL
    ),
    new_clusters AS (
        SELECT
            u.segment_id,
            u.cluster_id,
            gen_random_uuid() AS pothole_id
        FROM unmatched u
        GROUP BY u.segment_id, u.cluster_id
    ),
    inserted_potholes AS (
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
        )
        SELECT
            nc.pothole_id,
            u.segment_id,
            ST_Centroid(ST_Collect(u.location))::GEOMETRY(POINT, 4326) AS geom,
            MAX(u.magnitude)::NUMERIC(4,2) AS magnitude,
            MIN(u.recorded_at) AS first_reported_at,
            MAX(u.recorded_at) AS last_confirmed_at,
            COUNT(*)::INTEGER AS confirmation_count,
            COUNT(DISTINCT u.device_token_hash)::INTEGER AS unique_reporters,
            CASE
                WHEN COUNT(DISTINCT u.device_token_hash) >= 2
                    THEN 'active'::pothole_status
                ELSE 'candidate'::pothole_status
            END
        FROM unmatched u
        JOIN new_clusters nc
          ON nc.segment_id = u.segment_id
         AND nc.cluster_id IS NOT DISTINCT FROM u.cluster_id
        GROUP BY nc.pothole_id, u.segment_id, u.cluster_id
        RETURNING id
    )
    INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
    SELECT DISTINCT nc.pothole_id, u.device_token_hash
    FROM unmatched u
    JOIN new_clusters nc
      ON nc.segment_id = u.segment_id
     AND nc.cluster_id IS NOT DISTINCT FROM u.cluster_id
    ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
END;
$$;

REVOKE EXECUTE ON FUNCTION fold_pothole_candidates_for_readings(UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fold_pothole_candidates_for_readings(UUID, TIMESTAMPTZ) FROM anon;
REVOKE EXECUTE ON FUNCTION fold_pothole_candidates_for_readings(UUID, TIMESTAMPTZ) FROM authenticated;
GRANT EXECUTE ON FUNCTION fold_pothole_candidates_for_readings(UUID, TIMESTAMPTZ) TO service_role;

CREATE OR REPLACE FUNCTION fold_pothole_candidates(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM fold_pothole_candidates_for_readings(p_batch_id, NULL);
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. ingest_reading_batch
-- ---------------------------------------------------------------------------

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
        -- 2026-11 delta (N8): a heading outside [0, 360) is "no heading".
        -- It used to overflow readings.heading_degrees NUMERIC(5,1) or the
        -- matcher's INT cast and 500 the whole batch.
        CASE WHEN p.heading >= 0 AND p.heading < 360 THEN p.heading END AS heading,
        p.gps_accuracy_m,
        p.is_pothole,
        p.pothole_magnitude,
        p.recorded_at,
        ST_SetSRID(ST_MakePoint(p.lng, p.lat), 4326) AS geom,
        CASE
            -- 2026-11 delta (N8): a reading missing a required value is
            -- rejected on its own instead of failing the batch on a NOT NULL
            -- constraint.
            WHEN p.lat IS NULL
              OR p.lng IS NULL
              OR p.recorded_at IS NULL
              OR p.roughness_rms IS NULL
              OR p.speed_kmh IS NULL THEN 'low_quality'
            WHEN p.lng NOT BETWEEN -66.5 AND -59.5
              OR p.lat NOT BETWEEN 43.3 AND 47.1 THEN 'out_of_bounds'
            WHEN p.recorded_at > now() + INTERVAL '60 seconds' THEN 'future_timestamp'
            WHEN p.recorded_at < now() - INTERVAL '7 days' THEN 'stale_timestamp'
            WHEN p.gps_accuracy_m > 20
              -- 2026-11 delta (N8): iOS reports -1 for an invalid fix; a
              -- negative or missing accuracy is not "high quality".
              OR p.gps_accuracy_m IS NULL
              OR p.gps_accuracy_m < 0
              OR p.speed_kmh < 15
              OR p.speed_kmh > 160
              OR p.roughness_rms < 0
              OR p.roughness_rms > 15
              -- 2026-11 delta (N8): > 8 g is a phone leaving its mount, not a
              -- pothole; reject the reading rather than the batch.
              OR p.pothole_magnitude < 0
              OR p.pothole_magnitude > 8 THEN 'low_quality'
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

-- ---------------------------------------------------------------------------
-- 5. replay_unmatched_readings
-- ---------------------------------------------------------------------------

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
    -- 2026-11 delta: every reading this call promotes is stamped with this
    -- uploaded_at, which is strictly later than any earlier transaction's
    -- rows, so the aggregate/pothole folds below can select exactly them.
    v_promoted_at TIMESTAMPTZ := now();
BEGIN
    IF p_max_rows IS NULL OR p_max_rows <= 0 THEN
        p_max_rows := 50000;
    END IF;

    DROP TABLE IF EXISTS tmp_replay_candidates;
    DROP TABLE IF EXISTS tmp_replay_matched;
    DROP TABLE IF EXISTS tmp_replay_promoted;

    CREATE TEMP TABLE tmp_replay_candidates ON COMMIT DROP AS
    SELECT u.*, ST_SetSRID(u.location, 4326) AS geom
    FROM unmatched_readings u
    WHERE u.created_at <= now() - make_interval(secs => p_min_age_seconds)
    ORDER BY u.created_at DESC
    LIMIT p_max_rows;

    CREATE TEMP TABLE tmp_replay_matched ON COMMIT DROP AS
    SELECT
        c.id AS unmatched_id,
        c.batch_id,
        c.device_token_hash,
        c.geom,
        c.roughness_rms,
        c.speed_kmh,
        -- 2026-11 delta: sanitise legacy holding-table values before they
        -- reach the NUMERIC(5,x) readings columns.
        CASE WHEN c.heading_degrees >= 0 AND c.heading_degrees < 360 THEN c.heading_degrees END AS heading_degrees,
        c.gps_accuracy_m,
        c.is_pothole AND COALESCE(c.pothole_magnitude BETWEEN 0 AND 8, TRUE) AS is_pothole,
        CASE WHEN c.pothole_magnitude BETWEEN 0 AND 8 THEN c.pothole_magnitude END AS pothole_magnitude,
        c.recorded_at,
        m.segment_id,
        m.distance_m
    FROM tmp_replay_candidates c
    LEFT JOIN LATERAL match_reading_to_segment(c.geom, c.heading_degrees::double precision) m ON TRUE;

    DROP TABLE IF EXISTS tmp_replay_promoted_ids;
    CREATE TEMP TABLE tmp_replay_promoted_ids ON COMMIT DROP AS
    SELECT rm.unmatched_id
    FROM tmp_replay_matched rm
    WHERE rm.segment_id IS NOT NULL
      AND rm.recorded_at > now() - INTERVAL '6 months'
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
        recorded_at,
        uploaded_at
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
        rm.recorded_at,
        v_promoted_at
    FROM tmp_replay_matched rm
    INNER JOIN tmp_replay_promoted_ids p ON p.unmatched_id = rm.unmatched_id;

    GET DIAGNOSTICS v_promoted = ROW_COUNT;

    SELECT COALESCE(array_agg(DISTINCT rm.batch_id ORDER BY rm.batch_id), ARRAY[]::UUID[])
    INTO v_affected_batches
    FROM tmp_replay_matched rm
    INNER JOIN tmp_replay_promoted_ids p ON p.unmatched_id = rm.unmatched_id;

    DELETE FROM unmatched_readings u
    USING tmp_replay_promoted_ids p
    WHERE u.id = p.unmatched_id;

    UPDATE unmatched_readings u
    SET last_match_attempt_at = now()
    FROM tmp_replay_matched rm
    WHERE u.id = rm.unmatched_id
      AND rm.segment_id IS NULL;

    SELECT COUNT(*) INTO v_still_unmatched
    FROM tmp_replay_matched
    WHERE segment_id IS NULL;

    -- 2026-11 delta: fold only the readings promoted by this call (the old
    -- body re-added every reading of each affected batch, double-counting
    -- the originally accepted ones), and fold promoted pothole readings too.
    IF cardinality(v_affected_batches) > 0 THEN
        FOR i IN 1 .. cardinality(v_affected_batches) LOOP
            PERFORM update_segment_aggregates_from_readings(v_affected_batches[i], v_promoted_at);
            PERFORM fold_pothole_candidates_for_readings(v_affected_batches[i], v_promoted_at);
        END LOOP;
    END IF;

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

-- ---------------------------------------------------------------------------
-- 6. readings(uploaded_at) index
-- ---------------------------------------------------------------------------

-- Created on the partitioned parent so every existing partition gets it and
-- partitions created later by create_next_readings_partition() inherit it.
-- Plain (non-CONCURRENTLY) build: CONCURRENTLY is not supported on a
-- partitioned parent. It briefly blocks writes to readings while it builds.
CREATE INDEX IF NOT EXISTS idx_readings_uploaded_at ON readings (uploaded_at);
