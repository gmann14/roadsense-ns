-- B165 (step 2 of 2): pothole corroboration gate — candidate status, exact
-- reporter accounting, and distinct-device promotion to `active`
-- (P1-2/P1-3-class, docs/reviews/2026-06-11-backend-prelaunch-review.md;
-- docs/implementation/15-device-attestation-and-trust.md).
--
-- Before this migration a pothole went public on one device's say-so:
-- `fold_pothole_candidates` inserted `status='active'` from a single batch and
-- `apply_pothole_action` created `active` from a single manual report. The
-- sensor fold's `update_existing` arm also summed per-batch
-- COUNT(DISTINCT device_token_hash) into `unique_reporters` blindly — the same
-- bug class as P1-3 on segment contributors.
--
-- After this migration:
-- - New potholes insert as `candidate` and promote to `active` only once
--   `unique_reporters >= 2` — i.e. two distinct device-token hashes within the
--   existing 15 m / 90 day matching window, via either the sensor or manual
--   path. (Stage 1 counts distinct token hashes; when B164 flips
--   `attestation_enforced`, the same predicate means two physical devices.)
-- - `pothole_reporter_marks` makes `unique_reporters` exact across repeated
--   batches and across the sensor/manual paths.
-- - Public visibility predicates stay untouched: `status='active'` remains the
--   single gate in `get_tile` / `get_potholes_in_bbox` / `get_top_potholes`;
--   the gate moves into the status transition, one place instead of three.
--
-- [DECISION] Grandfathering: existing TestFlight-era single-reporter `active`
-- potholes are KEPT `active`. They predate the adversarial window, came from a
-- personally-known closed tester pool, and demoting them would blank most of
-- the pothole layer weeks before the marketing push. They expire on the normal
-- 90-day unconfirmed cycle, and nothing in the new code paths ever demotes an
-- `active` row. The alternative, if "every marker is corroborated" optics
-- matter more than map density, is a one-off demotion the owner can run
-- instead (recorded here per doc 15 B165; deliberately NOT executed):
--
--     UPDATE pothole_reports
--     SET status = 'candidate'
--     WHERE unique_reporters < 2 AND status = 'active';

CREATE TABLE IF NOT EXISTS pothole_reporter_marks (
    pothole_id UUID NOT NULL REFERENCES pothole_reports(id) ON DELETE CASCADE,
    device_token_hash BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pothole_id, device_token_hash)
);

ALTER TABLE pothole_reporter_marks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pothole_reporter_marks FROM anon;
REVOKE ALL ON pothole_reporter_marks FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON pothole_reporter_marks TO service_role;

-- Backfill marks from existing pothole_actions device hashes where
-- recoverable. Sensor-era potholes have no per-pothole device attribution to
-- recover; their current unique_reporters value is trusted as-is (doc 15
-- B165), so a returning sensor reporter may be counted once more — bounded,
-- one-time, and only ever upward on already-grandfathered rows. Idempotent.
INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
SELECT DISTINCT pa.pothole_report_id, pa.device_token_hash
FROM pothole_actions pa
WHERE pa.pothole_report_id IS NOT NULL
ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;

-- Redefinition of the 20260612090000 body (which added the P0-1 bounds).
-- Deltas, all commented inline:
-- 1. `matched_existing` also matches `candidate` potholes so a second device
--    can corroborate and promote them.
-- 2. `new_marks` / `new_mark_counts` CTEs write reporter marks; only marks
--    that actually insert increment `unique_reporters` (replaces the blind
--    per-batch COUNT(DISTINCT) summation).
-- 3. `update_existing` promotes `candidate` -> `active` at
--    `unique_reporters >= 2`; `active` rows (incl. grandfathered
--    single-reporter ones) are never demoted.
-- 4. New clusters insert with pre-assigned ids (so marks can be written in
--    the same statement) and as `candidate` unless the batch itself carries
--    >= 2 distinct devices.
-- Everything else (P0-1 magnitude/speed bounds, 15 m DBSCAN clustering,
-- 90-day window, >= 45 km/h gate) is unchanged.
CREATE OR REPLACE FUNCTION fold_pothole_candidates(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
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
            -- B165 delta: was status = 'active'. Candidates must be matchable
            -- so a second device's report corroborates instead of creating a
            -- duplicate cluster.
            WHERE pr.status IN ('active', 'candidate')
              AND pr.segment_id = bc.segment_id
              AND pr.last_confirmed_at >= bc.recorded_at - INTERVAL '90 days'
              AND ST_DWithin(pr.geom::geography, bc.location::geography, 15)
            ORDER BY pr.geom::geography <-> bc.location::geography
            LIMIT 1
        ) pr ON TRUE
    ),
    -- B165 delta: one reporter mark per (pothole, device); only marks that
    -- actually insert count toward unique_reporters.
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
            -- B165 delta: was pr.unique_reporters + agg.reporter_count, where
            -- reporter_count was the per-batch COUNT(DISTINCT) — N batches
            -- from one device inflated unique_reporters by N.
            unique_reporters = pr.unique_reporters + COALESCE(nmc.reporter_count, 0),
            magnitude = GREATEST(pr.magnitude, agg.max_magnitude),
            -- B165 delta: candidates promote at >= 2 distinct reporters;
            -- active rows are never demoted here (grandfathering).
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
            ST_ClusterDBSCAN(ST_Transform(me.location, 3857), eps := 15, minpoints := 1)
                OVER (PARTITION BY me.segment_id) AS cluster_id
        FROM matched_existing me
        WHERE me.pothole_id IS NULL
    ),
    -- B165 delta: pre-assign ids per cluster so reporter marks can be written
    -- for the freshly inserted rows in this same statement.
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
            -- B165 delta: was unconditionally 'active'. Single-device
            -- clusters now hold in the non-public candidate state.
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
    -- B165 delta: reporter marks for the new clusters (RI check runs at end
    -- of statement, after the inserted_potholes CTE's rows exist).
    INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
    SELECT DISTINCT nc.pothole_id, u.device_token_hash
    FROM unmatched u
    JOIN new_clusters nc
      ON nc.segment_id = u.segment_id
     AND nc.cluster_id IS NOT DISTINCT FROM u.cluster_id
    ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
END;
$$;

-- Redefinition of the 20260425221500 10-arg body. Deltas, all commented:
-- 1. manual_report target search also matches `candidate` so a second device
--    corroborates the existing candidate instead of creating a duplicate.
-- 2. Brand-new manual potholes insert as `candidate` (was `active`) and write
--    the creator's reporter mark.
-- 3. The pothole_actions-based v_seen_device_before dedupe is replaced by a
--    reporter-mark insert: unique_reporters increments only for genuinely-new
--    devices across BOTH the manual and sensor paths (previously a device that
--    had contributed via sensor folding was recounted on its first manual
--    action).
-- 4. Positive actions set status via the corroboration rule (active stays
--    active; otherwise >= 2 distinct reporters promotes, else candidate)
--    instead of unconditionally 'active'. Note the one deliberate behavior
--    change beyond promotion: a resolved/expired pothole re-reported by a
--    single identity now re-enters as `candidate` rather than republishing
--    immediately; a corroborated one (unique_reporters >= 2) still
--    reactivates to `active` exactly as before.
-- The sensor-backed validation, idempotent action replay, 24h same-device
-- dedupe, stale-target rejection, and confirm_fixed two-device quorum are
-- unchanged. The 8-arg SQL wrapper from 20260425221500 still delegates here
-- and is not redefined.
CREATE OR REPLACE FUNCTION apply_pothole_action(
    p_action_id UUID,
    p_device_token_hash BYTEA,
    p_action_type pothole_action_type,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_accuracy_m NUMERIC(5,2),
    p_recorded_at TIMESTAMPTZ,
    p_pothole_report_id UUID,
    p_sensor_backed_magnitude_g NUMERIC(4,2),
    p_sensor_backed_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_geom GEOMETRY(POINT, 4326) := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::GEOMETRY(POINT, 4326);
    v_existing_action pothole_actions%ROWTYPE;
    v_target pothole_reports%ROWTYPE;
    v_target_id UUID;
    v_segment_id UUID;
    -- B165 delta: replaces v_seen_device_before (which only consulted
    -- pothole_actions); TRUE when this device's reporter mark was newly
    -- inserted, i.e. it has never counted toward this pothole via either path.
    v_new_reporter BOOLEAN;
    v_fixed_quorum_count INTEGER;
    v_sensor_magnitude NUMERIC(4,2);
    v_sensor_at TIMESTAMPTZ;
BEGIN
    IF (p_sensor_backed_magnitude_g IS NULL) <> (p_sensor_backed_at IS NULL) THEN
        RAISE EXCEPTION 'sensor_backed_fields_required_together'
            USING ERRCODE = '22023';
    END IF;

    IF p_sensor_backed_magnitude_g IS NOT NULL AND p_action_type <> 'manual_report' THEN
        RAISE EXCEPTION 'sensor_backed_manual_report_only'
            USING ERRCODE = '22023';
    END IF;

    IF p_sensor_backed_magnitude_g IS NOT NULL THEN
        IF p_sensor_backed_magnitude_g <= 0 OR p_sensor_backed_magnitude_g > 8 THEN
            RAISE EXCEPTION 'sensor_backed_magnitude_invalid'
                USING ERRCODE = '22023';
        END IF;

        IF p_sensor_backed_at < p_recorded_at - INTERVAL '20 seconds'
           OR p_sensor_backed_at > p_recorded_at + INTERVAL '5 seconds' THEN
            RAISE EXCEPTION 'sensor_backed_timestamp_out_of_window'
                USING ERRCODE = '22023';
        END IF;

        v_sensor_magnitude := p_sensor_backed_magnitude_g::NUMERIC(4,2);
        v_sensor_at := p_sensor_backed_at;
    END IF;

    SELECT *
    INTO v_existing_action
    FROM pothole_actions
    WHERE action_id = p_action_id;

    IF FOUND THEN
        SELECT *
        INTO v_target
        FROM pothole_reports
        WHERE id = v_existing_action.pothole_report_id;

        RETURN jsonb_build_object(
            'action_id', p_action_id,
            'pothole_report_id', v_existing_action.pothole_report_id,
            'status', COALESCE(v_target.status::TEXT, 'active')
        );
    END IF;

    IF p_action_type IN ('confirm_present', 'confirm_fixed') AND p_pothole_report_id IS NULL THEN
        RAISE EXCEPTION 'pothole_report_id_required'
            USING ERRCODE = '22023';
    END IF;

    IF p_action_type = 'manual_report' THEN
        SELECT *
        INTO v_target
        FROM pothole_reports pr
        -- B165 delta: also match candidates (was IN ('active', 'resolved'))
        -- so a different device's manual report corroborates and promotes.
        WHERE pr.status IN ('active', 'resolved', 'candidate')
          AND pr.last_confirmed_at >= p_recorded_at - INTERVAL '90 days'
          AND ST_DWithin(pr.geom::geography, v_geom::geography, 15)
        ORDER BY pr.geom::geography <-> v_geom::geography
        LIMIT 1;
    ELSE
        SELECT *
        INTO v_target
        FROM pothole_reports
        WHERE id = p_pothole_report_id;

        IF NOT FOUND OR NOT ST_DWithin(v_target.geom::geography, v_geom::geography, 30) THEN
            RAISE EXCEPTION 'stale_target'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF v_target.id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM pothole_actions pa
            WHERE pa.pothole_report_id = v_target.id
              AND pa.device_token_hash = p_device_token_hash
              AND pa.action_type = p_action_type
              AND pa.recorded_at >= p_recorded_at - INTERVAL '24 hours'
        ) THEN
            RETURN jsonb_build_object(
                'action_id', p_action_id,
                'pothole_report_id', v_target.id,
                'status', v_target.status::TEXT
            );
        END IF;
    END IF;

    IF v_target.id IS NULL THEN
        SELECT rs.id
        INTO v_segment_id
        FROM road_segments rs
        WHERE ST_DWithin(rs.geom::geography, v_geom::geography, 30)
        ORDER BY rs.geom::geography <-> v_geom::geography
        LIMIT 1;

        INSERT INTO pothole_reports (
            segment_id,
            geom,
            magnitude,
            first_reported_at,
            last_confirmed_at,
            confirmation_count,
            unique_reporters,
            status,
            negative_confirmation_count,
            last_fixed_reported_at
        ) VALUES (
            v_segment_id,
            v_geom,
            COALESCE(v_sensor_magnitude, 1.00)::NUMERIC(4,2),
            p_recorded_at,
            p_recorded_at,
            1,
            1,
            -- B165 delta: was 'active'. One identity's say-so now holds in
            -- the non-public candidate state until a second device
            -- corroborates within 15 m / 90 days.
            'candidate',
            0,
            NULL
        )
        RETURNING *
        INTO v_target;

        -- B165 delta: record the creator's reporter mark.
        INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
        VALUES (v_target.id, p_device_token_hash)
        ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
    ELSE
        v_segment_id := v_target.segment_id;

        -- B165 delta: was SELECT EXISTS(... FROM pothole_actions ...) INTO
        -- v_seen_device_before. The mark insert is the dedupe: FOUND is TRUE
        -- only when the device has never counted toward this pothole.
        INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
        VALUES (v_target.id, p_device_token_hash)
        ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
        v_new_reporter := FOUND;

        IF p_action_type IN ('manual_report', 'confirm_present') THEN
            UPDATE pothole_reports
            SET
                last_confirmed_at = GREATEST(last_confirmed_at, p_recorded_at),
                confirmation_count = confirmation_count + 1,
                unique_reporters = unique_reporters + CASE WHEN v_new_reporter THEN 1 ELSE 0 END,
                magnitude = CASE
                    WHEN v_sensor_magnitude IS NULL THEN magnitude
                    ELSE GREATEST(magnitude, v_sensor_magnitude)
                END,
                -- B165 delta: was unconditionally 'active'. Active rows stay
                -- active (grandfathering, never demoted); candidates and
                -- resolved/expired rows go (back) public only with >= 2
                -- distinct reporters, else they hold as candidate.
                status = CASE
                    WHEN status = 'active' THEN 'active'::pothole_status
                    WHEN unique_reporters + CASE WHEN v_new_reporter THEN 1 ELSE 0 END >= 2
                        THEN 'active'::pothole_status
                    ELSE 'candidate'::pothole_status
                END
            WHERE id = v_target.id
            RETURNING *
            INTO v_target;
        ELSE
            UPDATE pothole_reports
            SET
                negative_confirmation_count = negative_confirmation_count + 1,
                last_fixed_reported_at = GREATEST(COALESCE(last_fixed_reported_at, p_recorded_at), p_recorded_at),
                -- B165 delta: mark-based instead of v_seen_device_before.
                unique_reporters = unique_reporters + CASE WHEN v_new_reporter THEN 1 ELSE 0 END
            WHERE id = v_target.id
            RETURNING *
            INTO v_target;
        END IF;
    END IF;

    v_target_id := v_target.id;

    INSERT INTO pothole_actions (
        action_id,
        device_token_hash,
        pothole_report_id,
        segment_id,
        geom,
        accuracy_m,
        action_type,
        recorded_at,
        sensor_backed_magnitude_g,
        sensor_backed_at
    ) VALUES (
        p_action_id,
        p_device_token_hash,
        v_target_id,
        v_segment_id,
        v_geom,
        p_accuracy_m,
        p_action_type,
        p_recorded_at,
        v_sensor_magnitude,
        v_sensor_at
    );

    IF p_action_type = 'confirm_fixed' THEN
        SELECT COUNT(DISTINCT pa.device_token_hash)::INTEGER
        INTO v_fixed_quorum_count
        FROM pothole_actions pa
        WHERE pa.pothole_report_id = v_target_id
          AND pa.action_type = 'confirm_fixed'
          AND pa.recorded_at > v_target.last_confirmed_at
          AND pa.recorded_at >= now() - INTERVAL '30 days';

        IF v_fixed_quorum_count >= 2 THEN
            UPDATE pothole_reports
            SET status = 'resolved'
            WHERE id = v_target_id
            RETURNING *
            INTO v_target;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'action_id', p_action_id,
        'pothole_report_id', v_target_id,
        'status', v_target.status::TEXT
    );
END;
$$;

-- Redefinition of the 20260418165013 body. Single delta: candidates age out
-- on the same 90-day unconfirmed cycle as active potholes, so an
-- uncorroborated report cannot sit promotable forever (the fold/manual match
-- window already refuses targets whose last_confirmed_at is > 90 days old —
-- this keeps the table tidy and the semantics symmetric).
CREATE OR REPLACE FUNCTION expire_unconfirmed_potholes()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE pothole_reports
    SET status = 'expired'
    WHERE status IN ('active', 'candidate')
      AND last_confirmed_at < now() - INTERVAL '90 days';
END;
$$;
