-- Cycling-speed motion can look like pothole impact data, especially on rough
-- paved shoulders. Keep low-speed readings available for road scoring, but
-- require driving-speed evidence before a sensor-only pothole becomes public.
--
-- This also removes the known 2026-05-05 evening bike ride from public
-- aggregates and lowers pothole vector tiles to z8 so regional pothole mode
-- shows South Shore reports without requiring a deep zoom.

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
            COALESCE(r.pothole_magnitude, r.roughness_rms)::NUMERIC(4,2) AS magnitude,
            r.recorded_at,
            r.device_token_hash
        FROM readings r
        WHERE r.batch_id = p_batch_id
          AND r.is_pothole = TRUE
          AND r.speed_kmh >= 45
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
            WHERE pr.status = 'active'
              AND pr.segment_id = bc.segment_id
              AND pr.last_confirmed_at >= bc.recorded_at - INTERVAL '90 days'
              AND ST_DWithin(pr.geom::geography, bc.location::geography, 15)
            ORDER BY pr.geom::geography <-> bc.location::geography
            LIMIT 1
        ) pr ON TRUE
    ),
    update_existing AS (
        UPDATE pothole_reports pr
        SET
            last_confirmed_at = GREATEST(pr.last_confirmed_at, agg.last_at),
            confirmation_count = pr.confirmation_count + agg.hit_count,
            unique_reporters = pr.unique_reporters + agg.reporter_count,
            magnitude = GREATEST(pr.magnitude, agg.max_magnitude)
        FROM (
            SELECT
                pothole_id,
                COUNT(*)::INTEGER AS hit_count,
                COUNT(DISTINCT device_token_hash)::INTEGER AS reporter_count,
                MAX(recorded_at) AS last_at,
                MAX(magnitude) AS max_magnitude
            FROM matched_existing
            WHERE pothole_id IS NOT NULL
            GROUP BY pothole_id
        ) agg
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
    )
    INSERT INTO pothole_reports (
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
        u.segment_id,
        ST_Centroid(ST_Collect(u.location))::GEOMETRY(POINT, 4326) AS geom,
        MAX(u.magnitude)::NUMERIC(4,2) AS magnitude,
        MIN(u.recorded_at) AS first_reported_at,
        MAX(u.recorded_at) AS last_confirmed_at,
        COUNT(*)::INTEGER AS confirmation_count,
        COUNT(DISTINCT u.device_token_hash)::INTEGER AS unique_reporters,
        'active'::pothole_status
    FROM unmatched u
    GROUP BY u.segment_id, u.cluster_id;
END;
$$;

CREATE OR REPLACE FUNCTION get_tile(z INT, x INT, y INT)
RETURNS BYTEA
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_tile BYTEA;
BEGIN
    IF z < 6 THEN
        RETURN ''::BYTEA;
    END IF;

    WITH bounds AS (
        SELECT
            ST_TileEnvelope(z, x, y) AS geom_3857,
            ST_Transform(ST_TileEnvelope(z, x, y), 4326) AS geom_4326
    ),
    segments AS (
        SELECT
            rs.id,
            rs.road_name,
            rs.road_type,
            sa.avg_roughness_score AS roughness_score,
            sa.roughness_category::TEXT AS category,
            sa.confidence::TEXT AS confidence,
            sa.total_readings,
            sa.unique_contributors,
            sa.pothole_count,
            ST_AsMVTGeom(
                ST_Transform(rs.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN road_segments rs
          ON rs.geom && b.geom_4326
        JOIN segment_aggregates sa
          ON sa.segment_id = rs.id
        WHERE ST_Intersects(ST_Transform(rs.geom, 3857), b.geom_3857)
          AND rs.is_parking_aisle = FALSE
          AND sa.total_readings > 0
          AND CASE
              WHEN z < 12 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link'
              )
              WHEN z < 14 THEN rs.road_type IN (
                  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
                  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link'
              )
              ELSE TRUE
          END
    ),
    potholes AS (
        SELECT
            pr.id,
            pr.magnitude,
            pr.confirmation_count,
            ST_AsMVTGeom(
                ST_Transform(pr.geom, 3857),
                b.geom_3857,
                4096,
                64,
                TRUE
            ) AS geom
        FROM bounds b
        JOIN pothole_reports pr
          ON pr.geom && b.geom_4326
        WHERE pr.status = 'active'
          AND z >= 8
          AND ST_Intersects(ST_Transform(pr.geom, 3857), b.geom_3857)
    )
    SELECT
        COALESCE(
            (
                SELECT ST_AsMVT(segment_rows.*, 'segment_aggregates', 4096, 'geom')
                FROM segments AS segment_rows
            ),
            ''::BYTEA
        ) ||
        COALESCE(
            (
                SELECT ST_AsMVT(pothole_rows.*, 'potholes', 4096, 'geom')
                FROM potholes AS pothole_rows
            ),
            ''::BYTEA
        )
    INTO v_tile;

    RETURN COALESCE(v_tile, ''::BYTEA);
END;
$$;

DO $cleanup$
DECLARE
    v_affected_segments UUID[];
    v_expired_potholes INTEGER := 0;
    v_deleted_readings INTEGER := 0;
BEGIN
    CREATE TEMP TABLE tmp_bike_batches ON COMMIT DROP AS
    SELECT r.batch_id
    FROM readings r
    WHERE r.recorded_at >= TIMESTAMPTZ '2026-05-05T21:00:00Z'
      AND r.recorded_at < TIMESTAMPTZ '2026-05-05T23:00:00Z'
    GROUP BY r.batch_id
    HAVING COUNT(*) FILTER (WHERE r.is_pothole) > 0
       AND MAX(r.speed_kmh) < 45;

    CREATE TEMP TABLE tmp_bike_segments ON COMMIT DROP AS
    SELECT DISTINCT r.segment_id
    FROM readings r
    JOIN tmp_bike_batches b ON b.batch_id = r.batch_id
    WHERE r.segment_id IS NOT NULL;

    CREATE TEMP TABLE tmp_bike_potholes ON COMMIT DROP AS
    WITH support AS (
        SELECT
            pr.id,
            MAX(r.speed_kmh) AS max_speed,
            COUNT(DISTINCT pa.action_id) AS action_count,
            COUNT(DISTINCT pp.id) AS photo_count
        FROM pothole_reports pr
        LEFT JOIN readings r ON r.is_pothole = TRUE
          AND r.recorded_at BETWEEN pr.first_reported_at - INTERVAL '5 minutes'
                                AND pr.last_confirmed_at + INTERVAL '5 minutes'
          AND ST_DWithin(r.location::geography, pr.geom::geography, 20)
        LEFT JOIN pothole_actions pa ON pa.pothole_report_id = pr.id
        LEFT JOIN pothole_photos pp ON pp.pothole_report_id = pr.id
        WHERE pr.status = 'active'
          AND pr.first_reported_at >= TIMESTAMPTZ '2026-05-05T21:00:00Z'
          AND pr.first_reported_at < TIMESTAMPTZ '2026-05-05T23:00:00Z'
        GROUP BY pr.id
    )
    SELECT id
    FROM support
    WHERE action_count = 0
      AND photo_count = 0
      AND max_speed < 45;

    UPDATE pothole_reports
    SET status = 'expired'
    WHERE id IN (SELECT id FROM tmp_bike_potholes);
    GET DIAGNOSTICS v_expired_potholes = ROW_COUNT;

    DELETE FROM readings r
    USING tmp_bike_batches b
    WHERE r.batch_id = b.batch_id;
    GET DIAGNOSTICS v_deleted_readings = ROW_COUNT;

    SELECT array_agg(segment_id)
    INTO v_affected_segments
    FROM tmp_bike_segments;

    IF v_affected_segments IS NOT NULL THEN
        DELETE FROM segment_aggregates
        WHERE segment_id = ANY(v_affected_segments);

        PERFORM nightly_recompute_aggregates(v_affected_segments);
    END IF;

    REFRESH MATERIALIZED VIEW public_stats_mv;

    RAISE NOTICE 'Expired % bike potholes and deleted % bike readings',
        v_expired_potholes,
        v_deleted_readings;
END;
$cleanup$;
