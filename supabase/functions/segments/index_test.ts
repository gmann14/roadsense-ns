import { assertEquals } from "jsr:@std/assert";
import { createSegmentsHandler, parseSegmentPath } from "./handler.ts";

Deno.test("parseSegmentPath extracts a UUID from the route", () => {
    assertEquals(
        parseSegmentPath("/functions/v1/segments/00000000-0000-0000-0000-000000001201"),
        "00000000-0000-0000-0000-000000001201",
    );
    assertEquals(parseSegmentPath("/functions/v1/segments/not-a-uuid"), null);
});

Deno.test("segments handler returns 200 with history and neighbors stubs", async () => {
    const handler = createSegmentsHandler({
        fetchSegmentDetail: async () => ({
            id: "00000000-0000-0000-0000-000000001201",
            road_name: "Barrington Street",
            road_type: "primary",
            municipality: "Halifax",
            length_m: 48.7,
            has_speed_bump: false,
            has_rail_crossing: false,
            surface_type: "asphalt",
            aggregate: {
                avg_roughness_score: 0.72,
                category: "rough",
                confidence: "high",
                total_readings: 137,
                unique_contributors: 34,
                pothole_count: 2,
                trend: "worsening",
                score_last_30d: 0.78,
                score_30_60d: 0.69,
                last_reading_at: "2026-04-16T22:15:00Z",
                updated_at: "2026-04-17T03:15:00Z",
            },
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/00000000-0000-0000-0000-000000001201", {
            headers: { "x-request-id": "req-segment" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("x-request-id"), "req-segment");

    const body = await response.json();
    assertEquals(body.history, []);
    assertEquals(body.neighbors, null);
    assertEquals(body.aggregate.category, "rough");
});

Deno.test("segments handler returns 404 when no segment detail exists", async () => {
    const handler = createSegmentsHandler({
        fetchSegmentDetail: async () => null,
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/00000000-0000-0000-0000-000000009999"),
    );

    assertEquals(response.status, 404);
    assertEquals((await response.json()).error, "not_found");
});

Deno.test("segments handler returns 405 for unsupported methods", async () => {
    const handler = createSegmentsHandler({
        fetchSegmentDetail: async () => null,
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/00000000-0000-0000-0000-000000001201", {
            method: "POST",
        }),
    );

    assertEquals(response.status, 405);
});

Deno.test("segments handler returns 503 when lookup fails upstream", async () => {
    const handler = createSegmentsHandler({
        fetchSegmentDetail: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/00000000-0000-0000-0000-000000001201"),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});
