import { assertEquals } from "jsr:@std/assert";
import { createTopPotholesHandler, parseTopPotholesLimit } from "./handler.ts";

Deno.test("parseTopPotholesLimit accepts missing and valid limits", () => {
    assertEquals(parseTopPotholesLimit(new URL("http://localhost/functions/v1/top-potholes")), 20);
    assertEquals(parseTopPotholesLimit(new URL("http://localhost/functions/v1/top-potholes?limit=50")), 50);
});

Deno.test("parseTopPotholesLimit rejects malformed or out-of-range limits", () => {
    assertEquals(parseTopPotholesLimit(new URL("http://localhost/functions/v1/top-potholes?limit=0")), null);
    assertEquals(parseTopPotholesLimit(new URL("http://localhost/functions/v1/top-potholes?limit=101")), null);
    assertEquals(parseTopPotholesLimit(new URL("http://localhost/functions/v1/top-potholes?limit=abc")), null);
});

Deno.test("top potholes handler returns rows", async () => {
    let seenLimit = 0;
    const handler = createTopPotholesHandler({
        fetchTopPotholes: async (limit) => {
            seenLimit = limit;
            return [
                {
                    id: "p1",
                    lat: 44.6498,
                    lng: -63.5762,
                    magnitude: 2.4,
                    confirmation_count: 7,
                    first_reported_at: "2026-04-01T12:00:00Z",
                    last_confirmed_at: "2026-04-16T08:00:00Z",
                    status: "active",
                    segment_id: "seg-1",
                },
            ];
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/top-potholes?limit=5", {
            headers: { "x-request-id": "req-top-potholes" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("x-request-id"), "req-top-potholes");
    assertEquals(seenLimit, 5);
    assertEquals((await response.json()).potholes.length, 1);
});

Deno.test("top potholes handler returns 400 for invalid limit", async () => {
    const handler = createTopPotholesHandler({
        fetchTopPotholes: async () => [],
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/top-potholes?limit=nope"),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("top potholes handler returns 503 when lookup fails upstream", async () => {
    const handler = createTopPotholesHandler({
        fetchTopPotholes: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/top-potholes?limit=5"),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});
