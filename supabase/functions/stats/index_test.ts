import { assertEquals } from "jsr:@std/assert";
import { createStatsHandler } from "./handler.ts";

Deno.test("stats handler returns 200 with cache headers", async () => {
    const handler = createStatsHandler({
        fetchStats: async () => ({
            total_km_mapped: 18423.7,
            total_readings: 1873921,
            segments_scored: 28743,
            active_potholes: 213,
            municipalities_covered: 4,
            generated_at: "2026-04-17T14:00:00Z",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/stats", {
            headers: { "x-request-id": "req-stats" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "public, max-age=300");
    assertEquals(response.headers.get("x-request-id"), "req-stats");
    assertEquals((await response.json()).active_potholes, 213);
});

Deno.test("stats handler returns 503 when stats are unavailable", async () => {
    const handler = createStatsHandler({
        fetchStats: async () => null,
    });

    const response = await handler(new Request("http://localhost/functions/v1/stats"));

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});

Deno.test("stats handler returns 405 for unsupported methods", async () => {
    const handler = createStatsHandler({
        fetchStats: async () => null,
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/stats", { method: "POST" }),
    );

    assertEquals(response.status, 405);
});
