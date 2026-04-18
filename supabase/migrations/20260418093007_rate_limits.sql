CREATE TABLE IF NOT EXISTS rate_limits (
    key TEXT NOT NULL,
    bucket_start TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (key, bucket_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_bucket_start
    ON rate_limits (bucket_start);

CREATE OR REPLACE FUNCTION check_and_bump_rate_limit(
    p_key TEXT,
    p_bucket_start TIMESTAMPTZ,
    p_limit INTEGER
) RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    INSERT INTO rate_limits AS rl (key, bucket_start, request_count)
    VALUES (p_key, p_bucket_start, 1)
    ON CONFLICT (key, bucket_start)
    DO UPDATE SET request_count = rl.request_count + 1
    RETURNING request_count INTO v_count;

    RETURN v_count <= p_limit;
END;
$$;

REVOKE EXECUTE ON FUNCTION check_and_bump_rate_limit(TEXT, TIMESTAMPTZ, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_and_bump_rate_limit(TEXT, TIMESTAMPTZ, INTEGER) TO service_role;

