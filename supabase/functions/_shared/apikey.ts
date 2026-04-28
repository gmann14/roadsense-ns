// Shared-secret apikey verification for the standalone service.
//
// Replaces Supabase's JWT-based anon auth with a simpler shared secret. The
// real protection is still per-handler input validation + per-IP rate limits;
// this just stops random internet scanners from filling logs.

export type ApiKeyResult =
    | { ok: true }
    | { ok: false; status: 401; error: "missing_apikey" | "invalid_apikey" };

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
function constantTimeEquals(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let mismatch = 0;
    for (let i = 0; i < a.length; i++) {
        mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return mismatch === 0;
}
