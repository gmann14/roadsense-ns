// Cache-Control for the public, read-only JSON GETs. The Cloudflare worker
// (cloudflare/api-proxy/src/worker.js, JSON_CACHE_ROUTES) edge-caches these
// routes for the same number of seconds; keep the two in step.
export const PUBLIC_JSON_CACHE_CONTROL_SHORT = "public, max-age=60, s-maxage=60";
export const PUBLIC_JSON_CACHE_CONTROL_MEDIUM = "public, max-age=300, s-maxage=300";

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
