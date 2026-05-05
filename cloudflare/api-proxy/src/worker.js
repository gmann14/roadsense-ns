// Edge proxy for the RoadSense NS Railway-hosted API.
//
// Why this exists: the upstream Supabase-compatible function gateway expects the
// `apikey` value as an HTTP header. The iOS Mapbox SDK can only template
// the apikey into the URL query string when fetching tiles. This worker
// bridges the two: incoming `?apikey=...` becomes an `apikey:` header on
// the request to origin. Tiles cache at the edge for 1 hour so 99%+ of
// public reads avoid repeated browser/API auth friction.
//
// Routes (configured in wrangler.toml):
//   api.nsroadsense.ca/*    — passes everything through, with auth shim
//   tiles.nsroadsense.ca/*  — same proxy logic, different subdomain
//
// Hostname mapping at the origin:
//   api.nsroadsense.ca/foo            -> ORIGIN_BASE/foo
//   tiles.nsroadsense.ca/{z}/{x}/{y}.mvt
//                                     -> ORIGIN_BASE/functions/v1/tiles/{z}/{x}/{y}.mvt

const TILE_PATH_RE = /^\/(\d+)\/(\d+)\/(\d+)\.mvt$/;

function buildOriginURL(env, requestURL) {
    const url = new URL(requestURL);
    const origin = new URL(env.ORIGIN_BASE);

    if (url.hostname === "tiles.nsroadsense.ca" && TILE_PATH_RE.test(url.pathname)) {
        // Rewrite tile paths so callers can use the cleaner /{z}/{x}/{y}.mvt
        // shape regardless of the upstream's nested edge-functions layout.
        origin.pathname = `/functions/v1/tiles${url.pathname}`;
    } else {
        origin.pathname = url.pathname;
    }

    // Drop apikey from the query string before forwarding — it moves to
    // a header below. Keep everything else.
    const params = new URLSearchParams(url.search);
    params.delete("apikey");
    origin.search = params.toString();

    return origin;
}

function pickApiKey(request) {
    const url = new URL(request.url);
    const fromQuery = url.searchParams.get("apikey");
    if (fromQuery) return fromQuery;

    const fromHeader = request.headers.get("apikey");
    if (fromHeader) return fromHeader;

    const auth = request.headers.get("authorization") ?? "";
    if (auth.toLowerCase().startsWith("bearer ")) return auth.slice("bearer ".length).trim();

    return null;
}

function corsHeaders() {
    return {
        "access-control-allow-origin": "*",
        "access-control-allow-headers": "content-type, apikey, authorization, x-request-id",
        "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
        "access-control-max-age": "86400",
    };
}

export default {
    async fetch(request, env, _ctx) {
        if (request.method === "OPTIONS") {
            return new Response(null, { status: 204, headers: corsHeaders() });
        }

        const apiKey = pickApiKey(request);
        if (!apiKey) {
            return new Response(JSON.stringify({ error: "missing_apikey" }), {
                status: 401,
                headers: { "content-type": "application/json", ...corsHeaders() },
            });
        }

        const originURL = buildOriginURL(env, request.url);

        const forwardHeaders = new Headers(request.headers);
        forwardHeaders.set("apikey", apiKey);
        forwardHeaders.set("authorization", `Bearer ${apiKey}`);
        // Strip headers that don't make sense to forward to a different host.
        forwardHeaders.delete("host");
        forwardHeaders.delete("cf-connecting-ip");
        forwardHeaders.delete("cf-ipcountry");
        forwardHeaders.delete("cf-ray");
        forwardHeaders.delete("cf-visitor");

        const init = {
            method: request.method,
            headers: forwardHeaders,
            body: ["GET", "HEAD"].includes(request.method) ? null : request.body,
        };

        const upstream = await fetch(originURL.toString(), init);

        const responseHeaders = new Headers(upstream.headers);
        for (const [k, v] of Object.entries(corsHeaders())) {
            responseHeaders.set(k, v);
        }

        return new Response(upstream.body, {
            status: upstream.status,
            statusText: upstream.statusText,
            headers: responseHeaders,
        });
    },
};
