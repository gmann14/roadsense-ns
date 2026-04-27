CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(17);

SELECT has_table('feedback_submissions', 'feedback_submissions table exists');

SELECT has_pk('feedback_submissions', 'feedback_submissions has a primary key');

SELECT col_not_null('feedback_submissions', 'source', 'source is not nullable');
SELECT col_not_null('feedback_submissions', 'category', 'category is not nullable');
SELECT col_not_null('feedback_submissions', 'message', 'message is not nullable');

SELECT has_type('feedback_source', 'feedback_source enum exists');
SELECT has_type('feedback_category', 'feedback_category enum exists');

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'feedback_submissions'
          AND indexname = 'idx_feedback_submissions_created_at'
    ),
    'feedback_submissions has a created_at index for triage'
);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.feedback_submissions'::regclass),
    'row level security is enabled on feedback_submissions'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM information_schema.role_table_grants
        WHERE table_name = 'feedback_submissions'
          AND grantee IN ('anon', 'authenticated')
    ),
    'anon/authenticated cannot read or write feedback_submissions directly'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM information_schema.role_table_grants
        WHERE table_name = 'feedback_submissions'
          AND grantee = 'service_role'
          AND privilege_type IN ('INSERT', 'SELECT')
    ),
    'service_role retains insert/select on feedback_submissions'
);

DELETE FROM feedback_submissions
WHERE message LIKE 'pgtap %';

SELECT throws_ok(
    $sql$
    INSERT INTO feedback_submissions (source, category, message)
    VALUES ('ios', 'bug', 'short')
    $sql$,
    '23514',
    NULL,
    'message length lower bound is enforced by check constraint'
);

SELECT throws_ok(
    $sql$
    INSERT INTO feedback_submissions (source, category, message)
    VALUES ('ios', 'bug', repeat('x', 4001))
    $sql$,
    '23514',
    NULL,
    'message length upper bound (4000) is enforced by check constraint'
);

SELECT throws_ok(
    $sql$
    INSERT INTO feedback_submissions (source, category, message, contact_consent)
    VALUES ('ios', 'bug', 'pgtap minimum-length boundary message', TRUE)
    $sql$,
    '23514',
    NULL,
    'contact_consent without reply_email is rejected'
);

SELECT lives_ok(
    $sql$
    INSERT INTO feedback_submissions (source, category, message)
    VALUES ('ios', 'bug', 'pgtap minimum-length boundary')
    $sql$,
    'an exactly-30-char message is accepted (8 minimum)'
);

SELECT lives_ok(
    $sql$
    INSERT INTO feedback_submissions (source, category, message, contact_consent, reply_email)
    VALUES ('web', 'feature', 'pgtap consent-with-email boundary', TRUE, 'tester@example.com')
    $sql$,
    'contact_consent with reply_email is accepted'
);

SELECT throws_ok(
    $sql$
    SET LOCAL ROLE anon;
    INSERT INTO feedback_submissions (source, category, message)
    VALUES ('web', 'bug', 'pgtap anon insertion attempt');
    RESET ROLE;
    $sql$,
    '42501',
    NULL,
    'anon role cannot INSERT into feedback_submissions directly'
);

DELETE FROM feedback_submissions
WHERE message LIKE 'pgtap %';

SELECT * FROM finish();
