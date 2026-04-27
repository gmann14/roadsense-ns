DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'feedback_source'
    ) THEN
        CREATE TYPE feedback_source AS ENUM ('ios', 'web');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'feedback_category'
    ) THEN
        CREATE TYPE feedback_category AS ENUM (
            'bug',
            'feature',
            'map_issue',
            'pothole_issue',
            'privacy_safety',
            'other'
        );
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS feedback_submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source feedback_source NOT NULL,
    category feedback_category NOT NULL,
    message TEXT NOT NULL,
    reply_email TEXT,
    contact_consent BOOLEAN NOT NULL DEFAULT FALSE,
    app_version TEXT,
    platform TEXT,
    locale TEXT,
    route TEXT,
    user_agent TEXT,
    client_ip TEXT,
    request_id TEXT,
    CONSTRAINT feedback_message_length CHECK (char_length(message) BETWEEN 8 AND 4000),
    CONSTRAINT feedback_reply_email_length CHECK (
        reply_email IS NULL OR char_length(reply_email) <= 254
    ),
    CONSTRAINT feedback_contact_requires_email CHECK (
        contact_consent = FALSE OR reply_email IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS idx_feedback_submissions_created_at
    ON feedback_submissions (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_feedback_submissions_category
    ON feedback_submissions (category, created_at DESC);

ALTER TABLE feedback_submissions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON feedback_submissions FROM anon;
REVOKE ALL ON feedback_submissions FROM authenticated;
GRANT SELECT, INSERT ON feedback_submissions TO service_role;
