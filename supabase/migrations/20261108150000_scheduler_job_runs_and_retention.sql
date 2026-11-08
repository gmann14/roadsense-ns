-- P0-6 retention + N3 scheduler visibility
-- (docs/reviews/2026-10-18-full-codebase-review.md).
--
-- 1. `scheduler_job_runs`: one row per in-process scheduler job
--    (supabase/functions/_shared/scheduler.ts) with its last start, last
--    success, last failure and consecutive failure count. The scheduler uses
--    it to decide whether a job is due (so a deploy or a second replica does
--    not re-run every daily job) and /health/deep uses it to report stale or
--    failing jobs. Holds job metadata only -- no user data.
-- 2. `purge_expired_readings()`: deletes readings older than exactly six
--    months and recomputes the segments they belonged to. The monthly
--    partition drop alone kept readings for 6-7 months (a partition is only
--    dropped once its whole month is past the line) and never touched the
--    aggregates built from them. The partition drop stays as the cheap bulk
--    reclaim of the then-empty partitions.
-- 3. `run_retention_sweeps()`: every other retention promise in
--    docs/implementation/06-security-and-privacy.md ("Retention schedule"),
--    none of which ran before:
--      unmatched_readings        90 days after upload (or 6 months after recording)
--      feedback_submissions      client_ip nulled after 30 days
--      token_challenges          deleted 1 hour after expiry (30 days hard cap)
--      processed_batches         180 days
--      pothole_actions           6 months (server receive time)
--      pothole_reporter_marks    6 months
--      segment_contributor_marks 6 months (was the separate marks-gc job)
--      rate_limits               2 days (was 7, via rate-limit-gc)
-- 4. pg_cron registrations (Supabase/local; Railway's cron stubs make these
--    no-ops and the Deno scheduler runs the same SQL): the consolidated
--    retention-sweeps job replaces rate-limit-gc and
--    segment-contributor-marks-gc, plus purge-expired-readings and the
--    daily replay-unmatched-readings that was never scheduled anywhere.

CREATE TABLE IF NOT EXISTS scheduler_job_runs (
    job_name TEXT PRIMARY KEY,
    last_started_at TIMESTAMPTZ,
    last_finished_at TIMESTAMPTZ,
    last_status TEXT CHECK (last_status IN ('ok', 'error')),
    last_success_at TIMESTAMPTZ,
    last_failure_at TIMESTAMPTZ,
    last_error TEXT,
    last_duration_ms INTEGER,
    last_result JSONB,
    consecutive_failures INTEGER NOT NULL DEFAULT 0
);

ALTER TABLE scheduler_job_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON scheduler_job_runs FROM anon;
REVOKE ALL ON scheduler_job_runs FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON scheduler_job_runs TO service_role;

CREATE OR REPLACE FUNCTION record_scheduler_job_run(
    p_job_name TEXT,
    p_started_at TIMESTAMPTZ,
    p_ok BOOLEAN,
    p_duration_ms INTEGER,
    p_error TEXT DEFAULT NULL,
    p_result JSONB DEFAULT NULL
) RETURNS VOID
LANGUAGE sql
SET search_path = pg_catalog, public
AS $$
    INSERT INTO scheduler_job_runs AS r (
        job_name,
        last_started_at,
        last_finished_at,
        last_status,
        last_success_at,
        last_failure_at,
        last_error,
        last_duration_ms,
        last_result,
        consecutive_failures
    ) VALUES (
        p_job_name,
        COALESCE(p_started_at, now()),
        clock_timestamp(),
        CASE WHEN p_ok THEN 'ok' ELSE 'error' END,
        CASE WHEN p_ok THEN clock_timestamp() END,
        CASE WHEN p_ok THEN NULL ELSE clock_timestamp() END,
        CASE WHEN p_ok THEN NULL ELSE left(p_error, 1000) END,
        p_duration_ms,
        CASE WHEN p_ok THEN p_result END,
        CASE WHEN p_ok THEN 0 ELSE 1 END
    )
    ON CONFLICT (job_name) DO UPDATE SET
        last_started_at = EXCLUDED.last_started_at,
        last_finished_at = EXCLUDED.last_finished_at,
        last_status = EXCLUDED.last_status,
        last_success_at = COALESCE(EXCLUDED.last_success_at, r.last_success_at),
        last_failure_at = COALESCE(EXCLUDED.last_failure_at, r.last_failure_at),
        last_error = CASE WHEN p_ok THEN r.last_error ELSE EXCLUDED.last_error END,
        last_duration_ms = EXCLUDED.last_duration_ms,
        last_result = CASE WHEN p_ok THEN EXCLUDED.last_result ELSE r.last_result END,
        consecutive_failures = CASE WHEN p_ok THEN 0 ELSE r.consecutive_failures + 1 END;
$$;

REVOKE EXECUTE ON FUNCTION record_scheduler_job_run(TEXT, TIMESTAMPTZ, BOOLEAN, INTEGER, TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION record_scheduler_job_run(TEXT, TIMESTAMPTZ, BOOLEAN, INTEGER, TEXT, JSONB) FROM anon;
REVOKE EXECUTE ON FUNCTION record_scheduler_job_run(TEXT, TIMESTAMPTZ, BOOLEAN, INTEGER, TEXT, JSONB) FROM authenticated;
GRANT EXECUTE ON FUNCTION record_scheduler_job_run(TEXT, TIMESTAMPTZ, BOOLEAN, INTEGER, TEXT, JSONB) TO service_role;

-- Seconds until a job is next due, by the database clock (0 = due now).
-- A job whose last run succeeded is due `p_interval_seconds` after that run
-- started; after a failure it is retried `p_retry_seconds` after the failed
-- start (never later than the normal interval). Never-run jobs are due now.
CREATE OR REPLACE FUNCTION scheduler_job_seconds_until_due(
    p_job_name TEXT,
    p_interval_seconds INTEGER,
    p_retry_seconds INTEGER
) RETURNS INTEGER
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT COALESCE(
        (
            SELECT GREATEST(
                0,
                CEIL(EXTRACT(EPOCH FROM (
                    r.last_started_at
                    + make_interval(secs => CASE
                        WHEN r.last_status = 'ok' THEN p_interval_seconds
                        ELSE LEAST(p_retry_seconds, p_interval_seconds)
                    END)
                    - now()
                )))
            )::INTEGER
            FROM scheduler_job_runs r
            WHERE r.job_name = p_job_name
              AND r.last_started_at IS NOT NULL
        ),
        0
    );
$$;

REVOKE EXECUTE ON FUNCTION scheduler_job_seconds_until_due(TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION scheduler_job_seconds_until_due(TEXT, INTEGER, INTEGER) FROM anon;
REVOKE EXECUTE ON FUNCTION scheduler_job_seconds_until_due(TEXT, INTEGER, INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION scheduler_job_seconds_until_due(TEXT, INTEGER, INTEGER) TO service_role;

CREATE OR REPLACE FUNCTION purge_expired_readings()
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_deleted INTEGER := 0;
    v_segments UUID[];
BEGIN
    -- Partition pruning keeps this to the oldest one or two partitions.
    WITH deleted AS (
        DELETE FROM readings
        WHERE recorded_at <= now() - INTERVAL '6 months'
        RETURNING segment_id
    )
    SELECT
        COUNT(*)::INTEGER,
        COALESCE(
            array_agg(DISTINCT segment_id) FILTER (WHERE segment_id IS NOT NULL),
            ARRAY[]::UUID[]
        )
    INTO v_deleted, v_segments
    FROM deleted;

    -- Recompute (or clear) every segment that just lost readings, so no
    -- public score outlives the readings it was built from.
    IF cardinality(v_segments) > 0 THEN
        PERFORM nightly_recompute_aggregates(v_segments);
    END IF;

    RETURN jsonb_build_object(
        'deleted_readings', v_deleted,
        'segments_recomputed', cardinality(v_segments)
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION purge_expired_readings() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION purge_expired_readings() FROM anon;
REVOKE EXECUTE ON FUNCTION purge_expired_readings() FROM authenticated;
GRANT EXECUTE ON FUNCTION purge_expired_readings() TO service_role;

CREATE OR REPLACE FUNCTION run_retention_sweeps()
RETURNS JSONB
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_unmatched INTEGER := 0;
    v_feedback_ips INTEGER := 0;
    v_challenges INTEGER := 0;
    v_batches INTEGER := 0;
    v_actions INTEGER := 0;
    v_pothole_marks INTEGER := 0;
    v_segment_marks INTEGER := 0;
    v_rate_limits INTEGER := 0;
BEGIN
    DELETE FROM unmatched_readings
    WHERE created_at < now() - INTERVAL '90 days'
       OR recorded_at <= now() - INTERVAL '6 months';
    GET DIAGNOSTICS v_unmatched = ROW_COUNT;

    UPDATE feedback_submissions
    SET client_ip = NULL
    WHERE client_ip IS NOT NULL
      AND created_at < now() - INTERVAL '30 days';
    GET DIAGNOSTICS v_feedback_ips = ROW_COUNT;

    -- Challenges live 5 minutes; the hour of grace keeps the
    -- challenge_expired vs challenge_invalid distinction meaningful for a
    -- client that redeems just after expiry. The 30-day cap bounds
    -- client_ip retention even if a bad expires_at was ever written.
    DELETE FROM token_challenges
    WHERE expires_at < now() - INTERVAL '1 hour'
       OR created_at < now() - INTERVAL '30 days';
    GET DIAGNOSTICS v_challenges = ROW_COUNT;

    -- Idempotency ledger. Uploads are rejected as stale after 7 days, so a
    -- 180-day-old batch id can never legitimately be retried.
    DELETE FROM processed_batches
    WHERE processed_at < now() - INTERVAL '180 days';
    GET DIAGNOSTICS v_batches = ROW_COUNT;

    -- Device hash + exact location: same 6-month line as readings. Keyed on
    -- server receive time (created_at), not the client-supplied recorded_at.
    DELETE FROM pothole_actions
    WHERE created_at < now() - INTERVAL '6 months';
    GET DIAGNOSTICS v_actions = ROW_COUNT;

    DELETE FROM pothole_reporter_marks
    WHERE created_at < now() - INTERVAL '6 months';
    GET DIAGNOSTICS v_pothole_marks = ROW_COUNT;

    DELETE FROM segment_contributor_marks
    WHERE first_seen_at < now() - INTERVAL '6 months';
    GET DIAGNOSTICS v_segment_marks = ROW_COUNT;

    -- The widest rate-limit window is 24 h.
    DELETE FROM rate_limits
    WHERE bucket_start < now() - INTERVAL '2 days';
    GET DIAGNOSTICS v_rate_limits = ROW_COUNT;

    RETURN jsonb_build_object(
        'unmatched_readings', v_unmatched,
        'feedback_client_ips_cleared', v_feedback_ips,
        'token_challenges', v_challenges,
        'processed_batches', v_batches,
        'pothole_actions', v_actions,
        'pothole_reporter_marks', v_pothole_marks,
        'segment_contributor_marks', v_segment_marks,
        'rate_limits', v_rate_limits
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION run_retention_sweeps() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION run_retention_sweeps() FROM anon;
REVOKE EXECUTE ON FUNCTION run_retention_sweeps() FROM authenticated;
GRANT EXECUTE ON FUNCTION run_retention_sweeps() TO service_role;

-- Sweep predicates need these.
CREATE INDEX IF NOT EXISTS idx_pothole_actions_created_at ON pothole_actions (created_at);
CREATE INDEX IF NOT EXISTS idx_pothole_reporter_marks_created_at ON pothole_reporter_marks (created_at);
CREATE INDEX IF NOT EXISTS idx_feedback_submissions_ip_retention
    ON feedback_submissions (created_at)
    WHERE client_ip IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_token_challenges_created_at ON token_challenges (created_at);
CREATE INDEX IF NOT EXISTS idx_unmatched_readings_recorded_at ON unmatched_readings (recorded_at);

DO $jobs$
DECLARE
    v_job_id BIGINT;
    v_name TEXT;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['rate-limit-gc', 'segment-contributor-marks-gc'] LOOP
        SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = v_name;
        IF v_job_id IS NOT NULL THEN
            PERFORM cron.unschedule(v_job_id);
        END IF;
    END LOOP;

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'purge-expired-readings';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'purge-expired-readings',
        '5 3 * * *',
        $cmd$SELECT purge_expired_readings()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'replay-unmatched-readings';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'replay-unmatched-readings',
        '45 2 * * *',
        $cmd$SELECT replay_unmatched_readings()$cmd$
    );

    SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'retention-sweeps';
    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
    PERFORM cron.schedule(
        'retention-sweeps',
        '30 4 * * *',
        $cmd$SELECT run_retention_sweeps()$cmd$
    );
END;
$jobs$;
