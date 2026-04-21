import { secondsUntilNextUtcDay, secondsUntilNextUtcHour, type RpcResponse } from "../upload-readings/runtime.ts";

export function createPotholeActionRateLimitChecker(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
    nowFactory: () => Date = () => new Date(),
) {
    return async (tokenHashHex: string, ip: string) => {
        const now = nowFactory();
        const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
        const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));

        const deviceResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-action-device:${tokenHashHex}`,
            p_bucket_start: dayBucket.toISOString(),
            p_limit: 60,
        });
        if (deviceResult.error) {
            throw new Error(deviceResult.error.message ?? "pothole action device rate limit RPC failed");
        }
        if (!deviceResult.data) {
            return {
                ok: false as const,
                retryAfterSeconds: secondsUntilNextUtcDay(now),
            };
        }

        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-action-ip:${ip}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: 120,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "pothole action ip rate limit RPC failed");
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
