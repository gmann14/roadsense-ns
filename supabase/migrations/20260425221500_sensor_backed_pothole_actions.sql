ALTER TABLE pothole_actions
    ADD COLUMN IF NOT EXISTS sensor_backed_magnitude_g NUMERIC(4,2),
    ADD COLUMN IF NOT EXISTS sensor_backed_at TIMESTAMPTZ;

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
    v_seen_device_before BOOLEAN;
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
        WHERE pr.status IN ('active', 'resolved')
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
            'active',
            0,
            NULL
        )
        RETURNING *
        INTO v_target;
    ELSE
        v_segment_id := v_target.segment_id;
        SELECT EXISTS(
            SELECT 1
            FROM pothole_actions pa
            WHERE pa.pothole_report_id = v_target.id
              AND pa.device_token_hash = p_device_token_hash
        )
        INTO v_seen_device_before;

        IF p_action_type IN ('manual_report', 'confirm_present') THEN
            UPDATE pothole_reports
            SET
                last_confirmed_at = GREATEST(last_confirmed_at, p_recorded_at),
                confirmation_count = confirmation_count + 1,
                unique_reporters = unique_reporters + CASE WHEN v_seen_device_before THEN 0 ELSE 1 END,
                magnitude = CASE
                    WHEN v_sensor_magnitude IS NULL THEN magnitude
                    ELSE GREATEST(magnitude, v_sensor_magnitude)
                END,
                status = 'active'
            WHERE id = v_target.id
            RETURNING *
            INTO v_target;
        ELSE
            UPDATE pothole_reports
            SET
                negative_confirmation_count = negative_confirmation_count + 1,
                last_fixed_reported_at = GREATEST(COALESCE(last_fixed_reported_at, p_recorded_at), p_recorded_at),
                unique_reporters = unique_reporters + CASE WHEN v_seen_device_before THEN 0 ELSE 1 END
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

CREATE OR REPLACE FUNCTION apply_pothole_action(
    p_action_id UUID,
    p_device_token_hash BYTEA,
    p_action_type pothole_action_type,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_accuracy_m NUMERIC(5,2),
    p_recorded_at TIMESTAMPTZ,
    p_pothole_report_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
SET search_path = pg_catalog, public
AS $$
    SELECT apply_pothole_action(
        p_action_id,
        p_device_token_hash,
        p_action_type,
        p_lat,
        p_lng,
        p_accuracy_m,
        p_recorded_at,
        p_pothole_report_id,
        NULL::NUMERIC(4,2),
        NULL::TIMESTAMPTZ
    );
$$;

REVOKE EXECUTE ON FUNCTION apply_pothole_action(UUID, BYTEA, pothole_action_type, DOUBLE PRECISION, DOUBLE PRECISION, NUMERIC, TIMESTAMPTZ, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_pothole_action(UUID, BYTEA, pothole_action_type, DOUBLE PRECISION, DOUBLE PRECISION, NUMERIC, TIMESTAMPTZ, UUID, NUMERIC, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_pothole_action(UUID, BYTEA, pothole_action_type, DOUBLE PRECISION, DOUBLE PRECISION, NUMERIC, TIMESTAMPTZ, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION apply_pothole_action(UUID, BYTEA, pothole_action_type, DOUBLE PRECISION, DOUBLE PRECISION, NUMERIC, TIMESTAMPTZ, UUID, NUMERIC, TIMESTAMPTZ) TO service_role;
