import { requireEnv, secondsUntilNextUtcHour, sha256Hex, type RpcResponse } from "../upload-readings/runtime.ts";

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

export function createChallengeRateLimitChecker(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
    nowFactory: () => Date = () => new Date(),
) {
    return async (ip: string) => {
        const now = nowFactory();
        const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));

        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `device-token-challenge-ip:${ip}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: CHALLENGE_IP_LIMIT_PER_HOUR,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "device token challenge ip rate limit RPC failed");
        }
        if (!ipResult.data) {
            return {
                ok: false as const,
                retryAfterSeconds: secondsUntilNextUtcHour(now),
            };
        }

        return {
            ok: true as const,
            retryAfterSeconds: 0,
        };
    };
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
