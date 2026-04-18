import { assertEquals } from "jsr:@std/assert";
import { createHealthHandler } from "./handler.ts";

Deno.test("health handler returns 200 with deploy metadata", async () => {
    Deno.env.set("APP_VERSION", "1.0.3");
    Deno.env.set("GIT_SHA", "a1b2c3d");
    Deno.env.set("DEPLOYED_AT", "2026-04-10T18:00:00Z");

    const handler = createHealthHandler({
        checkDb: async () => "2026-04-18T15:00:00Z",
    });

    const response = await handler(new Request("http://localhost/functions/v1/health"));

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "no-store");
    assertEquals((await response.json()).db, "reachable");
});

Deno.test("health handler returns 503 when db check fails", async () => {
    const handler = createHealthHandler({
        checkDb: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(new Request("http://localhost/functions/v1/health"));

    assertEquals(response.status, 503);
    assertEquals((await response.json()).db, "unreachable");
});

Deno.test("health handler returns 405 for unsupported methods", async () => {
    const handler = createHealthHandler({
        checkDb: async () => "2026-04-18T15:00:00Z",
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/health", { method: "POST" }),
    );

    assertEquals(response.status, 405);
});
