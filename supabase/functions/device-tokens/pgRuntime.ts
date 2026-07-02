import { db, type DB } from "../db.ts";
import { requireEnv } from "../upload-readings/runtime.ts";
import type { ChallengeResult, DeviceTokenResult, RedeemChallengeResult } from "./handler.ts";
import { CHALLENGE_TTL_SECONDS, generateChallengeBase64Url, hashWithPepper } from "./runtime.ts";

export function createPgIssueChallenge(sqlOverride?: DB) {
    return async ({ clientIp }: { clientIp: string }): Promise<ChallengeResult> => {
        const sql = sqlOverride ?? db();
        const challenge = generateChallengeBase64Url();
        const challengeHashHex = await hashWithPepper(challenge);
        const expiresAt = new Date(Date.now() + CHALLENGE_TTL_SECONDS * 1000);

        await sql`
            SELECT issue_token_challenge(
                decode(${challengeHashHex}, 'hex')::bytea,
                ${expiresAt.toISOString()}::timestamptz,
                ${clientIp}::text
            )
        `;

        return {
            challenge,
            expires_at: expiresAt.toISOString(),
        };
    };
}

// Redeems a raw challenge string: hashes it with the same pepper used at
// issuance, then delegates to the atomic redeem_token_challenge SQL function
// (DELETE ... RETURNING) for single-use, race-free semantics. Distinguishes
// "expired" from "missing/already redeemed" via peek_token_challenge_expired
// so the handler can return the two distinct B160 error codes.
export function createPgRedeemChallenge(sqlOverride?: DB) {
    return async (challenge: string): Promise<RedeemChallengeResult> => {
        const sql = sqlOverride ?? db();
        const challengeHashHex = await hashWithPepper(challenge);

        const redeemed = (await sql`
            SELECT * FROM redeem_token_challenge(decode(${challengeHashHex}, 'hex')::bytea)
        `) as Array<{ challenge_hash: Uint8Array }>;

        if (redeemed.length > 0) {
            return { ok: true };
        }

        const expiredRows = (await sql`
            SELECT peek_token_challenge_expired(decode(${challengeHashHex}, 'hex')::bytea) AS expired
        `) as Array<{ expired: boolean }>;

        if (expiredRows[0]?.expired) {
            return { ok: false, reason: "expired" };
        }

        return { ok: false, reason: "missing" };
    };
}

export function createPgIssueDeviceToken(sqlOverride?: DB) {
    return async (params: {
        platform: string;
        keyId: string;
        publicKey: string;
        signCount: number;
        trustTier: "unverified" | "attested" | "established";
    }): Promise<DeviceTokenResult> => {
        const sql = sqlOverride ?? db();

        const keyIdHashHex = await hashWithPepper(params.keyId);
        const deviceToken = crypto.randomUUID();
        const tokenHashHex = await hashWithPepper(deviceToken);

        // publicKey arrives as whatever the verifier hands back (base64 in the
        // stub/test verifiers); store it as raw bytes via decode(...)::bytea,
        // matching the BYTEA-cast convention used throughout this codebase
        // (pothole-actions/pgRuntime.ts, upload-readings/pgRuntime.ts).
        const publicKeyBase64 = params.publicKey;

        await sql`
            SELECT upsert_attested_device(
                decode(${keyIdHashHex}, 'hex')::bytea,
                ${params.platform}::text,
                decode(${publicKeyBase64}, 'base64')::bytea,
                ${params.signCount}::bigint,
                ${params.trustTier}::device_trust_tier,
                decode(${tokenHashHex}, 'hex')::bytea
            )
        `;

        // 30-day expiry mirrors the existing monthly device-token rotation
        // cadence documented in 03-api-contracts.md ("Device Token Rotation").
        const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

        return {
            device_token: deviceToken,
            expires_at: expiresAt.toISOString(),
        };
    };
}

// TOKEN_PEPPER must be configured for this module to function at all;
// referenced here (rather than left implicit) so a missing-env failure
// surfaces clearly during local dev/CI wiring, matching requireEnv's use
// elsewhere in the codebase.
export function assertDeviceTokensConfigured(): void {
    requireEnv("TOKEN_PEPPER");
}
