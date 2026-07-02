// Shared-secret apikey verification for the standalone service.
//
// Replaces Supabase's JWT-based anon auth with a simpler shared secret. The
// real protection is still per-handler input validation + per-IP rate limits;
// this just stops random internet scanners from filling logs.

export type ApiKeyResult =
    | { ok: true }
    | { ok: false; status: 401; error: "missing_apikey" | "invalid_apikey" };

// True when running as the deployed Railway service (vs local dev / tests).
// Reuses the same env var server.ts already checks to decide whether to start
// the in-process scheduler, so "are we on Railway" is answered one way across
// the codebase.
export function isRunningOnRailway(): boolean {
    return Boolean(Deno.env.get("RAILWAY_ENVIRONMENT"));
}

// Fail closed (P1-5): on Railway, a missing/empty PUBLIC_API_KEY must never
// silently allow every request through — that's fine for local dev/tests
// (see verifyApiKey's dev-mode branch below) but on the real deployed
// service it would mean auth is effectively disabled. Call this at startup
// so a misconfigured deploy refuses to boot instead of quietly serving
// unauthenticated traffic.
export function assertApiKeyConfiguredForEnvironment(
    expectedKey: string,
    onRailway: boolean = isRunningOnRailway(),
): void {
    if (onRailway && (!expectedKey || expectedKey.trim().length === 0)) {
        throw new Error(
            "PUBLIC_API_KEY is not set. Refusing to start on Railway with auth disabled.",
        );
    }
}

export function verifyApiKey(req: Request, expectedKey: string): ApiKeyResult {
    if (!expectedKey || expectedKey.length === 0) {
        // Test/dev mode: no key configured means anything passes.
        return { ok: true };
    }

    const headerKey =
        req.headers.get("apikey") ??
        req.headers.get("Apikey") ??
        bearerFromAuthHeader(req.headers.get("authorization") ?? req.headers.get("Authorization"));

    if (!headerKey || headerKey.length === 0) {
        return { ok: false, status: 401, error: "missing_apikey" };
    }

    if (!constantTimeEquals(headerKey, expectedKey)) {
        return { ok: false, status: 401, error: "invalid_apikey" };
    }

    return { ok: true };
}

function bearerFromAuthHeader(value: string | null): string | null {
    if (!value) return null;
    const trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith("bearer ")) {
        return trimmed.slice(7).trim();
    }
    return null;
}

// Length-safe equality so we don't leak the secret length via timing. Not a
// production crypto primitive, but as good as JS string equality on a hot path.
// Exported for reuse by other shared-secret comparisons (see
// _shared/internalAuth.ts) so we don't duplicate a second, non-constant-time
// `===` comparison elsewhere in the codebase.
export function constantTimeEquals(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let mismatch = 0;
    for (let i = 0; i < a.length; i++) {
        mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return mismatch === 0;
}
