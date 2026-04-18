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
