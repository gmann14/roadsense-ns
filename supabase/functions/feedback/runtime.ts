import { createHourlyIpRateLimitChecker, type RateLimitResult, type RateLimitRpc } from "../_shared/rateLimit.ts";

const FEEDBACK_IP_LIMIT_PER_HOUR = 10;

export function createFeedbackRateLimitChecker(
    rpc: RateLimitRpc,
    nowFactory: () => Date = () => new Date(),
): (ip: string) => Promise<RateLimitResult> {
    return createHourlyIpRateLimitChecker(rpc, {
        keyPrefix: "feedback-ip",
        limitPerHour: FEEDBACK_IP_LIMIT_PER_HOUR,
        nowFactory,
    });
}
