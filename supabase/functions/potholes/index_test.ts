import { assertEquals } from "jsr:@std/assert";
import { createPotholesHandler, parseBbox } from "./handler.ts";

Deno.test("parseBbox accepts a valid potholes bbox", () => {
    assertEquals(parseBbox("-63.60,44.64,-63.55,44.68"), {
        minLng: -63.6,
        minLat: 44.64,
        maxLng: -63.55,
        maxLat: 44.68,
    });
});

Deno.test("parseBbox rejects oversized or malformed boxes", () => {
    assertEquals(parseBbox(null), null);
    assertEquals(parseBbox("-63.60,44.64,-63.40,44.80"), null);
    assertEquals(parseBbox("-63.55,44.68,-63.60,44.64"), null);
});

Deno.test("potholes handler returns 200 with rows", async () => {
    const handler = createPotholesHandler({
        fetchPotholes: async () => [
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
        ],
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/potholes?bbox=-63.60,44.64,-63.55,44.68", {
            headers: { "x-request-id": "req-potholes" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("x-request-id"), "req-potholes");
    assertEquals((await response.json()).potholes.length, 1);
});

Deno.test("potholes handler returns 400 for invalid bbox", async () => {
    const handler = createPotholesHandler({
        fetchPotholes: async () => [],
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/potholes?bbox=-63.60,44.64,-63.30,44.80"),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("potholes handler returns 503 when lookup fails upstream", async () => {
    const handler = createPotholesHandler({
        fetchPotholes: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/potholes?bbox=-63.60,44.64,-63.55,44.68"),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});
