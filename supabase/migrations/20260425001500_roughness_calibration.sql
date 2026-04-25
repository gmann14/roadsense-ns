CREATE OR REPLACE FUNCTION roughness_category_for_score(p_score DOUBLE PRECISION)
RETURNS roughness_category
LANGUAGE sql
IMMUTABLE
RETURNS NULL ON NULL INPUT
AS $$
    SELECT CASE
        WHEN p_score < 0.05 THEN 'smooth'::roughness_category
        WHEN p_score < 0.09 THEN 'fair'::roughness_category
        WHEN p_score < 0.14 THEN 'rough'::roughness_category
        ELSE 'very_rough'::roughness_category
    END
$$;

CREATE OR REPLACE FUNCTION update_segment_aggregates_from_batch(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
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
        COUNT(DISTINCT r.device_token_hash)::INTEGER,
        MAX(r.recorded_at),
        COUNT(*) FILTER (WHERE r.is_pothole)::INTEGER,
        'low'::confidence_level,
        'unscored'::roughness_category
    FROM readings r
    WHERE r.batch_id = p_batch_id
      AND r.segment_id IS NOT NULL
    GROUP BY r.segment_id
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
    );
END;
$$;

CREATE OR REPLACE FUNCTION nightly_recompute_aggregates(
    p_segment_ids UUID[] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    WITH target_segments AS (
        SELECT DISTINCT r.segment_id
        FROM readings r
        WHERE p_segment_ids IS NULL
          AND r.uploaded_at > now() - INTERVAL '24 hours'
          AND r.segment_id IS NOT NULL
        UNION
        SELECT DISTINCT unnest(p_segment_ids)
        WHERE p_segment_ids IS NOT NULL
    ),
    per_device_capped AS (
        SELECT
            r.segment_id,
            r.roughness_rms,
            r.is_pothole,
            r.recorded_at,
            r.device_token_hash,
            ROW_NUMBER() OVER (
                PARTITION BY r.segment_id, r.device_token_hash, date_trunc('week', r.recorded_at)
                ORDER BY r.recorded_at DESC
            ) AS rn
        FROM readings r
        WHERE r.segment_id IN (SELECT segment_id FROM target_segments)
          AND r.recorded_at > now() - INTERVAL '6 months'
    ),
    filtered AS (
        SELECT *
        FROM per_device_capped
        WHERE rn <= 3
    ),
    segment_bounds AS (
        SELECT
            f.segment_id,
            PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY f.roughness_rms) AS p10,
            PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY f.roughness_rms) AS p90,
            COUNT(*) AS n
        FROM filtered f
        GROUP BY f.segment_id
    ),
    trimmed AS (
        SELECT
            f.segment_id,
            f.roughness_rms,
            f.is_pothole,
            f.recorded_at,
            f.device_token_hash
        FROM filtered f
        JOIN segment_bounds b ON b.segment_id = f.segment_id
        WHERE b.n < 10
           OR f.roughness_rms BETWEEN b.p10 AND b.p90
    ),
    recency_weighted AS (
        SELECT
            t.segment_id,
            SUM(t.roughness_rms * EXP(-EXTRACT(EPOCH FROM (now() - t.recorded_at)) / (86400 * 90)))
                / NULLIF(SUM(EXP(-EXTRACT(EPOCH FROM (now() - t.recorded_at)) / (86400 * 90))), 0) AS avg_score,
            COUNT(*)::INTEGER AS reading_count,
            COUNT(DISTINCT t.device_token_hash)::INTEGER AS contributor_count,
            COUNT(*) FILTER (WHERE t.is_pothole)::INTEGER AS pothole_count,
            MAX(t.recorded_at) AS last_at,
            AVG(t.roughness_rms) FILTER (WHERE t.recorded_at > now() - INTERVAL '30 days') AS avg_30d,
            AVG(t.roughness_rms) FILTER (
                WHERE t.recorded_at BETWEEN now() - INTERVAL '60 days' AND now() - INTERVAL '30 days'
            ) AS avg_30_60d
        FROM trimmed t
        GROUP BY t.segment_id
    )
    INSERT INTO segment_aggregates (
        segment_id,
        avg_roughness_score,
        total_readings,
        unique_contributors,
        last_reading_at,
        pothole_count,
        score_last_30d,
        score_30_60d,
        trend,
        confidence,
        roughness_category,
        updated_at
    )
    SELECT
        r.segment_id,
        r.avg_score::NUMERIC(5,3),
        r.reading_count,
        r.contributor_count,
        r.last_at,
        r.pothole_count,
        r.avg_30d::NUMERIC(5,3),
        r.avg_30_60d::NUMERIC(5,3),
        CASE
            WHEN r.avg_30d IS NULL OR r.avg_30_60d IS NULL THEN 'stable'
            WHEN r.avg_30d > r.avg_30_60d * 1.1 THEN 'worsening'
            WHEN r.avg_30d < r.avg_30_60d * 0.9 THEN 'improving'
            ELSE 'stable'
        END::trend_direction,
        CASE
            WHEN r.contributor_count >= 10 THEN 'high'
            WHEN r.contributor_count >= 3 THEN 'medium'
            ELSE 'low'
        END::confidence_level,
        roughness_category_for_score(r.avg_score),
        now()
    FROM recency_weighted r
    ON CONFLICT (segment_id) DO UPDATE SET
        avg_roughness_score = EXCLUDED.avg_roughness_score,
        total_readings = EXCLUDED.total_readings,
        unique_contributors = EXCLUDED.unique_contributors,
        last_reading_at = EXCLUDED.last_reading_at,
        pothole_count = EXCLUDED.pothole_count,
        score_last_30d = EXCLUDED.score_last_30d,
        score_30_60d = EXCLUDED.score_30_60d,
        trend = EXCLUDED.trend,
        confidence = EXCLUDED.confidence,
        roughness_category = EXCLUDED.roughness_category,
        updated_at = now();
END;
$$;
