// Deno-executable tests for the Cloudflare Worker proxy logic (worker.js).
//
// The worker itself only runs under the Cloudflare `workerd` runtime, but its
// pure request/URL-shaping helpers (buildOriginURL, isCacheableTileRequest,
// pickApiKey) use only standard Fetch API globals (Request/Headers/URL),
// which Deno also implements — so we can unit test them directly with `deno
// test` alongside the rest of the API layer's test suite, without adding a
// separate JS test runner/toolchain for this one file.
import { assertEquals } from "jsr:@std/assert";
import {
    applyOriginTrustHeaders,
    buildOriginURL,
    edgeCacheTtlByStatus,
    handleRequest,
    isCacheableTileRequest,
    pickApiKey,
    planOriginRequest,
} from "./worker.js";

const ENV = { ORIGIN_BASE: "https://api-production-075e9.up.railway.app" };

// ── isCacheableTileRequest: P1-3 edge caching should be scoped narrowly ──

Deno.test("isCacheableTileRequest is true for tiles.* GET requests matching the tile path shape", () => {
    const req = new Request("https://tiles.nsroadsense.ca/14/5299/5915.mvt", { method: "GET" });
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), true);
});

Deno.test("isCacheableTileRequest is true for api.* GET requests to /functions/v1/tiles/...", () => {
    const req = new Request(
        "https://api.nsroadsense.ca/functions/v1/tiles/14/5299/5915.mvt",
        { method: "GET" },
    );
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), true);
});

Deno.test("isCacheableTileRequest is true for the coverage-tile variant", () => {
    const req = new Request(
        "https://api.nsroadsense.ca/functions/v1/tiles/coverage/14/5299/5915.mvt",
        { method: "GET" },
    );
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), true);
});

Deno.test("isCacheableTileRequest is false for non-GET methods even on a tile path", () => {
    const req = new Request("https://tiles.nsroadsense.ca/14/5299/5915.mvt", { method: "POST" });
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), false);
});

Deno.test("isCacheableTileRequest is false for non-tile routes like upload-readings", () => {
    const req = new Request(
        "https://api.nsroadsense.ca/functions/v1/upload-readings",
        { method: "POST" },
    );
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), false);

    const getReq = new Request(
        "https://api.nsroadsense.ca/functions/v1/stats",
        { method: "GET" },
    );
    assertEquals(isCacheableTileRequest(getReq, new URL(getReq.url)), false);
});

Deno.test("isCacheableTileRequest is false for malformed tile coordinates", () => {
    const req = new Request("https://tiles.nsroadsense.ca/abc/def/ghi.mvt", { method: "GET" });
    assertEquals(isCacheableTileRequest(req, new URL(req.url)), false);
});

// ── buildOriginURL: sanity check that the rewrite still functions ──

Deno.test("buildOriginURL rewrites tiles.* paths under /functions/v1/tiles", () => {
    const result = buildOriginURL(ENV, "https://tiles.nsroadsense.ca/14/5299/5915.mvt?apikey=secret");
    assertEquals(result?.pathname, "/functions/v1/tiles/14/5299/5915.mvt");
    assertEquals(result?.searchParams.has("apikey"), false);
});

Deno.test("buildOriginURL passes through api.* paths unchanged aside from apikey stripping", () => {
    const result = buildOriginURL(ENV, "https://api.nsroadsense.ca/functions/v1/upload-readings?apikey=secret&foo=bar");
    assertEquals(result?.pathname, "/functions/v1/upload-readings");
    assertEquals(result?.searchParams.get("foo"), "bar");
    assertEquals(result?.searchParams.has("apikey"), false);
});

// ── pickApiKey: unchanged behavior, quick regression guard ──

Deno.test("pickApiKey prefers query string, then apikey header, then bearer auth", () => {
    const queryReq = new Request("https://api.nsroadsense.ca/x?apikey=from-query");
    assertEquals(pickApiKey(queryReq), "from-query");

    const headerReq = new Request("https://api.nsroadsense.ca/x", {
        headers: { apikey: "from-header" },
    });
    assertEquals(pickApiKey(headerReq), "from-header");

    const bearerReq = new Request("https://api.nsroadsense.ca/x", {
        headers: { authorization: "Bearer from-bearer" },
    });
    assertEquals(pickApiKey(bearerReq), "from-bearer");

    const noneReq = new Request("https://api.nsroadsense.ca/x");
    assertEquals(pickApiKey(noneReq), null);
});

// ── applyOriginTrustHeaders: worker -> origin authentication (review P0-4) ──

Deno.test("applyOriginTrustHeaders strips client-supplied x-origin-auth and x-client-ip", () => {
    const request = new Request("https://api.nsroadsense.ca/functions/v1/stats", {
        headers: { "x-origin-auth": "attacker-guess", "x-client-ip": "6.6.6.6" },
    });
    const forward = new Headers(request.headers);
    applyOriginTrustHeaders(forward, request, { ORIGIN_SHARED_SECRET: "" });
    assertEquals(forward.has("x-origin-auth"), false);
    assertEquals(forward.has("x-client-ip"), false);
});

Deno.test("applyOriginTrustHeaders sets the shared secret and the real client IP", () => {
    const request = new Request("https://api.nsroadsense.ca/functions/v1/stats", {
        headers: {
            "x-origin-auth": "attacker-guess",
            "x-client-ip": "6.6.6.6",
            "cf-connecting-ip": "203.0.113.50",
        },
    });
    const forward = new Headers(request.headers);
    applyOriginTrustHeaders(forward, request, { ORIGIN_SHARED_SECRET: "worker-secret" });
    assertEquals(forward.get("x-origin-auth"), "worker-secret");
    assertEquals(forward.get("x-client-ip"), "203.0.113.50");
});

Deno.test("applyOriginTrustHeaders omits x-origin-auth when the secret binding is missing", () => {
    const request = new Request("https://api.nsroadsense.ca/functions/v1/stats", {
        headers: { "cf-connecting-ip": "203.0.113.50" },
    });
    const forward = new Headers(request.headers);
    applyOriginTrustHeaders(forward, request, {});
    assertEquals(forward.has("x-origin-auth"), false);
    assertEquals(forward.get("x-client-ip"), "203.0.113.50");
});

// ── Canonical cache keys (review: tile cache can be busted) ──

function plannedUrl(url: string, method = "GET"): string | null {
    const plan = planOriginRequest(ENV, new Request(url, { method }));
    return plan.kind === "proxy" ? plan.url.toString() : null;
}

Deno.test("tile cache key normalizes zero-padded z/x/y and drops every query param", () => {
    const canonical = "https://api-production-075e9.up.railway.app/functions/v1/tiles/8/80/90.mvt";
    assertEquals(plannedUrl("https://api.nsroadsense.ca/functions/v1/tiles/08/080/090.mvt?bust=1"), canonical);
    assertEquals(plannedUrl("https://api.nsroadsense.ca/functions/v1/tiles/8/80/90.mvt?apikey=k&v=7"), canonical);
    assertEquals(plannedUrl("https://tiles.nsroadsense.ca/0008/80/90.mvt?apikey=k"), canonical);
});

Deno.test("coverage tile cache key is normalized the same way", () => {
    assertEquals(
        plannedUrl("https://api.nsroadsense.ca/functions/v1/tiles/coverage/014/05299/05915.mvt?x=1"),
        "https://api-production-075e9.up.railway.app/functions/v1/tiles/coverage/14/5299/5915.mvt",
    );
});

Deno.test("non-numeric or out-of-range tile coordinates are rejected at the edge", () => {
    for (
        const url of [
            "https://api.nsroadsense.ca/functions/v1/tiles/abc/1/2.mvt",
            "https://api.nsroadsense.ca/functions/v1/tiles/1e1/1/2.mvt",
            "https://api.nsroadsense.ca/functions/v1/tiles/-1/0/0.mvt",
            "https://api.nsroadsense.ca/functions/v1/tiles/23/0/0.mvt",
            "https://api.nsroadsense.ca/functions/v1/tiles/2/4/0.mvt",
            "https://api.nsroadsense.ca/functions/v1/tiles/coverage/2/0/4.mvt",
            "https://tiles.nsroadsense.ca/abc/def/ghi.mvt",
            "https://tiles.nsroadsense.ca/99999999999/0/0.mvt",
        ]
    ) {
        assertEquals(planOriginRequest(ENV, new Request(url)).kind, "not_found", url);
    }
});

Deno.test("tile requests are edge-cached for an hour; POSTs to a tile path are not", () => {
    const get = planOriginRequest(ENV, new Request("https://tiles.nsroadsense.ca/14/5299/5915.mvt"));
    assertEquals(get.kind === "proxy" ? get.cacheTtlSeconds : "not_found", 3600);
    const post = planOriginRequest(ENV, new Request("https://tiles.nsroadsense.ca/14/5299/5915.mvt", { method: "POST" }));
    assertEquals(post.kind === "proxy" ? post.cacheTtlSeconds : "not_found", null);
});

Deno.test("public JSON GETs get short TTLs and canonical, whitelisted, sorted query params", () => {
    const cases: Array<[string, string, number]> = [
        ["https://api.nsroadsense.ca/functions/v1/stats?apikey=k&bust=9", "/functions/v1/stats", 300],
        [
            "https://api.nsroadsense.ca/functions/v1/segments-worst?municipality=%20Halifax%20&utm=x&limit=010",
            "/functions/v1/segments-worst?limit=10&municipality=Halifax",
            300,
        ],
        ["https://api.nsroadsense.ca/functions/v1/top-potholes?limit=05&z=1", "/functions/v1/top-potholes?limit=5", 300],
        ["https://api.nsroadsense.ca/functions/v1/top-potholes?limit=", "/functions/v1/top-potholes", 300],
        [
            "https://api.nsroadsense.ca/functions/v1/potholes?bbox=-63.600, 44.640,-63.5500,44.6600&cb=1",
            "/functions/v1/potholes?bbox=-63.6%2C44.64%2C-63.55%2C44.66",
            60,
        ],
        [
            "https://api.nsroadsense.ca/functions/v1/segments/C8A1B2D3-0000-4000-8000-00000000ABCD?x=1",
            "/functions/v1/segments/c8a1b2d3-0000-4000-8000-00000000abcd",
            60,
        ],
    ];
    for (const [input, expectedPathAndQuery, ttl] of cases) {
        const plan = planOriginRequest(ENV, new Request(input));
        if (plan.kind !== "proxy") throw new Error(`expected proxy for ${input}`);
        assertEquals(`${plan.url.pathname}${plan.url.search}`, expectedPathAndQuery, input);
        assertEquals(plan.cacheTtlSeconds, ttl, input);
    }
});

Deno.test("malformed public-GET params pass through unchanged so the origin can 400 them", () => {
    const plan = planOriginRequest(ENV, new Request("https://api.nsroadsense.ca/functions/v1/potholes?bbox=nope"));
    if (plan.kind !== "proxy") throw new Error("expected proxy");
    assertEquals(plan.url.searchParams.get("bbox"), "nope");
});

Deno.test("writes, health and unknown routes are never edge-cached", () => {
    for (
        const [url, method] of [
            ["https://api.nsroadsense.ca/functions/v1/upload-readings", "POST"],
            ["https://api.nsroadsense.ca/functions/v1/feedback", "POST"],
            ["https://api.nsroadsense.ca/functions/v1/health", "GET"],
            ["https://api.nsroadsense.ca/functions/v1/stats", "HEAD"],
            ["https://api.nsroadsense.ca/functions/v1/some-future-route?a=1", "GET"],
        ]
    ) {
        const plan = planOriginRequest(ENV, new Request(url, { method }));
        assertEquals(plan.kind === "proxy" ? plan.cacheTtlSeconds : "not_found", null, `${method} ${url}`);
    }
});

Deno.test("edgeCacheTtlByStatus caches successes, briefly caches 404, and never caches other errors", () => {
    assertEquals(edgeCacheTtlByStatus(3600), {
        "200-299": 3600,
        "404": 60,
        "400-403": -1,
        "405-599": -1,
    });
});

// ── handleRequest end to end with a stubbed origin fetch ──

type Captured = { url: string; init: RequestInit & { cf?: Record<string, unknown> } };

function stubFetch(response: () => Response | Promise<Response>) {
    const calls: Captured[] = [];
    const impl = (input: string, init: Captured["init"]) => {
        calls.push({ url: input, init });
        return Promise.resolve(response());
    };
    return { calls, impl };
}

Deno.test("handleRequest sends cacheTtlByStatus (not cacheTtl) for tile requests", async () => {
    const { calls, impl } = stubFetch(() => new Response(new Uint8Array([1]), { status: 200 }));
    const res = await handleRequest(
        new Request("https://tiles.nsroadsense.ca/08/080/090.mvt?apikey=k&bust=1"),
        { ...ENV, ORIGIN_SHARED_SECRET: "s" },
        impl,
    );
    assertEquals(res.status, 200);
    assertEquals(calls.length, 1);
    assertEquals(calls[0].url, "https://api-production-075e9.up.railway.app/functions/v1/tiles/8/80/90.mvt");
    assertEquals(calls[0].init.cf, { cacheEverything: true, cacheTtlByStatus: edgeCacheTtlByStatus(3600) });
    const headers = new Headers(calls[0].init.headers);
    assertEquals(headers.get("apikey"), "k");
    assertEquals(headers.get("x-origin-auth"), "s");
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
});

Deno.test("handleRequest does not attach cf cache options to writes", async () => {
    const { calls, impl } = stubFetch(() => new Response("{}", { status: 200 }));
    await handleRequest(
        new Request("https://api.nsroadsense.ca/functions/v1/upload-readings", {
            method: "POST",
            headers: { apikey: "k" },
            body: "{}",
        }),
        ENV,
        impl,
    );
    assertEquals(calls[0].init.cf, undefined);
});

Deno.test("handleRequest answers invalid tile coordinates with 404 without calling the origin", async () => {
    const { calls, impl } = stubFetch(() => new Response(null, { status: 200 }));
    const res = await handleRequest(
        new Request("https://api.nsroadsense.ca/functions/v1/tiles/abc/0/0.mvt", { headers: { apikey: "k" } }),
        ENV,
        impl,
    );
    assertEquals(res.status, 404);
    assertEquals(calls.length, 0);
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
});

Deno.test("handleRequest returns a JSON 502 with CORS headers when the origin fetch throws", async () => {
    const res = await handleRequest(
        new Request("https://api.nsroadsense.ca/functions/v1/stats", {
            headers: { apikey: "k", "x-request-id": "req-502" },
        }),
        ENV,
        () => Promise.reject(new TypeError("network connection lost")),
    );
    assertEquals(res.status, 502);
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
    assertEquals(res.headers.get("x-request-id"), "req-502");
    const body = await res.json();
    assertEquals(body.error, "upstream_unavailable");
    assertEquals(body.request_id, "req-502");
});

Deno.test("handleRequest replaces an oversized or unsafe x-request-id before forwarding", async () => {
    const { calls, impl } = stubFetch(() => new Response("{}", { status: 200 }));
    await handleRequest(
        new Request("https://api.nsroadsense.ca/functions/v1/stats", {
            headers: { apikey: "k", "x-request-id": "x".repeat(65) },
        }),
        ENV,
        impl,
    );
    const forwarded = new Headers(calls[0].init.headers).get("x-request-id") ?? "";
    assertEquals(forwarded.length, 36);
});

Deno.test("handleRequest still 401s without any apikey", async () => {
    const { calls, impl } = stubFetch(() => new Response("{}", { status: 200 }));
    const res = await handleRequest(new Request("https://api.nsroadsense.ca/functions/v1/stats"), ENV, impl);
    assertEquals(res.status, 401);
    assertEquals((await res.json()).error, "missing_apikey");
    assertEquals(calls.length, 0);
});
