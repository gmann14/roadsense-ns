-- upsert_attested_device overwrote `public_key` and `sign_count` on conflict
-- (docs/reviews/2026-10-18-full-codebase-review.md, "Fake attestation
-- verifier wired into production").
--
-- The attested public key is the device's identity anchor: a later
-- attestation for the same key id must never replace it (with a real
-- verifier, a replaced key lets whoever triggered the conflict sign future
-- assertions as that device). And App Attest's sign counter is monotonic; a
-- lower value on a later call is a replayed or cloned assertion and must not
-- roll the stored counter back.
--
-- Redefinition of the 20260702160000 body. Delta: on conflict, `public_key`
-- is kept and `sign_count` only moves forward (GREATEST). Token rotation
-- (`current_token_hash`, `last_rotated_at`) is unchanged, so the
-- no-rotation-history privacy posture is unaffected.

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
        -- 2026-11 delta: public_key is never overwritten; sign_count never
        -- decreases.
        sign_count = GREATEST(ad.sign_count, EXCLUDED.sign_count),
        current_token_hash = EXCLUDED.current_token_hash,
        last_rotated_at = now()
    RETURNING ad.* INTO v_row;

    RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION upsert_attested_device(BYTEA, TEXT, BYTEA, BIGINT, device_trust_tier, BYTEA) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_attested_device(BYTEA, TEXT, BYTEA, BIGINT, device_trust_tier, BYTEA) TO service_role;
