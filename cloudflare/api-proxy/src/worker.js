// Edge proxy for the RoadSense NS Railway-hosted API.
//
// Why this exists: the upstream Supabase-compatible function gateway expects the
// `apikey` value as an HTTP header. The iOS Mapbox SDK can only template
// the apikey into the URL query string when fetching tiles. This worker
// bridges the two: incoming `?apikey=...` becomes an `apikey:` header on
// the request to origin.
//
// It also:
//   - authenticates itself to the origin (x-origin-auth) so the gateway can
//     trust the x-client-ip it asserts (review 2026-10-18 P0-4);
//   - edge-caches tiles (1 h) and the public read-only JSON GETs (60-300 s)
//     under canonical cache keys, never caching 4xx/5xx except a short 404;
//   - turns an unreachable origin into a JSON 502 with CORS headers instead
//     of a bare Cloudflare error page.
//
// Routes (configured in wrangler.toml):
//   api.nsroadsense.ca/*    — passes everything through, with auth shim
//   tiles.nsroadsense.ca/*  — same proxy logic, different subdomain
//
// Hostname mapping at the origin:
//   api.nsroadsense.ca/foo            -> ORIGIN_BASE/foo
//   tiles.nsroadsense.ca/{z}/{x}/{y}.mvt
//                                     -> ORIGIN_BASE/functions/v1/tiles/{z}/{x}/{y}.mvt

const TILES_HOST = "tiles.nsroadsense.ca";

// Path *shapes*. Anything that looks like a tile request but fails these
// (non-numeric or out-of-range z/x/y) is answered 404 at the edge without
// touching the origin, so junk coordinates can't be used to bust the cache.
const TILES_HOST_TILE_RE = /^\/([^/]+)\/([^/]+)\/([^/]+)\.mvt$/;
const API_TILE_RE = /^\/functions\/v1\/tiles(\/coverage)?\/([^/]+)\/([^/]+)\/([^/]+)\.mvt$/;
const API_TILE_PREFIX_RE = /^\/functions\/v1\/tiles\//;
const DIGITS_RE = /^\d{1,10}$/;
const MAX_TILE_ZOOM = 22;

const TILE_EDGE_CACHE_TTL_SECONDS = 3600;
// Short negative cache so a hot missing resource can't hammer the origin,
// short enough that a newly published segment appears within a minute.
const NOT_FOUND_EDGE_CACHE_TTL_SECONDS = 60;

const REQUEST_ID_RE = /^[A-Za-z0-9._:-]{1,64}$/;

// Public read-only JSON GETs that are safe to share between callers. Each
// entry lists the only query params the origin handler reads; everything
// else (cache busters, apikey, tracking params) is dropped, and the kept
// params are sorted and canonicalized so equivalent URLs share one cache key.
// TTLs match the Cache-Control each origin handler sends.
const JSON_CACHE_ROUTES = [
    { pattern: /^\/functions\/v1\/stats$/, ttlSeconds: 300, params: {} },
    {
        pattern: /^\/functions\/v1\/segments-worst$/,
        ttlSeconds: 300,
        params: { limit: canonicalInteger, municipality: canonicalText },
    },
    { pattern: /^\/functions\/v1\/top-potholes$/, ttlSeconds: 300, params: { limit: canonicalInteger } },
    { pattern: /^\/functions\/v1\/potholes$/, ttlSeconds: 60, params: { bbox: canonicalBbox } },
    {
        pattern: /^\/functions\/v1\/segments\/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
        ttlSeconds: 60,
        params: {},
        lowercasePath: true,
    },
];

function canonicalInteger(raw) {
    const value = raw.trim();
    return DIGITS_RE.test(value) ? String(Number.parseInt(value, 10)) : value;
}

function canonicalText(raw) {
    return raw.trim();
}

function canonicalBbox(raw) {
    const parts = raw.split(",").map((part) => part.trim());
    if (parts.length !== 4 || !parts.every((part) => /^-?\d+(\.\d+)?$/.test(part))) {
        // Leave malformed values alone: the origin answers 400, which is
        // never cached, so they can't fill the cache either.
        return raw;
    }
    return parts.map((part) => String(Number(part))).join(",");
}

// Parses z/x/y strictly: decimal digits only (leading zeros allowed and
// stripped), z within 0..22 and x/y inside the 2^z grid. Returns null for
// anything else.
function parseTileCoords(rawZ, rawX, rawY) {
    if (!DIGITS_RE.test(rawZ) || !DIGITS_RE.test(rawX) || !DIGITS_RE.test(rawY)) return null;
    const z = Number.parseInt(rawZ, 10);
    const x = Number.parseInt(rawX, 10);
    const y = Number.parseInt(rawY, 10);
    if (z < 0 || z > MAX_TILE_ZOOM) return null;
    const max = 2 ** z;
    if (x < 0 || x >= max || y < 0 || y >= max) return null;
    return { z, x, y };
}

// Status-aware edge TTLs: Cloudflare's plain `cacheTtl` caches every status
// for the full TTL, so a transient 500 (or a 401 for a bad apikey, since the
// cache key ignores the apikey) would have been served to everyone for an
// hour. Only successes are cached for the full TTL, 404 briefly, and every
// other 4xx/5xx not at all (-1).
function edgeCacheTtlByStatus(successTtlSeconds) {
    return {
        "200-299": successTtlSeconds,
        "404": NOT_FOUND_EDGE_CACHE_TTL_SECONDS,
        "400-403": -1,
        "405-599": -1,
    };
}

/**
 * @typedef {{ kind: "not_found" } | { kind: "proxy", url: URL, cacheTtlSeconds: number | null }} OriginPlan
 */

// Decides where a request goes and whether it may be edge-cached.
// Returns one of:
//   { kind: "not_found" }                          — answer 404 at the edge
//   { kind: "proxy", url: URL, cacheTtlSeconds }   — cacheTtlSeconds is null
//                                                    when the response must
//                                                    not be edge-cached
/** @returns {OriginPlan} */
function planOriginRequest(env, request) {
    const url = new URL(request.url);
    const origin = new URL(env.ORIGIN_BASE);
    const isGet = request.method === "GET";

    if (url.hostname === TILES_HOST && url.pathname.endsWith(".mvt")) {
        const match = url.pathname.match(TILES_HOST_TILE_RE);
        const coords = match ? parseTileCoords(match[1], match[2], match[3]) : null;
        if (!coords) return { kind: "not_found" };
        origin.pathname = `/functions/v1/tiles/${coords.z}/${coords.x}/${coords.y}.mvt`;
        origin.search = "";
        return { kind: "proxy", url: origin, cacheTtlSeconds: isGet ? TILE_EDGE_CACHE_TTL_SECONDS : null };
    }

    if (API_TILE_PREFIX_RE.test(url.pathname) && url.pathname.endsWith(".mvt")) {
        const match = url.pathname.match(API_TILE_RE);
        const coords = match ? parseTileCoords(match[2], match[3], match[4]) : null;
        if (!coords) return { kind: "not_found" };
        const coverage = match[1] ?? "";
        origin.pathname = `/functions/v1/tiles${coverage}/${coords.z}/${coords.x}/${coords.y}.mvt`;
        // Tiles take no query parameters at the origin. Dropping the whole
        // query string (apikey moves to a header) makes the cache key
        // canonical: `?bust=1`, `?v=7` and friends all hit the same entry.
        origin.search = "";
        return { kind: "proxy", url: origin, cacheTtlSeconds: isGet ? TILE_EDGE_CACHE_TTL_SECONDS : null };
    }

    if (isGet) {
        const route = JSON_CACHE_ROUTES.find((candidate) => candidate.pattern.test(url.pathname));
        if (route) {
            origin.pathname = route.lowercasePath ? url.pathname.toLowerCase() : url.pathname;
            const canonical = new URLSearchParams();
            for (const name of Object.keys(route.params).sort()) {
                const raw = url.searchParams.get(name);
                if (raw === null) continue;
                const value = route.params[name](raw);
                if (value.length > 0) canonical.set(name, value);
            }
            origin.search = canonical.toString();
            return { kind: "proxy", url: origin, cacheTtlSeconds: route.ttlSeconds };
        }
    }

    // Everything else (writes, health, unknown paths) passes through
    // unchanged and uncached, minus the apikey which moves to a header.
    origin.pathname = url.pathname;
    const params = new URLSearchParams(url.search);
    params.delete("apikey");
    origin.search = params.toString();
    return { kind: "proxy", url: origin, cacheTtlSeconds: null };
}

// Kept for callers/tests that only need the rewritten URL.
function buildOriginURL(env, requestURL, method = "GET") {
    const plan = planOriginRequest(env, new Request(requestURL, { method }));
    return plan.kind === "proxy" ? plan.url : null;
}

function isCacheableTileRequest(request, url) {
    if (request.method !== "GET") return false;
    if (url.hostname === TILES_HOST) {
        const match = url.pathname.match(TILES_HOST_TILE_RE);
        return Boolean(match && parseTileCoords(match[1], match[2], match[3]));
    }
    const match = url.pathname.match(API_TILE_RE);
    return Boolean(match && parseTileCoords(match[2], match[3], match[4]));
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

function requestIdFor(request) {
    const incoming = request.headers.get("x-request-id");
    return incoming && REQUEST_ID_RE.test(incoming) ? incoming : crypto.randomUUID();
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

function edgeJsonResponse(status, body, requestId) {
    return new Response(JSON.stringify({ ...body, request_id: requestId }), {
        status,
        headers: {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "x-request-id": requestId,
            ...corsHeaders(),
        },
    });
}

// `fetchImpl` is injectable for tests; Cloudflare's runtime uses the global.
async function handleRequest(request, env, fetchImpl = (input, init) => fetch(input, init)) {
    if (request.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const requestId = requestIdFor(request);

    const apiKey = pickApiKey(request);
    if (!apiKey) {
        return edgeJsonResponse(401, { error: "missing_apikey" }, requestId);
    }

    const plan = planOriginRequest(env, request);
    if (plan.kind === "not_found") {
        return edgeJsonResponse(404, { error: "not_found", message: "Tile not found." }, requestId);
    }

    const forwardHeaders = new Headers(request.headers);
    forwardHeaders.set("apikey", apiKey);
    forwardHeaders.set("authorization", `Bearer ${apiKey}`);
    forwardHeaders.set("x-request-id", requestId);

    // Preserve the real client IP under a header only we can set. Cloudflare
    // rewrites `cf-connecting-ip` on every hop, so by the time this worker's
    // *own* outbound fetch reaches Railway, a naive "trust cf-connecting-ip"
    // read there would actually see our worker's egress IP, not the client's.
    // The gateway only believes x-client-ip when the same request carries
    // x-origin-auth matching its ORIGIN_SHARED_SECRET (review 2026-10-18
    // P0-4: the Railway origin URL is public, so the header alone proves
    // nothing). Any client-supplied copy of either header is dropped first,
    // so only values this worker assigns ever reach the origin.
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

    // Cloudflare's default cache only keys off well-known extensions (not
    // `.mvt`, not JSON API paths), so caching needs an explicit `cf`
    // directive. It is only set for the read-only GET routes chosen in
    // planOriginRequest; writes are never cached. The cache key is the
    // canonical origin URL built there.
    if (plan.cacheTtlSeconds !== null) {
        init.cf = {
            cacheEverything: true,
            cacheTtlByStatus: edgeCacheTtlByStatus(plan.cacheTtlSeconds),
        };
    }

    let upstream;
    try {
        upstream = await fetchImpl(plan.url.toString(), init);
    } catch (error) {
        console.error(JSON.stringify({
            msg: "origin fetch failed",
            request_id: requestId,
            path: plan.url.pathname,
            error: error instanceof Error ? error.message : String(error),
        }));
        return edgeJsonResponse(
            502,
            { error: "upstream_unavailable", message: "The API is temporarily unreachable. Please retry." },
            requestId,
        );
    }

    const responseHeaders = new Headers(upstream.headers);
    for (const [k, v] of Object.entries(corsHeaders())) {
        responseHeaders.set(k, v);
    }
    if (!responseHeaders.has("x-request-id")) {
        responseHeaders.set("x-request-id", requestId);
    }

    return new Response(upstream.body, {
        status: upstream.status,
        statusText: upstream.statusText,
        headers: responseHeaders,
    });
}

// Exported for tests only (see worker_test.ts) — Cloudflare's runtime just
// uses the default export below.
export {
    applyOriginTrustHeaders,
    buildOriginURL,
    edgeCacheTtlByStatus,
    handleRequest,
    isCacheableTileRequest,
    pickApiKey,
    planOriginRequest,
};

export default {
    fetch(request, env, _ctx) {
        return handleRequest(request, env);
    },
};
