import { secondsUntilNextUtcDay, secondsUntilNextUtcHour } from "../upload-readings/runtime.ts";
import { RATE_LIMIT_OK, rateLimitIpKey, type RateLimitResult, type RateLimitRpc } from "../_shared/rateLimit.ts";

export function createPotholeActionRateLimitChecker(
    rpc: RateLimitRpc,
    nowFactory: () => Date = () => new Date(),
): (tokenHashHex: string, ip: string) => Promise<RateLimitResult> {
    return async (tokenHashHex: string, ip: string): Promise<RateLimitResult> => {
        const now = nowFactory();
        const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
        const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));

        // IP check runs first and short-circuits before the device check/bump
        // (P1-4) — see upload-readings/runtime.ts for the full rationale:
        // device_token is client-chosen, so checking it first would let an
        // IP-limited attacker keep writing rate_limits rows by rotating
        // tokens.
        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-action-ip:${rateLimitIpKey(ip)}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: 120,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "pothole action ip rate limit RPC failed");
        }
        if (!ipResult.data) {
            return { ok: false, retryAfterSeconds: secondsUntilNextUtcHour(now) };
        }

        const deviceResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-action-device:${tokenHashHex}`,
            p_bucket_start: dayBucket.toISOString(),
            p_limit: 60,
        });
        if (deviceResult.error) {
            throw new Error(deviceResult.error.message ?? "pothole action device rate limit RPC failed");
        }
        if (!deviceResult.data) {
            return { ok: false, retryAfterSeconds: secondsUntilNextUtcDay(now) };
        }

        return RATE_LIMIT_OK;
    };
}
