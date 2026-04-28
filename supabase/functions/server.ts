// Single Deno entrypoint for the Railway-hosted Edge service.
//
// Mounts every existing function handler under its current /functions/v1/...
// path so the iOS and web clients require zero changes. URL routing via the
// built-in URLPattern API; no router library needed.

import { dispatch, route, type RouteHandler } from "./_shared/routes.ts";
import { verifyApiKey } from "./_shared/apikey.ts";
import { createStatsHandler } from "./stats/handler.ts";
import { createPgFetchStats } from "./stats/pgRuntime.ts";

const PUBLIC_API_KEY = Deno.env.get("PUBLIC_API_KEY") ?? "";

// Handlers are filled in phase-by-phase. notImplemented stubs keep the route
// table valid; tests rely on the 501 baseline for non-ported routes.
async function notImplemented(_req: Request): Promise<Response> {
    return new Response(
        JSON.stringify({ error: "not_implemented", message: "Handler not yet ported" }),
        { status: 501, headers: { "content-type": "application/json; charset=utf-8" } },
    );
}

// Each ported handler is built lazily on first call so tests can import this
// module without a live DATABASE_URL. Subsequent calls reuse the same instance.
function lazy<T>(factory: () => T): () => T {
    let cached: T | null = null;
    return () => {
        if (cached === null) cached = factory();
        return cached;
    };
}

const getStatsHandler = lazy(() =>
    createStatsHandler({ fetchStats: createPgFetchStats() })
);
const handleStats: RouteHandler = (req) => getStatsHandler()(req);

export const ROUTES = [
    route("/functions/v1/health", notImplemented),
    route("/functions/v1/upload-readings", notImplemented),
    route("/functions/v1/pothole-actions", notImplemented),
    route("/functions/v1/feedback", notImplemented),
    route("/functions/v1/stats", handleStats),
    route("/functions/v1/segments-worst", notImplemented),
    route("/functions/v1/segments/:id", notImplemented),
    route("/functions/v1/potholes", notImplemented),
    route("/functions/v1/tiles/coverage/:z/:x/:y.mvt", notImplemented),
    route("/functions/v1/tiles/:z/:x/:y.mvt", notImplemented),
] as const;

export async function handleRequest(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") {
        return new Response(null, {
            status: 204,
            headers: corsHeaders(),
        });
    }

    const auth = verifyApiKey(req, PUBLIC_API_KEY);
    if (!auth.ok) {
        return new Response(
            JSON.stringify({ error: auth.error }),
            {
                status: auth.status,
                headers: {
                    "content-type": "application/json; charset=utf-8",
                    ...corsHeaders(),
                },
            },
        );
    }

    const response = await dispatch(ROUTES, req);
    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(corsHeaders())) {
        if (!headers.has(key)) headers.set(key, value);
    }
    return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
    });
}

function corsHeaders(): Record<string, string> {
    return {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
        "access-control-allow-headers": "content-type, apikey, authorization, x-request-id",
        "access-control-max-age": "86400",
    };
}

// Boot only when run as the main module (not when imported by tests).
if (import.meta.main) {
    const port = Number(Deno.env.get("PORT") ?? "8000");
    console.log(`server starting on :${port}`);
    Deno.serve({ port }, handleRequest);
}
