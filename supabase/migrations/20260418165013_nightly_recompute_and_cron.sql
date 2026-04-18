CREATE OR REPLACE FUNCTION create_next_readings_partition()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_next_month DATE := date_trunc('month', now() + INTERVAL '1 month')::DATE;
    v_following DATE := (v_next_month + INTERVAL '1 month')::DATE;
    v_part_name TEXT := format('readings_%s', to_char(v_next_month, 'YYYY_MM'));
BEGIN
    EXECUTE format(
        $f$CREATE TABLE IF NOT EXISTS %I PARTITION OF readings FOR VALUES FROM (%L) TO (%L)$f$,
        v_part_name,
        v_next_month,
        v_following
    );

    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (location)$f$,
        v_part_name || '_location_gist',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON %I (segment_id)$f$,
        v_part_name || '_segment',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON %I (batch_id)$f$,
        v_part_name || '_batch',
        v_part_name
    );
    EXECUTE format(
        $f$CREATE INDEX IF NOT EXISTS %I ON %I (device_token_hash)$f$,
        v_part_name || '_device',
        v_part_name
    );
END;
$$;

CREATE OR REPLACE FUNCTION drop_old_readings_partitions()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_cutoff DATE := date_trunc('month', now() - INTERVAL '6 months')::DATE;
    v_part RECORD;
    v_upper DATE;
BEGIN
    FOR v_part IN
        SELECT
            inhrelid::regclass AS part_name,
            pg_get_expr(relpartbound, inhrelid) AS bound
        FROM pg_inherits
        JOIN pg_class ON pg_class.oid = inhrelid
        WHERE inhparent = 'readings'::regclass
    LOOP
        v_upper := NULLIF(
            substring(v_part.bound FROM $re$TO \('(\d{4}-\d{2}-\d{2})'\)$re$),
            ''
        )::DATE;

        IF v_upper IS NOT NULL AND v_upper <= v_cutoff THEN
            EXECUTE format('DROP TABLE IF EXISTS %s', v_part.part_name);
        END IF;
    END LOOP;
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
        CASE
            WHEN r.avg_score < 0.3 THEN 'smooth'
            WHEN r.avg_score < 0.6 THEN 'fair'
            WHEN r.avg_score < 1.0 THEN 'rough'
            ELSE 'very_rough'
        END::roughness_category,
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

CREATE OR REPLACE FUNCTION expire_unconfirmed_potholes()
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE pothole_reports
    SET status = 'expired'
    WHERE status = 'active'
      AND last_confirmed_at < now() - INTERVAL '90 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION create_next_readings_partition() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_next_readings_partition() FROM anon;
REVOKE EXECUTE ON FUNCTION create_next_readings_partition() FROM authenticated;
GRANT EXECUTE ON FUNCTION create_next_readings_partition() TO service_role;

REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM anon;
REVOKE EXECUTE ON FUNCTION drop_old_readings_partitions() FROM authenticated;
GRANT EXECUTE ON FUNCTION drop_old_readings_partitions() TO service_role;

REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM anon;
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) TO service_role;

REVOKE EXECUTE ON FUNCTION expire_unconfirmed_potholes() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION expire_unconfirmed_potholes() FROM anon;
REVOKE EXECUTE ON FUNCTION expire_unconfirmed_potholes() FROM authenticated;
GRANT EXECUTE ON FUNCTION expire_unconfirmed_potholes() TO service_role;

DO $jobs$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'create-next-readings-partition';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'create-next-readings-partition',
        '0 3 25 * *',
        $cmd$SELECT create_next_readings_partition()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'drop-old-readings-partitions';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'drop-old-readings-partitions',
        '30 3 1 * *',
        $cmd$SELECT drop_old_readings_partitions()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'nightly-aggregate-recompute';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'nightly-aggregate-recompute',
        '15 3 * * *',
        $cmd$SELECT nightly_recompute_aggregates()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'pothole-expiry';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'pothole-expiry',
        '0 4 * * *',
        $cmd$SELECT expire_unconfirmed_potholes()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'rate-limit-gc';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'rate-limit-gc',
        '15 4 * * *',
        $cmd$DELETE FROM rate_limits WHERE bucket_start < now() - INTERVAL '7 days'$cmd$
    );
END;
$jobs$;
