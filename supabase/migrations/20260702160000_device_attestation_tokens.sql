-- B160 — server-issued device tokens: schema, challenge, and issuance
-- endpoint (docs/implementation/17-device-attestation-and-trust.md).
--
-- This migration lays the foundation for the attestation chain (B160-B164):
-- the device token stops being client-minted. The client proves device
-- integrity once (App Attest / Play Integrity, B161/B163), the server mints
-- a token and remembers the binding in `attested_devices`.
--
-- Privacy posture (load-bearing, see doc 17 "Privacy posture" section):
--   1. `attested_devices.key_id_hash` is SHA256(key_id || TOKEN_PEPPER) --
--      the raw App Attest/Play Integrity key id is never stored.
--   2. The row holds ONLY `current_token_hash`, overwritten in place at
--      rotation. No token-history table, no issuance audit log of past
--      hashes -- after rotation the server cannot join last month's
--      readings to this month's device. This is a hard requirement, not a
--      style preference: do not add a history/audit table here.
--   3. `token_challenges` stores the challenge hashed (same pepper pattern
--      as `TOKEN_PEPPER` device-token hashing in upload-readings/runtime.ts),
--      TTL-bounded, single-use via delete-on-redeem.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type
        WHERE typname = 'device_trust_tier'
    ) THEN
        CREATE TYPE device_trust_tier AS ENUM ('unverified', 'attested', 'established');
    END IF;
END
$$;

-- One row per physical device (keyed by its hashed attestation key id).
-- Rotation overwrites `public_key`, `sign_count`, `current_token_hash`,
-- `last_rotated_at`, and increments `accepted_batches` IN PLACE -- there is
-- deliberately no history table. See privacy posture note above.
CREATE TABLE IF NOT EXISTS attested_devices (
    key_id_hash BYTEA PRIMARY KEY,
    platform TEXT NOT NULL,
    public_key BYTEA NOT NULL,
    sign_count BIGINT NOT NULL DEFAULT 0,
    trust_tier device_trust_tier NOT NULL DEFAULT 'unverified',
    current_token_hash BYTEA NOT NULL UNIQUE,
    first_attested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_rotated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_batches INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT attested_devices_platform_check CHECK (platform IN ('ios', 'android'))
);

CREATE INDEX IF NOT EXISTS idx_attested_devices_trust_tier
    ON attested_devices (trust_tier);

ALTER TABLE attested_devices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON attested_devices FROM anon;
REVOKE ALL ON attested_devices FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON attested_devices TO service_role;

-- Server-minted attestation challenges. Hashed at rest (same "never store
-- the raw secret" posture as device tokens); TTL-bounded; consumed exactly
-- once via DELETE ... RETURNING in redeem_token_challenge below.
CREATE TABLE IF NOT EXISTS token_challenges (
    challenge_hash BYTEA PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    client_ip TEXT
);

CREATE INDEX IF NOT EXISTS idx_token_challenges_expires_at
    ON token_challenges (expires_at);

ALTER TABLE token_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON token_challenges FROM anon;
REVOKE ALL ON token_challenges FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON token_challenges TO service_role;

-- Issues a challenge: caller (the Deno handler) generates the raw 32-byte
-- challenge and hashes it with TOKEN_PEPPER before calling this, mirroring
-- how device tokens are hashed in upload-readings/runtime.ts. Only the hash
-- and TTL are ever persisted.
CREATE OR REPLACE FUNCTION issue_token_challenge(
    p_challenge_hash BYTEA,
    p_expires_at TIMESTAMPTZ,
    p_client_ip TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    INSERT INTO token_challenges (challenge_hash, expires_at, client_ip)
    VALUES (p_challenge_hash, p_expires_at, p_client_ip);
END;
$$;

REVOKE EXECUTE ON FUNCTION issue_token_challenge(BYTEA, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_token_challenge(BYTEA, TIMESTAMPTZ, TEXT) TO service_role;

-- Atomically consumes a challenge: single-use via DELETE ... RETURNING.
-- Under concurrent callers redeeming the SAME challenge_hash, Postgres row
-- locking on the DELETE means only one transaction's DELETE affects the row;
-- the other sees zero rows deleted (FOUND = false) and gets nothing back.
-- This is exactly what guarantees "concurrent redeems of one challenge
-- yield exactly one token" at the SQL layer.
--
-- Returns NULL if the challenge does not exist, is expired, or was already
-- redeemed by a concurrent/earlier call -- the caller (Deno handler) is
-- responsible for distinguishing "missing" from "expired" at the API layer
-- via its own pre-check, since this function intentionally collapses both
-- into one atomic no-row-returned outcome to keep the single DML statement
-- race-free.
CREATE OR REPLACE FUNCTION redeem_token_challenge(
    p_challenge_hash BYTEA
) RETURNS TABLE (challenge_hash BYTEA, created_at TIMESTAMPTZ, expires_at TIMESTAMPTZ)
LANGUAGE sql
SET search_path = pg_catalog, public
AS $$
    DELETE FROM token_challenges
    WHERE token_challenges.challenge_hash = p_challenge_hash
      AND token_challenges.expires_at > now()
    RETURNING token_challenges.challenge_hash, token_challenges.created_at, token_challenges.expires_at;
$$;

REVOKE EXECUTE ON FUNCTION redeem_token_challenge(BYTEA) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION redeem_token_challenge(BYTEA) TO service_role;

-- Distinguishes "never existed / already redeemed" from "exists but
-- expired" without consuming the row, so the Deno handler can return the
-- distinct challenge_expired vs challenge_invalid error codes the B160
-- ticket requires. Read-only; does not delete expired rows (GC is a
-- follow-up scheduler concern, matching the segment_contributor_marks GC
-- pattern -- not required for B160's acceptance criteria).
CREATE OR REPLACE FUNCTION peek_token_challenge_expired(
    p_challenge_hash BYTEA
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM token_challenges
        WHERE token_challenges.challenge_hash = p_challenge_hash
          AND token_challenges.expires_at <= now()
    );
$$;

REVOKE EXECUTE ON FUNCTION peek_token_challenge_expired(BYTEA) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION peek_token_challenge_expired(BYTEA) TO service_role;

-- Upserts a device's attestation record and mints/rotates its current
-- token. Overwrites in place per the privacy posture note at the top of
-- this file -- no history is kept across rotations.
CREATE OR REPLACE FUNCTION upsert_attested_device(
    p_key_id_hash BYTEA,
    p_platform TEXT,
    p_public_key BYTEA,
    p_sign_count BIGINT,
    p_trust_tier device_trust_tier,
    p_current_token_hash BYTEA
) RETURNS attested_devices
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_row attested_devices%ROWTYPE;
BEGIN
    INSERT INTO attested_devices AS ad (
        key_id_hash, platform, public_key, sign_count, trust_tier,
        current_token_hash, first_attested_at, last_rotated_at, accepted_batches
    ) VALUES (
        p_key_id_hash, p_platform, p_public_key, p_sign_count, p_trust_tier,
        p_current_token_hash, now(), now(), 0
    )
    ON CONFLICT (key_id_hash) DO UPDATE SET
        public_key = EXCLUDED.public_key,
        sign_count = EXCLUDED.sign_count,
        current_token_hash = EXCLUDED.current_token_hash,
        last_rotated_at = now()
    RETURNING ad.* INTO v_row;

    RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION upsert_attested_device(BYTEA, TEXT, BYTEA, BIGINT, device_trust_tier, BYTEA) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_attested_device(BYTEA, TEXT, BYTEA, BIGINT, device_trust_tier, BYTEA) TO service_role;
