-- N1 (docs/reviews/2026-10-18-full-codebase-review.md): one request can make
-- a pothole permanent and unresolvable.
--
-- `apply_pothole_action` (latest 10-arg body: 20260612182000_pothole_corroboration_gate.sql)
-- trusted the client's `recorded_at` everywhere: `confirm_present` with
-- recorded_at = 2099-01-01 set last_confirmed_at = 2099, so the pothole
-- never expired (90-day unconfirmed cycle) and could never be resolved
-- (`confirm_fixed` votes only count when recorded_at > last_confirmed_at).
--
-- 2026-11 deltas (everything else is byte-identical to 20260612182000):
-- 1. recorded_at more than 5 minutes in the future, or more than 30 days in
--    the past, is rejected with RAISE EXCEPTION 'recorded_at_out_of_window'
--    USING ERRCODE = '22023' (invalid_parameter_value) -- the same class as
--    the existing sensor_backed_* validation errors. An idempotent replay of
--    an already-stored action_id still returns its stored result first.
-- 2. Every value derived from the client clock is clamped to
--    LEAST(recorded_at, now()), so the up-to-5-minute future tolerance can't
--    push last_confirmed_at / first_reported_at / last_fixed_reported_at or
--    the stored action's recorded_at past the server clock either.
-- 3. accuracy_m is bounded before the NUMERIC(5,2) insert: negative/NaN ->
--    NULL (iOS uses -1 for "invalid fix"), anything >= 1000 m -> 999.99.
--    Function argument typmods are not enforced by Postgres, so an accuracy
--    of 5000 used to overflow the column and surface as a 502.
-- 4. manual_report find-or-create takes the same per-area advisory locks as
--    the sensor fold (pothole_area_lock_keys, 20261108110000) before its
--    target search, so two concurrent first reports of one pothole share a
--    candidate instead of creating two single-reporter candidates.
-- The 8-arg SQL wrapper from 20260425221500 still delegates here.

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
    v_new_reporter BOOLEAN;
    v_fixed_quorum_count INTEGER;
    v_sensor_magnitude NUMERIC(4,2);
    v_sensor_at TIMESTAMPTZ;
    -- 2026-11 deltas.
    v_recorded_at TIMESTAMPTZ;
    v_accuracy_m NUMERIC(5,2);
    v_lock_key INTEGER;
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
        v_sensor_at := LEAST(p_sensor_backed_at, now());
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

    -- 2026-11 delta (N1): bound the client clock.
    IF p_recorded_at IS NULL
       OR p_recorded_at > now() + INTERVAL '5 minutes'
       OR p_recorded_at < now() - INTERVAL '30 days' THEN
        RAISE EXCEPTION 'recorded_at_out_of_window'
            USING ERRCODE = '22023';
    END IF;
    v_recorded_at := LEAST(p_recorded_at, now());

    -- 2026-11 delta: keep accuracy inside NUMERIC(5,2).
    v_accuracy_m := CASE
        WHEN p_accuracy_m IS NULL OR p_accuracy_m = 'NaN'::NUMERIC OR p_accuracy_m < 0 THEN NULL
        ELSE LEAST(p_accuracy_m, 999.99)
    END;

    IF p_action_type IN ('confirm_present', 'confirm_fixed') AND p_pothole_report_id IS NULL THEN
        RAISE EXCEPTION 'pothole_report_id_required'
            USING ERRCODE = '22023';
    END IF;

    IF p_action_type = 'manual_report' THEN
        -- 2026-11 delta: serialise find-or-create per area (sorted keys).
        FOR v_lock_key IN
            SELECT k FROM pothole_area_lock_keys(v_geom) AS k ORDER BY k
        LOOP
            PERFORM pg_advisory_xact_lock(7301, v_lock_key);
        END LOOP;

        SELECT *
        INTO v_target
        FROM pothole_reports pr
        WHERE pr.status IN ('active', 'resolved', 'candidate')
          AND pr.last_confirmed_at >= v_recorded_at - INTERVAL '90 days'
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
              AND pa.recorded_at >= v_recorded_at - INTERVAL '24 hours'
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
            v_recorded_at,
            v_recorded_at,
            1,
            1,
            'candidate',
            0,
            NULL
        )
        RETURNING *
        INTO v_target;

        INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
        VALUES (v_target.id, p_device_token_hash)
        ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
    ELSE
        v_segment_id := v_target.segment_id;

        INSERT INTO pothole_reporter_marks (pothole_id, device_token_hash)
        VALUES (v_target.id, p_device_token_hash)
        ON CONFLICT (pothole_id, device_token_hash) DO NOTHING;
        v_new_reporter := FOUND;

        IF p_action_type IN ('manual_report', 'confirm_present') THEN
            UPDATE pothole_reports
            SET
                last_confirmed_at = GREATEST(last_confirmed_at, v_recorded_at),
                confirmation_count = confirmation_count + 1,
                unique_reporters = unique_reporters + CASE WHEN v_new_reporter THEN 1 ELSE 0 END,
                magnitude = CASE
                    WHEN v_sensor_magnitude IS NULL THEN magnitude
                    ELSE GREATEST(magnitude, v_sensor_magnitude)
                END,
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
                last_fixed_reported_at = GREATEST(COALESCE(last_fixed_reported_at, v_recorded_at), v_recorded_at),
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
        v_accuracy_m,
        p_action_type,
        v_recorded_at,
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

-- One-off repair for rows already poisoned by N1: no legitimate client clock
-- is more than a few minutes ahead, so any stored future value is clamped to
-- now(). Idempotent.
UPDATE pothole_reports
SET last_confirmed_at = now()
WHERE last_confirmed_at > now() + INTERVAL '5 minutes';

UPDATE pothole_reports
SET first_reported_at = LEAST(first_reported_at, last_confirmed_at)
WHERE first_reported_at > last_confirmed_at;

UPDATE pothole_reports
SET last_fixed_reported_at = now()
WHERE last_fixed_reported_at > now() + INTERVAL '5 minutes';

UPDATE pothole_actions
SET recorded_at = created_at
WHERE recorded_at > created_at + INTERVAL '5 minutes';
