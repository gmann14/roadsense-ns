import { assertEquals } from "jsr:@std/assert";
import { createDeepHealthHandler, createHealthHandler } from "./handler.ts";

Deno.test("lite health handler returns 200 with deploy metadata and no DB call", async () => {
    Deno.env.set("APP_VERSION", "1.0.3");
    Deno.env.set("GIT_SHA", "a1b2c3d");
    Deno.env.set("DEPLOYED_AT", "2026-04-10T18:00:00Z");

    const handler = createHealthHandler();

    const response = await handler(new Request("http://localhost/functions/v1/health"));

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "no-store");
    const body = await response.json();
    assertEquals(body.status, "ok");
    assertEquals(body.version, "1.0.3");
    assertEquals(body.commit, "a1b2c3d");
    // No db field — that's the whole point of splitting the handler.
    assertEquals("db" in body, false);
});

Deno.test("lite health handler returns 405 for unsupported methods", async () => {
    const handler = createHealthHandler();

    const response = await handler(
        new Request("http://localhost/functions/v1/health", { method: "POST" }),
    );

    assertEquals(response.status, 405);
});

Deno.test("deep health handler returns 200 when db is reachable", async () => {
    Deno.env.set("APP_VERSION", "1.0.3");
    Deno.env.set("GIT_SHA", "a1b2c3d");
    Deno.env.set("DEPLOYED_AT", "2026-04-10T18:00:00Z");

    const handler = createDeepHealthHandler({
        checkDb: async () => "2026-04-18T15:00:00Z",
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "no-store");
    assertEquals((await response.json()).db, "reachable");
});

Deno.test("deep health handler returns 503 when db check fails", async () => {
    const handler = createDeepHealthHandler({
        checkDb: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 503);
    assertEquals((await response.json()).db, "unreachable");
});

Deno.test("deep health handler returns 503 when db check returns null", async () => {
    const handler = createDeepHealthHandler({
        checkDb: async () => null,
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 503);
    assertEquals((await response.json()).db, "unreachable");
});

Deno.test("deep health handler returns 405 for unsupported methods", async () => {
    const handler = createDeepHealthHandler({
        checkDb: async () => "2026-04-18T15:00:00Z",
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/health/deep", { method: "POST" }),
    );

    assertEquals(response.status, 405);
});
