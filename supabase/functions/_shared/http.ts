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
        extraHeaders,
        requestId,
    );
}
