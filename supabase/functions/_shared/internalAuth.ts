import { constantTimeEquals } from "./apikey.ts";

export function isAuthorizedInternalRequest(headers: Headers, expectedSecret: string): boolean {
    if (!expectedSecret) {
        return false;
    }

    const authorization = headers.get("authorization") ?? "";
    const bearerToken = authorization.startsWith("Bearer ")
        ? authorization.slice("Bearer ".length).trim()
        : "";
    const apiKey = headers.get("apikey")?.trim() ?? "";

    // Constant-time comparison (P1-6) — matches the guard already used for
    // the public apikey check (_shared/apikey.ts) instead of a `===` that
    // can leak timing information about the service-role secret.
    return constantTimeEquals(bearerToken, expectedSecret) || constantTimeEquals(apiKey, expectedSecret);
}
