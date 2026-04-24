import { secondsUntilNextUtcDay, secondsUntilNextUtcHour, type RpcResponse } from "../upload-readings/runtime.ts";

export function createPotholePhotoRateLimitChecker(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
    nowFactory: () => Date = () => new Date(),
) {
    return async (tokenHashHex: string, ip: string) => {
        const now = nowFactory();
        const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
        const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));

        const deviceResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-photo-device:${tokenHashHex}`,
            p_bucket_start: dayBucket.toISOString(),
            p_limit: 20,
        });
        if (deviceResult.error) {
            throw new Error(deviceResult.error.message ?? "pothole photo device rate limit RPC failed");
        }
        if (!deviceResult.data) {
            return {
                ok: false as const,
                retryAfterSeconds: secondsUntilNextUtcDay(now),
            };
        }

        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `pothole-photo-ip:${ip}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: 40,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "pothole photo ip rate limit RPC failed");
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
