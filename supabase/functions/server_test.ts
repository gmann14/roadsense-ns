import { assertEquals } from "jsr:@std/assert";
import { dispatch, route } from "./_shared/routes.ts";
import { verifyApiKey } from "./_shared/apikey.ts";
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

Deno.test("handleRequest returns 501 for routes that aren't implemented yet (baseline)", async () => {
    // health is still notImplemented as of P2; pick any other un-ported route
    // if/when this one gets refactored.
    const req = new Request("http://localhost/functions/v1/health");
    const res = await handleRequest(req);
    assertEquals(res.status, 501);
});
