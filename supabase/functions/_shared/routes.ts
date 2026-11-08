// URL-pattern routing for the single-entrypoint Deno service.
//
// Each route is { path, pattern, handler }. The handler receives the original
// Request plus a `params` map populated from URLPattern named groups. Matching
// the FIRST pattern wins (declaration order); list more specific patterns
// before generic ones.

export type RouteHandler = (req: Request, params: Record<string, string>) => Promise<Response>;

export type Route = {
    // The path template the route was declared with. Request logging uses it
    // instead of the concrete URL so ids, tile coordinates and query strings
    // never reach the logs.
    path: string;
    pattern: URLPattern;
    handler: RouteHandler;
};

export type RouteMatch = {
    route: Route;
    params: Record<string, string>;
};

/// Builds a route from a path template like "/functions/v1/segments/:id".
export function route(path: string, handler: RouteHandler): Route {
    return { path, pattern: new URLPattern({ pathname: path }), handler };
}

/// First route (declaration order) whose pattern matches the URL, with its
/// named groups as params; null when nothing matches.
export function matchRoute(routes: readonly Route[], url: string): RouteMatch | null {
    for (const candidate of routes) {
        const result = candidate.pattern.exec(url);
        if (result) {
            const groups: Record<string, string | undefined> = result.pathname.groups ?? {};
            const params: Record<string, string> = {};
            for (const [key, value] of Object.entries(groups)) {
                if (typeof value === "string") {
                    params[key] = value;
                }
            }
            return { route: candidate, params };
        }
    }
    return null;
}

/// Runs an already-computed match, or the 404 fallback when there is none.
/// server.ts matches once up front so its request log can name the route.
export function dispatchMatch(
    match: RouteMatch | null,
    req: Request,
    notFound: (req: Request) => Promise<Response> = defaultNotFound,
): Promise<Response> {
    return match ? match.route.handler(req, match.params) : notFound(req);
}

/// Tries each route in order; returns the first match's handler invocation, or
/// 404 if no route matched.
export function dispatch(
    routes: readonly Route[],
    req: Request,
    notFound: (req: Request) => Promise<Response> = defaultNotFound,
): Promise<Response> {
    return dispatchMatch(matchRoute(routes, req.url), req, notFound);
}

function defaultNotFound(_req: Request): Promise<Response> {
    return Promise.resolve(
        new Response(JSON.stringify({ error: "not_found" }), {
            status: 404,
            headers: { "content-type": "application/json; charset=utf-8" },
        }),
    );
}
