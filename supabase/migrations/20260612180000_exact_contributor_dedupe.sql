-- B166: exact unique-contributor accounting for the incremental path
-- (P1-3, docs/reviews/2026-06-11-backend-prelaunch-review.md;
-- docs/implementation/15-device-attestation-and-trust.md).
--
-- `update_segment_aggregates_from_batch` (current definition 20260425001500)
-- UPSERTs `unique_contributors = segment_aggregates.unique_contributors +
-- EXCLUDED.unique_contributors`, where EXCLUDED is the per-batch
-- COUNT(DISTINCT device_token_hash) — 1 for a single device. Three batches
-- from one device therefore read as three contributors, flipping the segment
-- to `medium` confidence and public tile visibility until the nightly
-- recompute corrects it (which on the in-process scheduler can be nearly a
-- day away, behind a 1h tile cache).
--
-- Fix: a `segment_contributor_marks` exact-dedupe table. The incremental path
-- inserts one mark per (segment, device) ON CONFLICT DO NOTHING and increments
-- `unique_contributors` only by the count of rows actually inserted, then
-- derives confidence from the corrected value.
--
-- Why a dedupe table and not HyperLogLog: cardinality is tiny at NS scale
-- (active devices x touched segments), the Railway Postgres template ships no
-- `hll` extension, marks are exactly auditable in pgTAP, and the nightly
-- COUNT(DISTINCT) recompute already corrects any drift within 24h. The table
-- follows the existing small-bookkeeping-table conventions (`rate_limits`,
-- `processed_batches`: date-based GC, service_role-only access).
--
-- Privacy: marks hold token hashes already present in `readings`, with the
-- same 6-month retention window — no new retention class. Monthly token
-- rotation still counts a long-running device once per rotation; identical to
-- today's nightly-recompute semantics, deliberately kept so the no-cross-
-- rotation-linkage privacy property holds.

CREATE TABLE IF NOT EXISTS segment_contributor_marks (
    segment_id UUID NOT NULL REFERENCES road_segments(id) ON DELETE CASCADE,
    device_token_hash BYTEA NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (segment_id, device_token_hash)
);

-- GC sweep predicate (first_seen_at < now() - 6 months) needs this.
CREATE INDEX IF NOT EXISTS idx_segment_contributor_marks_first_seen
    ON segment_contributor_marks (first_seen_at);

ALTER TABLE segment_contributor_marks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON segment_contributor_marks FROM anon;
REVOKE ALL ON segment_contributor_marks FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON segment_contributor_marks TO service_role;

-- Backfill from the readings retention window so every device the nightly
-- recompute has already counted holds a mark from day one — otherwise each
-- existing device's first post-migration batch would inflate
-- unique_contributors by 1 until the next nightly run. Idempotent
-- (migrate-railway.sh re-runs every file).
INSERT INTO segment_contributor_marks (segment_id, device_token_hash, first_seen_at)
SELECT r.segment_id, r.device_token_hash, MIN(r.recorded_at)
FROM readings r
WHERE r.segment_id IS NOT NULL
  AND r.recorded_at > now() - INTERVAL '6 months'
GROUP BY r.segment_id, r.device_token_hash
ON CONFLICT (segment_id, device_token_hash) DO NOTHING;

-- Redefinition of the 20260425001500 body. Deltas (commented inline):
-- 1. `new_marks` / `new_mark_counts` CTEs insert contributor marks and count
--    only the rows actually inserted.
-- 2. The aggregate UPSERT's per-segment contributor value is that new-marks
--    count instead of the per-batch COUNT(DISTINCT device_token_hash).
-- The confidence-derivation UPDATE below it is byte-identical: it reads the
-- now-corrected unique_contributors, which closes "3 batches -> medium
-- confidence visible tile" in the same call.
CREATE OR REPLACE FUNCTION update_segment_aggregates_from_batch(p_batch_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- B166 delta: record one mark per (segment, device); only marks that
    -- actually insert count toward unique_contributors.
    WITH new_marks AS (
        INSERT INTO segment_contributor_marks (segment_id, device_token_hash, first_seen_at)
        SELECT r.segment_id, r.device_token_hash, MIN(r.recorded_at)
        FROM readings r
        WHERE r.batch_id = p_batch_id
          AND r.segment_id IS NOT NULL
        GROUP BY r.segment_id, r.device_token_hash
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
        -- B166 delta: was COUNT(DISTINCT r.device_token_hash)::INTEGER, which
        -- the UPSERT below blindly summed (P1-3). Now only genuinely-new
        -- contributor marks count. (If the aggregates row was deleted while
        -- marks survive — e.g. the bike-cleanup pattern — this undercounts
        -- until the nightly recompute, which remains the source of truth.)
        COALESCE(nmc.new_contributors, 0),
        MAX(r.recorded_at),
        COUNT(*) FILTER (WHERE r.is_pothole)::INTEGER,
        'low'::confidence_level,
        'unscored'::roughness_category
    FROM readings r
    LEFT JOIN new_mark_counts nmc ON nmc.segment_id = r.segment_id
    WHERE r.batch_id = p_batch_id
      AND r.segment_id IS NOT NULL
    GROUP BY r.segment_id, nmc.new_contributors
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

-- Redefinition of the 20260425001500 body. Single delta: after the recompute,
-- upsert a mark for every (segment, device) pair inside the recompute window,
-- so a device the nightly path has already counted can never re-increment
-- unique_contributors through a later incremental batch (and so marks GC'd at
-- the retention boundary are re-seeded while the device's readings remain).
-- The aggregate math above it is byte-identical.
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

    -- B166 delta: seed marks for every device/segment pair in the recompute
    -- window (superset of the contributor_count input set — a device whose
    -- readings were all p10-p90-trimmed still gets a mark, which biases the
    -- incremental path conservative rather than inflationary).
    INSERT INTO segment_contributor_marks (segment_id, device_token_hash, first_seen_at)
    SELECT r.segment_id, r.device_token_hash, MIN(r.recorded_at)
    FROM readings r
    WHERE r.segment_id IN (
        SELECT DISTINCT r2.segment_id
        FROM readings r2
        WHERE p_segment_ids IS NULL
          AND r2.uploaded_at > now() - INTERVAL '24 hours'
          AND r2.segment_id IS NOT NULL
        UNION
        SELECT DISTINCT unnest(p_segment_ids)
        WHERE p_segment_ids IS NOT NULL
    )
      AND r.recorded_at > now() - INTERVAL '6 months'
    GROUP BY r.segment_id, r.device_token_hash
    ON CONFLICT (segment_id, device_token_hash) DO NOTHING;
END;
$$;

-- Daily GC matching the 6-month reading-retention window, same pattern as
-- rate-limit-gc. pg_cron is stubbed on Railway; the Deno in-process scheduler
-- (supabase/functions/_shared/scheduler.ts) runs the equivalent sweep there.
DO $jobs$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'segment-contributor-marks-gc';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'segment-contributor-marks-gc',
        '30 4 * * *',
        $cmd$DELETE FROM segment_contributor_marks WHERE first_seen_at < now() - INTERVAL '6 months'$cmd$
    );
END;
$jobs$;
