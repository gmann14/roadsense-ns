// Deno-executable tests for the Cloudflare Worker proxy logic (worker.js).
//
// The worker itself only runs under the Cloudflare `workerd` runtime, but its
// pure request/URL-shaping helpers (buildOriginURL, isCacheableTileRequest,
// pickApiKey) use only standard Fetch API globals (Request/Headers/URL),
// which Deno also implements — so we can unit test them directly with `deno
// test` alongside the rest of the API layer's test suite, without adding a
// separate JS test runner/toolchain for this one file.
import { assertEquals } from "jsr:@std/assert";
import { buildOriginURL, isCacheableTileRequest, pickApiKey } from "./worker.js";

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
    assertEquals(result.pathname, "/functions/v1/tiles/14/5299/5915.mvt");
    assertEquals(result.searchParams.has("apikey"), false);
});

Deno.test("buildOriginURL passes through api.* paths unchanged aside from apikey stripping", () => {
    const result = buildOriginURL(ENV, "https://api.nsroadsense.ca/functions/v1/upload-readings?apikey=secret&foo=bar");
    assertEquals(result.pathname, "/functions/v1/upload-readings");
    assertEquals(result.searchParams.get("foo"), "bar");
    assertEquals(result.searchParams.has("apikey"), false);
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
