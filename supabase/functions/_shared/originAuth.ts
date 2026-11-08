// Worker -> origin authentication (review 2026-10-18 P0-4).
//
// The Railway origin URL is public (it is in wrangler.toml), so anything the
// Cloudflare worker asserts about a request -- most importantly the real
// client IP in `x-client-ip` -- is only trustworthy when the request provably
// came through the worker. The worker proves that by sending
// `x-origin-auth: <ORIGIN_SHARED_SECRET>` on every origin request (and by
// stripping any client-supplied copy of the header first). The gateway reads
// the same secret from its own env and compares in constant time.
//
// Rollout modes (deploy-order safe):
//   - ORIGIN_SHARED_SECRET unset: x-client-ip is never trusted; client IPs
//     come from the existing x-forwarded-for logic. No request is rejected.
//   - ORIGIN_SHARED_SECRET set: x-client-ip is trusted only on requests that
//     carry a matching x-origin-auth. Requests without it are still served
//     (they just fall back to x-forwarded-for).
//   - ORIGIN_SHARED_SECRET set AND REQUIRE_ORIGIN_AUTH=true: requests without
//     a matching x-origin-auth get 403, except the unauthenticated /health
//     liveness probe so Railway healthchecks keep working.

import { constantTimeEquals } from "./apikey.ts";

export const ORIGIN_AUTH_HEADER = "x-origin-auth";

/// Read per call (same reasoning as configuredApiKey() in server.ts): cheap,
/// and lets tests mutate the env mid-suite.
export function configuredOriginSecret(): string {
    return (Deno.env.get("ORIGIN_SHARED_SECRET") ?? "").trim();
}

/// True only when a secret is configured AND enforcement is explicitly on.
/// Enforcing without a secret would lock out every caller, so a missing
/// secret always wins and disables enforcement.
export function originAuthRequired(secret: string = configuredOriginSecret()): boolean {
    return secret.length > 0 && (Deno.env.get("REQUIRE_ORIGIN_AUTH") ?? "").trim().toLowerCase() === "true";
}

/// True when the request carries the worker's shared secret. Always false
/// when no secret is configured, so an unset secret can never be "matched" by
/// an empty header.
export function hasValidOriginAuth(
    headers: Headers,
    secret: string = configuredOriginSecret(),
): boolean {
    if (secret.length === 0) return false;
    const presented = headers.get(ORIGIN_AUTH_HEADER);
    if (presented === null || presented.length === 0) return false;
    return constantTimeEquals(presented, secret);
}
