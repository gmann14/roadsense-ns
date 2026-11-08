-- Nightly recompute correctness (docs/reviews/2026-10-18-full-codebase-review.md,
-- "still open from July"):
--
-- The full-run target set of nightly_recompute_aggregates (latest body:
-- 20260612180000_exact_contributor_dedupe.sql) was "segments with readings
-- uploaded in the last 24 hours". Two consequences:
--   - after more than a day of scheduler downtime, the uploads in between
--     were never recomputed (no watermark);
--   - a segment nobody had driven recently was never recomputed again, so a
--     score built on readings that had since aged out of the 6-month window
--     (or been deleted by retention) stayed public forever.
--
-- 2026-11 deltas (aggregate math is byte-identical to 20260612180000):
-- 1. Watermark: the full run targets readings uploaded since the previous
--    full run started (`aggregate_recompute_state`), never less than the old
--    24 h window.
-- 2. Aged-out readings: segments with readings that crossed the 6-month
--    retention edge since the previous run, and segments whose aggregate's
--    newest reading is already outside the window, are recomputed too.
-- 3. A target segment left with no retained readings has its aggregate (and
--    its contributor marks) deleted instead of keeping a stale public score.
--    This applies to explicit p_segment_ids calls as well (purge, refresh
--    finalize, the bike cleanup pattern).
-- 4. The UPSERT and marks insert run in segment_id order (deadlock fix,
--    same as update_segment_aggregates_from_readings).
-- 5. Targets are limited to segments that still exist in road_segments, so
--    readings orphaned by a segment refresh (before the rematch) cannot
--    abort the run on segment_aggregates' foreign key.

CREATE TABLE IF NOT EXISTS aggregate_recompute_state (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    last_full_run_started_at TIMESTAMPTZ NOT NULL
);

ALTER TABLE aggregate_recompute_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON aggregate_recompute_state FROM anon;
REVOKE ALL ON aggregate_recompute_state FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON aggregate_recompute_state TO service_role;

CREATE OR REPLACE FUNCTION nightly_recompute_aggregates(
    p_segment_ids UUID[] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
    v_retention_edge TIMESTAMPTZ := now() - INTERVAL '6 months';
    v_watermark TIMESTAMPTZ;
    v_targets UUID[];
    v_cleared UUID[];
BEGIN
    IF p_segment_ids IS NULL THEN
        SELECT last_full_run_started_at
        INTO v_watermark
        FROM aggregate_recompute_state
        WHERE singleton;

        -- Never look back less than the original fixed 24 h window; a
        -- missing or stale watermark simply widens the window.
        v_watermark := LEAST(
            COALESCE(v_watermark, v_now - INTERVAL '24 hours'),
            v_now - INTERVAL '24 hours'
        );

        SELECT COALESCE(array_agg(DISTINCT s.segment_id ORDER BY s.segment_id), ARRAY[]::UUID[])
        INTO v_targets
        FROM (
            SELECT r.segment_id
            FROM readings r
            WHERE r.uploaded_at > v_watermark
              AND r.segment_id IS NOT NULL
            UNION
            SELECT r.segment_id
            FROM readings r
            WHERE r.recorded_at > v_watermark - INTERVAL '6 months'
              AND r.recorded_at <= v_retention_edge
              AND r.segment_id IS NOT NULL
            UNION
            SELECT sa.segment_id
            FROM segment_aggregates sa
            WHERE sa.last_reading_at IS NOT NULL
              AND sa.last_reading_at <= v_retention_edge
        ) s
        -- readings.segment_id has no FK (partitioned table): a reading can
        -- still point at a segment a refresh deleted until the rematch runs.
        -- Upserting an aggregate for it would violate segment_aggregates' FK
        -- and abort the whole run.
        WHERE EXISTS (SELECT 1 FROM road_segments rs WHERE rs.id = s.segment_id);
    ELSE
        SELECT COALESCE(array_agg(DISTINCT sid ORDER BY sid), ARRAY[]::UUID[])
        INTO v_targets
        FROM unnest(p_segment_ids) AS sid
        WHERE sid IS NOT NULL
          AND EXISTS (SELECT 1 FROM road_segments rs WHERE rs.id = sid);
    END IF;

    IF cardinality(v_targets) > 0 THEN
        WITH target_segments AS (
            SELECT unnest(v_targets) AS segment_id
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
              AND r.recorded_at > v_retention_edge
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
        -- 2026-11 delta: deterministic lock order.
        ORDER BY r.segment_id
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

        -- 2026-11 delta: a target segment with no retained readings has
        -- nothing left to publish. Delete its aggregate rather than keep a
        -- score derived from readings that no longer exist.
        WITH cleared AS (
            DELETE FROM segment_aggregates sa
            WHERE sa.segment_id = ANY(v_targets)
              AND NOT EXISTS (
                  SELECT 1
                  FROM readings r
                  WHERE r.segment_id = sa.segment_id
                    AND r.recorded_at > v_retention_edge
              )
            RETURNING sa.segment_id
        )
        SELECT COALESCE(array_agg(segment_id), ARRAY[]::UUID[])
        INTO v_cleared
        FROM cleared;

        IF cardinality(v_cleared) > 0 THEN
            DELETE FROM segment_contributor_marks
            WHERE segment_id = ANY(v_cleared);
        END IF;

        -- B166 mark seeding (unchanged semantics), now over the resolved
        -- target set and in segment_id order.
        INSERT INTO segment_contributor_marks (segment_id, device_token_hash, first_seen_at)
        SELECT r.segment_id, r.device_token_hash, MIN(r.recorded_at)
        FROM readings r
        WHERE r.segment_id = ANY(v_targets)
          AND r.recorded_at > v_retention_edge
        GROUP BY r.segment_id, r.device_token_hash
        ORDER BY r.segment_id, r.device_token_hash
        ON CONFLICT (segment_id, device_token_hash) DO NOTHING;
    END IF;

    IF p_segment_ids IS NULL THEN
        INSERT INTO aggregate_recompute_state (singleton, last_full_run_started_at)
        VALUES (TRUE, v_now)
        ON CONFLICT (singleton) DO UPDATE
            SET last_full_run_started_at = EXCLUDED.last_full_run_started_at;
    END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM anon;
REVOKE EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION nightly_recompute_aggregates(UUID[]) TO service_role;
