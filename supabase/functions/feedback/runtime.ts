import { secondsUntilNextUtcHour, type RpcResponse } from "../upload-readings/runtime.ts";

export function createFeedbackRateLimitChecker(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
    nowFactory: () => Date = () => new Date(),
) {
    return async (ip: string) => {
        const now = nowFactory();
        const hourBucket = new Date(Date.UTC(
            now.getUTCFullYear(),
            now.getUTCMonth(),
            now.getUTCDate(),
            now.getUTCHours(),
        ));

        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `feedback-ip:${ip}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: 10,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "feedback ip rate limit RPC failed");
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
