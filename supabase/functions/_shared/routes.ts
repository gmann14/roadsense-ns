// URL-pattern routing for the single-entrypoint Deno service.
//
// Each route is { pattern, handler }. The handler receives the original Request
// plus a `params` map populated from URLPattern named groups. Matching the FIRST
// pattern wins (declaration order); list more specific patterns before generic ones.

export type RouteHandler = (req: Request, params: Record<string, string>) => Promise<Response>;

export type Route = {
    pattern: URLPattern;
    handler: RouteHandler;
};

/// Builds a route from a path template like "/functions/v1/segments/:id".
export function route(path: string, handler: RouteHandler): Route {
    return { pattern: new URLPattern({ pathname: path }), handler };
}

/// Tries each route in order; returns the first match's handler invocation, or
/// 404 if no route matched. Provided as a dispatch helper so server.ts stays small.
export async function dispatch(
    routes: readonly Route[],
    req: Request,
    notFound: (req: Request) => Promise<Response> = defaultNotFound,
): Promise<Response> {
    for (const { pattern, handler } of routes) {
        const result = pattern.exec(req.url);
        if (result) {
            const groups = (result.pathname.groups ?? {}) as Record<string, string | undefined>;
            const params: Record<string, string> = {};
            for (const [key, value] of Object.entries(groups)) {
                if (typeof value === "string") {
                    params[key] = value;
                }
            }
            return handler(req, params);
        }
    }
    return notFound(req);
}

async function defaultNotFound(_req: Request): Promise<Response> {
    return new Response(JSON.stringify({ error: "not_found" }), {
        status: 404,
        headers: { "content-type": "application/json; charset=utf-8" },
    });
}
