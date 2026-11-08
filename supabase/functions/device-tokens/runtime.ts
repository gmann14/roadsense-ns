import { requireEnv, sha256Hex } from "../upload-readings/runtime.ts";
import { createHourlyIpRateLimitChecker, type RateLimitResult, type RateLimitRpc } from "../_shared/rateLimit.ts";

// Per-IP rate limit for challenge issuance, using the existing
// check_and_bump_rate_limit SQL pattern (see upload-readings/runtime.ts and
// pothole-actions/runtime.ts for the two prior callers). Challenge issuance
// has no device identity yet (that's the whole point -- the device proves
// itself via the challenge), so this is IP-only, unlike the device+IP dual
// check the other two rate limiters do.
//
// Limit chosen to comfortably cover the legitimate retry/backoff path (a
// client that fails attestation and needs a fresh challenge) while still
// bounding a challenge-minting flood: 30/hour/IP is generous for a handful
// of devices behind one NAT/carrier-grade-NAT IP, tight enough that scripted
// abuse can't mint thousands of challenges for free.
const CHALLENGE_IP_LIMIT_PER_HOUR = 30;

// Redemption is the expensive half (challenge lookup + attestation verify +
// upsert), and it had no limit at all (review 2026-10-18). Same budget as
// challenge issuance: every legitimate redemption needs one challenge.
const REDEEM_IP_LIMIT_PER_HOUR = 30;

export function createChallengeRateLimitChecker(
    rpc: RateLimitRpc,
    nowFactory: () => Date = () => new Date(),
): (ip: string) => Promise<RateLimitResult> {
    return createHourlyIpRateLimitChecker(rpc, {
        keyPrefix: "device-token-challenge-ip",
        limitPerHour: CHALLENGE_IP_LIMIT_PER_HOUR,
        nowFactory,
    });
}

export function createRedeemRateLimitChecker(
    rpc: RateLimitRpc,
    nowFactory: () => Date = () => new Date(),
): (ip: string) => Promise<RateLimitResult> {
    return createHourlyIpRateLimitChecker(rpc, {
        keyPrefix: "device-token-redeem-ip",
        limitPerHour: REDEEM_IP_LIMIT_PER_HOUR,
        nowFactory,
    });
}

// Same pepper-hashing posture as hashDeviceToken in upload-readings/runtime.ts:
// the raw challenge/key_id is hashed with TOKEN_PEPPER and only the hash is
// ever persisted or compared. Reusing TOKEN_PEPPER (rather than minting a
// second secret) keeps one pepper to rotate/manage, matching how
// upload-readings and pothole-actions already share it for device token
// hashing -- challenges and key ids get the identical treatment.
export async function hashWithPepper(value: string): Promise<string> {
    return sha256Hex(`${value}${requireEnv("TOKEN_PEPPER")}`);
}

export function generateChallengeBase64Url(): string {
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    let binary = "";
    for (const byte of bytes) {
        binary += String.fromCharCode(byte);
    }
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export const CHALLENGE_TTL_SECONDS = 300; // 5 minutes, per doc 17's architecture diagram.
