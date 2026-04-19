import { assertEquals } from "jsr:@std/assert";
import {
    createSegmentsWorstHandler,
    parseWorstSegmentsQuery,
} from "./handler.ts";

Deno.test("parseWorstSegmentsQuery accepts valid municipality and limit", () => {
    assertEquals(
        parseWorstSegmentsQuery(new URL("http://localhost/functions/v1/segments/worst?municipality=Halifax&limit=5")),
        { municipality: "Halifax", limit: 5 },
    );
});

Deno.test("parseWorstSegmentsQuery rejects missing or invalid limit", () => {
    assertEquals(
        parseWorstSegmentsQuery(new URL("http://localhost/functions/v1/segments/worst?municipality=Halifax")),
        null,
    );
    assertEquals(
        parseWorstSegmentsQuery(new URL("http://localhost/functions/v1/segments/worst?limit=0")),
        null,
    );
    assertEquals(
        parseWorstSegmentsQuery(new URL("http://localhost/functions/v1/segments/worst?limit=abc")),
        null,
    );
});

Deno.test("segments worst handler returns 400 for invalid limit", async () => {
    const handler = createSegmentsWorstHandler({
        fetchKnownMunicipalities: async () => ["Halifax"],
        fetchWorstSegments: async () => ({ generated_at: "2026-04-17T03:20:00Z", rows: [] }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/worst?municipality=Halifax"),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("segments worst handler returns 400 for unknown municipality", async () => {
    const handler = createSegmentsWorstHandler({
        fetchKnownMunicipalities: async () => ["Halifax"],
        fetchWorstSegments: async () => ({ generated_at: "2026-04-17T03:20:00Z", rows: [] }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/worst?municipality=Bedford&limit=5"),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("segments worst handler returns ranked rows", async () => {
    const handler = createSegmentsWorstHandler({
        fetchKnownMunicipalities: async () => ["Halifax"],
        fetchWorstSegments: async () => ({
            generated_at: "2026-04-17T03:20:00Z",
            rows: [
                {
                    rank: 1,
                    segment_id: "00000000-0000-0000-0000-000000002104",
                    road_name: "Coverage Strong Road",
                    municipality: "Halifax",
                    road_type: "primary",
                    category: "very_rough",
                    confidence: "high",
                    avg_roughness_score: 1.24,
                    score_last_30d: 1.25,
                    score_30_60d: 1.1,
                    trend: "worsening",
                    total_readings: 22,
                    unique_contributors: 12,
                    pothole_count: 3,
                    last_reading_at: "2026-04-17T02:20:00Z",
                },
            ],
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/worst?municipality=Halifax&limit=5", {
            headers: { "x-request-id": "req-worst" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("x-request-id"), "req-worst");

    const body = await response.json();
    assertEquals(body.municipality, "Halifax");
    assertEquals(body.rows.length, 1);
    assertEquals(body.rows[0].rank, 1);
});

Deno.test("segments worst handler returns 503 when upstream fails", async () => {
    const handler = createSegmentsWorstHandler({
        fetchKnownMunicipalities: async () => ["Halifax"],
        fetchWorstSegments: async () => {
            throw new Error("db down");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/segments/worst?municipality=Halifax&limit=5"),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});
