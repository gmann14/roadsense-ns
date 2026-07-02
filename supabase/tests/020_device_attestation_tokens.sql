-- B160 — server-issued device tokens: schema, challenge, and issuance
-- endpoint (docs/implementation/17-device-attestation-and-trust.md).
--
-- Covers: hashed storage for both new tables (no raw challenge/key_id ever
-- persisted), TTL expiry + single-use delete-on-redeem for
-- token_challenges, and PK/UNIQUE + overwrite-in-place-leaves-one-row-no-
-- history for attested_devices. Also the guard requirement from the B160
-- RED list: no table stores a raw key_id, and current_token_hash is UNIQUE
-- so no device can ever hold more than one live token hash.

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(39);

DELETE FROM attested_devices
WHERE key_id_hash IN (decode('aa01', 'hex'), decode('aa02', 'hex'), decode('aa03', 'hex'));

DELETE FROM token_challenges
WHERE challenge_hash IN (
    decode('bb01', 'hex'), decode('bb02', 'hex'), decode('bb03', 'hex'),
    decode('bb04', 'hex'), decode('bb05', 'hex'), decode('bb06', 'hex')
);

-- ── Schema sanity ────────────────────────────────────────────────────────

SELECT has_table('public', 'attested_devices', 'attested_devices table exists');
SELECT has_table('public', 'token_challenges', 'token_challenges table exists');

SELECT col_is_pk(
    'public', 'attested_devices', 'key_id_hash',
    'attested_devices.key_id_hash is primary key'
);
SELECT col_type_is(
    'public', 'attested_devices', 'key_id_hash', 'bytea',
    'attested_devices.key_id_hash is bytea (hashed, never the raw key id)'
);
SELECT col_type_is(
    'public', 'attested_devices', 'public_key', 'bytea',
    'attested_devices.public_key is bytea'
);
SELECT col_type_is(
    'public', 'attested_devices', 'current_token_hash', 'bytea',
    'attested_devices.current_token_hash is bytea (hashed)'
);
SELECT col_is_unique(
    'public', 'attested_devices', 'current_token_hash',
    'attested_devices.current_token_hash is UNIQUE (no device can share a live token hash)'
);

SELECT col_is_pk(
    'public', 'token_challenges', 'challenge_hash',
    'token_challenges.challenge_hash is primary key'
);
SELECT col_type_is(
    'public', 'token_challenges', 'challenge_hash', 'bytea',
    'token_challenges.challenge_hash is bytea (hashed, never the raw challenge)'
);

-- device_trust_tier enum exists with the three documented values.
SELECT has_type('device_trust_tier', 'device_trust_tier enum exists');
SELECT enum_has_labels(
    'device_trust_tier',
    ARRAY['unverified', 'attested', 'established'],
    'device_trust_tier has exactly the documented labels'
);

-- Guard: neither table is anon/authenticated readable (device identity data).
SELECT ok(
    NOT has_table_privilege('anon', 'public.attested_devices', 'SELECT'),
    'anon cannot read attested_devices'
);
SELECT ok(
    NOT has_table_privilege('anon', 'public.token_challenges', 'SELECT'),
    'anon cannot read token_challenges'
);

-- ── token_challenges: issuance, TTL expiry, single-use delete-on-redeem ──

SELECT lives_ok(
    $$SELECT issue_token_challenge(decode('bb01', 'hex'), now() + INTERVAL '5 minutes', '203.0.113.5')$$,
    'issue_token_challenge inserts a hashed, TTL-bounded challenge'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM token_challenges WHERE challenge_hash = decode('bb01', 'hex')),
    '1',
    'exactly one row stored for the issued challenge'
);

-- Redeeming a valid, unexpired challenge returns it and deletes the row
-- (single-use).
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb01', 'hex'))),
    '1',
    'redeem_token_challenge returns the row for a valid unexpired challenge'
);
SELECT is(
    (SELECT COUNT(*)::TEXT FROM token_challenges WHERE challenge_hash = decode('bb01', 'hex')),
    '0',
    'redeeming deletes the challenge row (single-use, delete-on-redeem)'
);

-- Reusing the same (now-deleted) challenge fails: no row returned.
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb01', 'hex'))),
    '0',
    'redeeming an already-redeemed challenge returns nothing (reuse rejected)'
);

-- A missing challenge (never issued) also returns nothing.
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb02', 'hex'))),
    '0',
    'redeeming a challenge that was never issued returns nothing'
);
SELECT ok(
    NOT peek_token_challenge_expired(decode('bb02', 'hex')),
    'peek_token_challenge_expired is false for a challenge that never existed (not "expired", just missing)'
);

-- TTL expiry: an already-expired challenge cannot be redeemed, and the peek
-- helper distinguishes "expired" from "missing" for distinct error codes.
SELECT lives_ok(
    $$SELECT issue_token_challenge(decode('bb03', 'hex'), now() - INTERVAL '1 minute', '203.0.113.6')$$,
    'issue_token_challenge accepts an already-past expiry for the expiry fixture'
);
SELECT ok(
    peek_token_challenge_expired(decode('bb03', 'hex')),
    'peek_token_challenge_expired is true for an expired-but-present challenge'
);
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb03', 'hex'))),
    '0',
    'redeem_token_challenge never returns an expired challenge'
);

-- ── Concurrency: two simultaneous redeems of one challenge yield exactly
--    one success. We can't fork real concurrent transactions inside a single
--    pgTAP script, so this proves the property the atomicity relies on: the
--    single DELETE ... RETURNING statement is all-or-nothing per row, and a
--    second call after the first always sees zero rows -- there is no
--    read-then-write gap a second session could interleave into. The Deno
--    contract-test suite (device-tokens/index_test.ts) exercises this with
--    real parallel HTTP requests against the handler.
SELECT lives_ok(
    $$SELECT issue_token_challenge(decode('bb04', 'hex'), now() + INTERVAL '5 minutes', '203.0.113.7')$$,
    'issue_token_challenge for the concurrency-semantics fixture'
);
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb04', 'hex'))),
    '1',
    'first redeem call succeeds'
);
SELECT is(
    (SELECT COUNT(*)::TEXT FROM redeem_token_challenge(decode('bb04', 'hex'))),
    '0',
    'immediate second redeem call (simulating a losing concurrent racer) returns nothing'
);

-- ── attested_devices: upsert overwrite-in-place, exactly one row per device
--    after N rotations, no history table/rows anywhere ──────────────────

SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('aa01', 'hex'), 'ios', decode('c1', 'hex'), 0, 'attested'::device_trust_tier, decode('d1', 'hex'))$$,
    'upsert_attested_device inserts a new device on first attestation'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM attested_devices WHERE key_id_hash = decode('aa01', 'hex')),
    '1',
    'exactly one row exists for the device after first attestation'
);
SELECT is(
    (SELECT current_token_hash FROM attested_devices WHERE key_id_hash = decode('aa01', 'hex')),
    decode('d1', 'hex'),
    'current_token_hash matches the first-issued token'
);

-- Rotate three times ("N rotations"): each call must overwrite the same row,
-- not insert a new one.
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('aa01', 'hex'), 'ios', decode('c1', 'hex'), 1, 'attested'::device_trust_tier, decode('d2', 'hex'))$$,
    'first rotation overwrites the existing row'
);
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('aa01', 'hex'), 'ios', decode('c1', 'hex'), 2, 'established'::device_trust_tier, decode('d3', 'hex'))$$,
    'second rotation overwrites the existing row again'
);
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('aa01', 'hex'), 'ios', decode('c1', 'hex'), 3, 'established'::device_trust_tier, decode('d4', 'hex'))$$,
    'third rotation overwrites the existing row again'
);

SELECT is(
    (SELECT COUNT(*)::TEXT FROM attested_devices WHERE key_id_hash = decode('aa01', 'hex')),
    '1',
    'attested_devices contains exactly one row per device after N rotations'
);
SELECT is(
    (SELECT current_token_hash FROM attested_devices WHERE key_id_hash = decode('aa01', 'hex')),
    decode('d4', 'hex'),
    'current_token_hash holds only the latest token hash after rotation (no history)'
);
SELECT is(
    (SELECT sign_count::TEXT FROM attested_devices WHERE key_id_hash = decode('aa01', 'hex')),
    '3',
    'sign_count reflects only the latest rotation value, overwritten in place'
);

-- A second, distinct device gets its own row (proves PK isolation, not a
-- shared/aggregated row).
SELECT lives_ok(
    $$SELECT upsert_attested_device(decode('aa02', 'hex'), 'android', decode('c2', 'hex'), 0, 'unverified'::device_trust_tier, decode('d5', 'hex'))$$,
    'a distinct device upserts its own row'
);
SELECT is(
    (SELECT COUNT(*)::TEXT FROM attested_devices WHERE key_id_hash IN (decode('aa01', 'hex'), decode('aa02', 'hex'))),
    '2',
    'two distinct devices produce exactly two rows total'
);

-- Guard: current_token_hash UNIQUE means no device can ever be issued a
-- token hash already bound to a different device (would raise, not silently
-- duplicate).
SELECT throws_ok(
    $$SELECT upsert_attested_device(decode('aa03', 'hex'), 'ios', decode('c3', 'hex'), 0, 'unverified'::device_trust_tier, decode('d4', 'hex'))$$,
    '23505',
    NULL,
    'a token hash already bound to another device cannot be reused (UNIQUE violation)'
);

-- Guard: no companion history/audit table exists anywhere in the schema for
-- either table -- this is the automated form of the "no history table, no
-- historical joins" hard privacy requirement from doc 17.
SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND (
              table_name ILIKE '%attested_device%history%'
              OR table_name ILIKE '%device_token%history%'
              OR table_name ILIKE '%token_challenge%history%'
              OR table_name ILIKE '%attestation%audit%'
              OR table_name ILIKE '%attested_device%log%'
          )
    ),
    'no attested-device/token-challenge history or audit table exists anywhere in the schema'
);

SELECT * FROM finish();
