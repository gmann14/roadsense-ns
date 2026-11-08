// Cache-Control for the public, read-only JSON GETs. The Cloudflare worker
// (cloudflare/api-proxy/src/worker.js, JSON_CACHE_ROUTES) edge-caches these
// routes for the same number of seconds; keep the two in step.
export const PUBLIC_JSON_CACHE_CONTROL_SHORT = "public, max-age=60, s-maxage=60";
export const PUBLIC_JSON_CACHE_CONTROL_MEDIUM = "public, max-age=300, s-maxage=300";

// x-request-id is client-supplied, echoed in responses and logs, and stored
// with feedback rows, so it is bounded (review 2026-10-18 P2: "x-request-id
// is stored unbounded"). Anything longer than 64 characters or outside a
// conservative token charset is replaced with a fresh UUID.
const REQUEST_ID_RE = /^[A-Za-z0-9._:-]{1,64}$/;

export function isSafeRequestId(value: string | null | undefined): value is string {
    return typeof value === "string" && REQUEST_ID_RE.test(value);
}

export function requestIdFrom(req: Request): string {
    const incoming = req.headers.get("x-request-id");
    return isSafeRequestId(incoming) ? incoming : crypto.randomUUID();
}

export function jsonResponse(
    body: unknown,
    status = 200,
    extraHeaders: HeadersInit = {},
    requestId?: string,
) {
    const headers = new Headers(extraHeaders);
    headers.set("content-type", "application/json; charset=utf-8");
    if (requestId) {
        headers.set("x-request-id", requestId);
    }

    return new Response(JSON.stringify(body), {
        status,
        headers,
    });
}

// Every 503 tells the client when to come back (review 2026-10-18: "503s
// without Retry-After"). Handlers with a better estimate (rate-limit window,
// feature gates) pass their own header; everything else gets this default.
export const DEFAULT_SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS = 30;

/// Adds the default Retry-After to a 503 that lacks one. Returns the headers
/// unchanged for any other status.
export function withServiceUnavailableRetryAfter(status: number, headers: Headers): Headers {
    if (status === 503 && !headers.has("retry-after")) {
        headers.set("Retry-After", String(DEFAULT_SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS));
    }
    return headers;
}

export function errorResponse(
    error: string,
    message: string,
    status: number,
    requestId: string,
    extraBody: Record<string, unknown> = {},
    extraHeaders: HeadersInit = {},
) {
    return jsonResponse(
        {
            error,
            message,
            request_id: requestId,
            ...extraBody,
        },
        status,
        withServiceUnavailableRetryAfter(status, new Headers(extraHeaders)),
        requestId,
    );
}
