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
const TILE_EDGE_CACHE_TTL_SECONDS = 3600;

// True only for the public read-only tile routes: either the tiles.* subdomain
// serving /{z}/{x}/{y}.mvt, or api.* proxying the same path shape under
// /functions/v1/tiles/... (and the coverage-tile variant). Deliberately
// narrow — routes like upload-readings/pothole-actions/feedback must never be
// edge-cached, so this only matches paths that look like tile fetches.
function isCacheableTileRequest(request, url) {
    if (request.method !== "GET") return false;

    if (url.hostname === "tiles.nsroadsense.ca" && TILE_PATH_RE.test(url.pathname)) {
        return true;
    }

    return /\/functions\/v1\/tiles(\/coverage)?\/\d+\/\d+\/\d+\.mvt$/.test(url.pathname);
}

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

// Replaces any client-supplied x-origin-auth / x-client-ip with the values
// only this worker may assert. ORIGIN_SHARED_SECRET is a Worker secret
// (`wrangler secret put ORIGIN_SHARED_SECRET`); when it is not configured the
// header is simply omitted and the gateway falls back to x-forwarded-for.
function applyOriginTrustHeaders(forwardHeaders, request, env) {
    forwardHeaders.delete("x-origin-auth");
    forwardHeaders.delete("x-client-ip");

    const secret = typeof env?.ORIGIN_SHARED_SECRET === "string" ? env.ORIGIN_SHARED_SECRET.trim() : "";
    if (secret.length > 0) {
        forwardHeaders.set("x-origin-auth", secret);
    }

    const realClientIp = request.headers.get("cf-connecting-ip");
    if (realClientIp) {
        forwardHeaders.set("x-client-ip", realClientIp);
    }
}

function corsHeaders() {
    return {
        "access-control-allow-origin": "*",
        "access-control-allow-headers": "content-type, apikey, authorization, x-request-id",
        "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
        "access-control-max-age": "86400",
    };
}

// Exported for tests only (see worker_test.ts) — Cloudflare's runtime just
// uses the default export below.
export { applyOriginTrustHeaders, buildOriginURL, isCacheableTileRequest, pickApiKey };

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

        // Preserve the real client IP under a header only we can set. Cloudflare
        // rewrites `cf-connecting-ip` on every hop, so by the time this worker's
        // *own* outbound fetch reaches Railway, a naive "trust cf-connecting-ip"
        // read there would actually see our worker's egress IP, not the client's.
        // `x-client-ip` is a name the public internet has no reason to send us
        // and Cloudflare doesn't special-case, so anything a client sets on the
        // inbound request is overwritten here before we forward — the gateway
        // only ever sees the value we assign.
        //
        // The gateway only believes x-client-ip when the same request carries
        // x-origin-auth matching its ORIGIN_SHARED_SECRET (review 2026-10-18
        // P0-4: the Railway origin URL is public, so the header alone proves
        // nothing). Any client-supplied copy of either header is dropped here
        // first, so only values this worker assigns ever reach the origin.
        applyOriginTrustHeaders(forwardHeaders, request, env);

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

        // Tile responses are the only routes we advertise as edge-cached (see
        // module comment above). Cloudflare's default cache only keys off
        // well-known extensions, and `.mvt` isn't one of them, so without this
        // explicit `cf` directive every tile request was silently passing
        // through to origin on every request despite the "cache at the edge
        // for 1 hour" comment. Scope this narrowly to GET tile requests so
        // routes like upload-readings/pothole-actions/feedback are never
        // cached.
        if (isCacheableTileRequest(request, new URL(request.url))) {
            init.cf = {
                cacheEverything: true,
                cacheTtl: TILE_EDGE_CACHE_TTL_SECONDS,
            };
        }

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
