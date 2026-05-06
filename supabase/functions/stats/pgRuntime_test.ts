import { assertEquals } from "jsr:@std/assert";
import { createPgFetchStats } from "./pgRuntime.ts";

Deno.test("pg stats runtime normalizes alternate bounds key casing", async () => {
    const sql = async () => [{
        total_km_mapped: "12.4",
        total_readings: "31",
        segments_scored: "9",
        active_potholes: "4",
        municipalities_covered: "2",
        map_bounds: {
            min_lng: "-64.34",
            min_lat: "44.37",
            max_lng: "-64.31",
            max_lat: "44.41",
        },
        pothole_bounds: {
            minLng: -64.2,
            minLat: 44.4,
            maxLng: -64.1,
            maxLat: 44.5,
        },
        generated_at: "2026-04-28T15:00:00Z",
    }];

    const stats = await createPgFetchStats(sql as never)();

    assertEquals(stats?.map_bounds, {
        minLng: -64.34,
        minLat: 44.37,
        maxLng: -64.31,
        maxLat: 44.41,
    });
    assertEquals(stats?.pothole_bounds, {
        minLng: -64.2,
        minLat: 44.4,
        maxLng: -64.1,
        maxLat: 44.5,
    });
});

Deno.test("pg stats runtime drops invalid bounds", async () => {
    const sql = async () => [{
        total_km_mapped: 12.4,
        total_readings: 31,
        segments_scored: 9,
        active_potholes: 4,
        municipalities_covered: 2,
        map_bounds: {
            minLng: -63,
            minLat: 45,
            maxLng: -64,
            maxLat: 44,
        },
        pothole_bounds: null,
        generated_at: "2026-04-28T15:00:00Z",
    }];

    const stats = await createPgFetchStats(sql as never)();

    assertEquals(stats?.map_bounds, null);
});
