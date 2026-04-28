import { assertEquals } from "jsr:@std/assert";
import { dispatch, route } from "./_shared/routes.ts";
import { verifyApiKey } from "./_shared/apikey.ts";
import { createPgRpc } from "./_shared/pgRpc.ts";
import { isRailwayInternalUrl } from "./db.ts";
import { isValidTileCoord, MAX_TILE_ZOOM, parseTilePath } from "./tiles/handler.ts";
import { parseCoverageTilePath } from "./tiles-coverage/handler.ts";
import { handleRequest } from "./server.ts";

Deno.test("dispatch returns 404 for an unmatched URL", async () => {
    const routes = [
        route("/functions/v1/health", async () => new Response("ok")),
    ];
    const res = await dispatch(routes, new Request("http://localhost/nope"));
    assertEquals(res.status, 404);
});

Deno.test("dispatch invokes the matching route handler", async () => {
    const routes = [
        route("/functions/v1/health", async () => new Response("alive", { status: 200 })),
    ];
    const res = await dispatch(routes, new Request("http://localhost/functions/v1/health"));
    assertEquals(res.status, 200);
    assertEquals(await res.text(), "alive");
});

Deno.test("dispatch extracts named URL params", async () => {
    let captured: Record<string, string> = {};
    const routes = [
        route("/functions/v1/segments/:id", async (_req, params) => {
            captured = params;
            return new Response("ok");
        }),
    ];
    await dispatch(
        routes,
        new Request("http://localhost/functions/v1/segments/abc-123-uuid"),
    );
    assertEquals(captured.id, "abc-123-uuid");
});

Deno.test("dispatch extracts multiple path params for tile routes", async () => {
    let captured: Record<string, string> = {};
    const routes = [
        route("/functions/v1/tiles/:z/:x/:y.mvt", async (_req, params) => {
            captured = params;
            return new Response(new Uint8Array([0]));
        }),
    ];
    await dispatch(
        routes,
        new Request("http://localhost/functions/v1/tiles/14/5299/5915.mvt"),
    );
    assertEquals(captured.z, "14");
    assertEquals(captured.x, "5299");
    assertEquals(captured.y, "5915");
});

Deno.test("dispatch picks the more specific route declared first", async () => {
    let hitGeneric = false;
    let hitSpecific = false;
    const routes = [
        route("/functions/v1/tiles/coverage/:z/:x/:y.mvt", async () => {
            hitSpecific = true;
            return new Response("specific");
        }),
        route("/functions/v1/tiles/:z/:x/:y.mvt", async () => {
            hitGeneric = true;
            return new Response("generic");
        }),
    ];
    await dispatch(
        routes,
        new Request("http://localhost/functions/v1/tiles/coverage/14/5299/5915.mvt"),
    );
    assertEquals(hitSpecific, true);
    assertEquals(hitGeneric, false);
});

Deno.test("verifyApiKey accepts a matching apikey header", () => {
    const req = new Request("http://localhost/x", {
        headers: { apikey: "secret-token" },
    });
    assertEquals(verifyApiKey(req, "secret-token").ok, true);
});

Deno.test("verifyApiKey accepts a Bearer Authorization header that matches", () => {
    const req = new Request("http://localhost/x", {
        headers: { authorization: "Bearer secret-token" },
    });
    assertEquals(verifyApiKey(req, "secret-token").ok, true);
});

Deno.test("verifyApiKey rejects a missing header with 401", () => {
    const req = new Request("http://localhost/x");
    const result = verifyApiKey(req, "secret-token");
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.status, 401);
        assertEquals(result.error, "missing_apikey");
    }
});

Deno.test("verifyApiKey rejects a wrong header with 401", () => {
    const req = new Request("http://localhost/x", {
        headers: { apikey: "wrong-token" },
    });
    const result = verifyApiKey(req, "secret-token");
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.status, 401);
        assertEquals(result.error, "invalid_apikey");
    }
});

Deno.test("verifyApiKey passes everything through when no key is configured (dev mode)", () => {
    const req = new Request("http://localhost/x"); // no apikey header
    assertEquals(verifyApiKey(req, "").ok, true);
});

Deno.test("handleRequest returns 204 for OPTIONS preflight with CORS headers", async () => {
    const req = new Request("http://localhost/functions/v1/health", { method: "OPTIONS" });
    const res = await handleRequest(req);
    assertEquals(res.status, 204);
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
    assertEquals(
        res.headers.get("access-control-allow-headers")?.includes("apikey"),
        true,
    );
});

Deno.test("handleRequest applies CORS to all responses, including 404", async () => {
    const req = new Request("http://localhost/no-such-route");
    const res = await handleRequest(req);
    assertEquals(res.status, 404);
    assertEquals(res.headers.get("access-control-allow-origin"), "*");
});

Deno.test("handleRequest returns 404 for routes outside the registered set", async () => {
    const req = new Request("http://localhost/functions/v1/some-future-thing");
    const res = await handleRequest(req);
    assertEquals(res.status, 404);
});

Deno.test("handleRequest routes top-potholes through the Deno API surface", async () => {
    const previousKey = Deno.env.get("PUBLIC_API_KEY");
    const previousDatabaseUrl = Deno.env.get("DATABASE_URL");
    Deno.env.delete("PUBLIC_API_KEY");
    Deno.env.delete("DATABASE_URL");
    try {
        const res = await handleRequest(
            new Request("http://localhost/functions/v1/top-potholes?limit=1"),
        );
        assertEquals(res.status, 503);
        assertEquals((await res.json()).error, "service_unavailable");
    } finally {
        if (previousKey === undefined) Deno.env.delete("PUBLIC_API_KEY");
        else Deno.env.set("PUBLIC_API_KEY", previousKey);
        if (previousDatabaseUrl === undefined) Deno.env.delete("DATABASE_URL");
        else Deno.env.set("DATABASE_URL", previousDatabaseUrl);
    }
});

Deno.test("handleRequest blocks unauthorized requests when PUBLIC_API_KEY is set", async () => {
    const previous = Deno.env.get("PUBLIC_API_KEY");
    Deno.env.set("PUBLIC_API_KEY", "test-secret-token-1234");
    try {
        const res = await handleRequest(
            new Request("http://localhost/functions/v1/stats"),
        );
        assertEquals(res.status, 401);
    } finally {
        if (previous === undefined) Deno.env.delete("PUBLIC_API_KEY");
        else Deno.env.set("PUBLIC_API_KEY", previous);
    }
});

Deno.test("handleRequest exempts /health from apikey auth and does not touch the DB", async () => {
    const previous = Deno.env.get("PUBLIC_API_KEY");
    Deno.env.set("PUBLIC_API_KEY", "test-secret-token-1234");
    try {
        const res = await handleRequest(
            new Request("http://localhost/functions/v1/health"),
        );
        assertEquals(res.status, 200);
        const body = await res.json();
        assertEquals(body.status, "ok");
        // Critical: the lite /health must not include a DB roundtrip — that
        // would re-introduce the unauthenticated DoS surface against the pool.
        assertEquals("db" in body, false);
    } finally {
        if (previous === undefined) Deno.env.delete("PUBLIC_API_KEY");
        else Deno.env.set("PUBLIC_API_KEY", previous);
    }
});

Deno.test("handleRequest still gates /health/deep behind apikey", async () => {
    const previous = Deno.env.get("PUBLIC_API_KEY");
    Deno.env.set("PUBLIC_API_KEY", "test-secret-token-1234");
    try {
        const res = await handleRequest(
            new Request("http://localhost/functions/v1/health/deep"),
        );
        assertEquals(res.status, 401);
    } finally {
        if (previous === undefined) Deno.env.delete("PUBLIC_API_KEY");
        else Deno.env.set("PUBLIC_API_KEY", previous);
    }
});

Deno.test("handleRequest accepts requests with a matching apikey when PUBLIC_API_KEY is set", async () => {
    const previous = Deno.env.get("PUBLIC_API_KEY");
    Deno.env.set("PUBLIC_API_KEY", "test-secret-token-1234");
    try {
        const res = await handleRequest(
            new Request("http://localhost/functions/v1/some-future-thing", {
                headers: { apikey: "test-secret-token-1234" },
            }),
        );
        // Auth passes → router fires → 404 (route not in table)
        assertEquals(res.status, 404);
    } finally {
        if (previous === undefined) Deno.env.delete("PUBLIC_API_KEY");
        else Deno.env.set("PUBLIC_API_KEY", previous);
    }
});

// ── isRailwayInternalUrl: anchored hostname check ──

Deno.test("isRailwayInternalUrl matches the bare hostname and subdomains", () => {
    assertEquals(isRailwayInternalUrl("postgres://u:p@railway.internal:5432/db"), true);
    assertEquals(isRailwayInternalUrl("postgres://u:p@postgis.railway.internal:5432/db"), true);
    assertEquals(isRailwayInternalUrl("postgres://u:p@deep.nested.railway.internal:5432/db"), true);
});

Deno.test("isRailwayInternalUrl rejects spoofed hostnames that contain the substring", () => {
    // The original .includes('railway.internal') match would have accepted these.
    assertEquals(isRailwayInternalUrl("postgres://u:p@evil.railway.internal.attacker.com:5432/db"), false);
    assertEquals(isRailwayInternalUrl("postgres://u:p@railway-internal.example.com:5432/db"), false);
    assertEquals(isRailwayInternalUrl("postgres://u:p@notreallyrailway.internal.com:5432/db"), false);
});

Deno.test("isRailwayInternalUrl returns false for malformed URLs", () => {
    assertEquals(isRailwayInternalUrl("not a url"), false);
    assertEquals(isRailwayInternalUrl(""), false);
});

// ── Tile coord validation: don't pass nonsense to PostGIS ──

Deno.test("isValidTileCoord rejects out-of-range zoom", () => {
    assertEquals(isValidTileCoord(-1, 0, 0), false);
    assertEquals(isValidTileCoord(MAX_TILE_ZOOM + 1, 0, 0), false);
    assertEquals(isValidTileCoord(99, 0, 0), false);
});

Deno.test("isValidTileCoord rejects x/y outside 2^z grid", () => {
    assertEquals(isValidTileCoord(1, 2, 0), false); // max=2 at z=1
    assertEquals(isValidTileCoord(1, -1, 0), false);
    assertEquals(isValidTileCoord(0, 1, 0), false); // max=1 at z=0
});

Deno.test("isValidTileCoord accepts in-range coords at boundary zooms", () => {
    assertEquals(isValidTileCoord(0, 0, 0), true);
    assertEquals(isValidTileCoord(MAX_TILE_ZOOM, 0, 0), true);
    assertEquals(isValidTileCoord(12, 1324, 1480), true); // Halifax
});

Deno.test("parseTilePath rejects out-of-range coords with null", () => {
    assertEquals(parseTilePath("/functions/v1/tiles/99/0/0.mvt"), null);
    assertEquals(parseTilePath("/functions/v1/tiles/12/9999999/1480.mvt"), null);
});

Deno.test("parseTilePath accepts in-range coords", () => {
    assertEquals(parseTilePath("/functions/v1/tiles/14/5298/5921.mvt"), { z: 14, x: 5298, y: 5921 });
});

Deno.test("parseCoverageTilePath rejects out-of-range coords with null", () => {
    assertEquals(parseCoverageTilePath("/functions/v1/tiles/coverage/99/0/0.mvt"), null);
});

// ── pgRpc identifier guard: refuse fn names that could break out of the SQL template ──

Deno.test("createPgRpc refuses unsafe RPC function names", async () => {
    const rpc = createPgRpc(undefined as never);
    const cases = [
        "drop_table; --",
        "fn(1)",
        "fn'name",
        "1bad_name",
        "fn-name",
        "schema.fn.too_many_parts",
        "",
    ];
    for (const fn of cases) {
        const res = await rpc(fn, {});
        assertEquals(res.data, null, `expected null data for ${fn}`);
        assertEquals(typeof res.error?.message, "string");
        assertEquals(res.error?.message?.startsWith("unsafe RPC function name"), true, `expected guard for ${fn}`);
    }
});

Deno.test("createPgRpc accepts safe identifiers (rejection is the only thing tested without a real DB)", async () => {
    // We can't exercise the SQL path without a real DB, but we can prove the
    // guard does NOT short-circuit on legitimate names — the call instead
    // proceeds to db() and fails with the expected DATABASE_URL error.
    const previous = Deno.env.get("DATABASE_URL");
    Deno.env.delete("DATABASE_URL");
    try {
        const rpc = createPgRpc();
        const res = await rpc("schema.qualified_fn", {});
        assertEquals(res.data, null);
        // Error message comes from db() init, not the guard.
        assertEquals(res.error?.message?.includes("DATABASE_URL"), true);
    } finally {
        if (previous !== undefined) Deno.env.set("DATABASE_URL", previous);
    }
});
