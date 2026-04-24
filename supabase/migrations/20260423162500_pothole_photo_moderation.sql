ALTER TABLE pothole_reports
    ADD COLUMN IF NOT EXISTS has_photo BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION approve_pothole_photo(
    p_report_id UUID,
    p_reviewed_by TEXT,
    p_storage_object_path TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_photo pothole_photos%ROWTYPE;
    v_target pothole_reports%ROWTYPE;
    v_segment_id UUID;
    v_seen_device_before BOOLEAN;
    v_reviewed_by TEXT := COALESCE(NULLIF(BTRIM(p_reviewed_by), ''), 'moderator');
    v_effective_storage_path TEXT;
BEGIN
    SELECT *
    INTO v_photo
    FROM pothole_photos
    WHERE report_id = p_report_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'photo_not_found'
            USING ERRCODE = 'P0002';
    END IF;

    v_effective_storage_path := COALESCE(NULLIF(BTRIM(p_storage_object_path), ''), v_photo.storage_object_path);

    IF v_photo.status = 'approved' THEN
        RETURN jsonb_build_object(
            'report_id', v_photo.report_id,
            'pothole_report_id', v_photo.pothole_report_id,
            'status', v_photo.status::TEXT,
            'storage_object_path', v_effective_storage_path
        );
    END IF;

    IF v_photo.status <> 'pending_moderation' THEN
        RAISE EXCEPTION 'invalid_photo_state'
            USING ERRCODE = 'P0001';
    END IF;

    v_segment_id := v_photo.segment_id;
    IF v_segment_id IS NULL THEN
        SELECT rs.id
        INTO v_segment_id
        FROM road_segments rs
        WHERE ST_DWithin(rs.geom::geography, v_photo.geom::geography, 30)
        ORDER BY rs.geom::geography <-> v_photo.geom::geography
        LIMIT 1;
    END IF;

    SELECT *
    INTO v_target
    FROM pothole_reports pr
    WHERE pr.last_confirmed_at >= v_photo.captured_at - INTERVAL '90 days'
      AND ST_DWithin(pr.geom::geography, v_photo.geom::geography, 15)
    ORDER BY pr.geom::geography <-> v_photo.geom::geography
    LIMIT 1;

    IF v_target.id IS NULL THEN
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
            last_fixed_reported_at,
            has_photo
        ) VALUES (
            v_segment_id,
            v_photo.geom,
            1.00,
            v_photo.captured_at,
            v_photo.captured_at,
            1,
            1,
            'active',
            0,
            NULL,
            true
        )
        RETURNING *
        INTO v_target;
    ELSE
        SELECT EXISTS(
            SELECT 1
            FROM pothole_actions pa
            WHERE pa.pothole_report_id = v_target.id
              AND pa.device_token_hash = v_photo.device_token_hash
            UNION ALL
            SELECT 1
            FROM pothole_photos pp
            WHERE pp.pothole_report_id = v_target.id
              AND pp.report_id <> v_photo.report_id
              AND pp.device_token_hash = v_photo.device_token_hash
              AND pp.status = 'approved'
        )
        INTO v_seen_device_before;

        UPDATE pothole_reports
        SET
            segment_id = COALESCE(pothole_reports.segment_id, v_segment_id),
            last_confirmed_at = GREATEST(pothole_reports.last_confirmed_at, v_photo.captured_at),
            confirmation_count = pothole_reports.confirmation_count + 1,
            unique_reporters = pothole_reports.unique_reporters + CASE WHEN v_seen_device_before THEN 0 ELSE 1 END,
            status = 'active',
            has_photo = true
        WHERE id = v_target.id
        RETURNING *
        INTO v_target;
    END IF;

    UPDATE pothole_photos
    SET
        segment_id = COALESCE(pothole_photos.segment_id, v_segment_id),
        pothole_report_id = v_target.id,
        status = 'approved',
        reviewed_at = now(),
        reviewed_by = v_reviewed_by,
        rejection_reason = NULL,
        storage_object_path = v_effective_storage_path
    WHERE report_id = p_report_id
    RETURNING *
    INTO v_photo;

    RETURN jsonb_build_object(
        'report_id', v_photo.report_id,
        'pothole_report_id', v_target.id,
        'status', v_photo.status::TEXT,
        'storage_object_path', v_photo.storage_object_path
    );
END;
$$;

CREATE OR REPLACE FUNCTION reject_pothole_photo(
    p_report_id UUID,
    p_reviewed_by TEXT,
    p_rejection_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_photo pothole_photos%ROWTYPE;
    v_reviewed_by TEXT := COALESCE(NULLIF(BTRIM(p_reviewed_by), ''), 'moderator');
BEGIN
    SELECT *
    INTO v_photo
    FROM pothole_photos
    WHERE report_id = p_report_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'photo_not_found'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_photo.status = 'rejected' THEN
        RETURN jsonb_build_object(
            'report_id', v_photo.report_id,
            'status', v_photo.status::TEXT,
            'storage_object_path', v_photo.storage_object_path
        );
    END IF;

    IF v_photo.status <> 'pending_moderation' THEN
        RAISE EXCEPTION 'invalid_photo_state'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE pothole_photos
    SET
        status = 'rejected',
        reviewed_at = now(),
        reviewed_by = v_reviewed_by,
        rejection_reason = NULLIF(BTRIM(p_rejection_reason), '')
    WHERE report_id = p_report_id
    RETURNING *
    INTO v_photo;

    RETURN jsonb_build_object(
        'report_id', v_photo.report_id,
        'status', v_photo.status::TEXT,
        'storage_object_path', v_photo.storage_object_path
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION approve_pothole_photo(UUID, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION reject_pothole_photo(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION approve_pothole_photo(UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION reject_pothole_photo(UUID, TEXT, TEXT) TO service_role;

CREATE OR REPLACE VIEW moderation_pothole_photo_queue AS
SELECT
    pp.report_id,
    pp.submitted_at,
    pp.uploaded_at,
    pp.captured_at,
    pp.storage_object_path,
    pp.byte_size,
    pp.content_type,
    ST_Y(pp.geom) AS lat,
    ST_X(pp.geom) AS lng,
    pp.accuracy_m,
    pp.segment_id,
    rs.road_name,
    rs.municipality,
    pp.pothole_report_id
FROM pothole_photos pp
LEFT JOIN road_segments rs
  ON rs.id = pp.segment_id
WHERE pp.status = 'pending_moderation'
ORDER BY pp.submitted_at ASC;

GRANT SELECT ON moderation_pothole_photo_queue TO service_role;
