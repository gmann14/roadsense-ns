import { assertEquals } from "jsr:@std/assert";
import { createPgFetchTopPotholes } from "./pgRuntime.ts";

Deno.test("pg top-potholes runtime normalizes direct pothole report rows", async () => {
    const sql = async () => [{
        id: "p1",
        lat: "44.6498",
        lng: "-63.5762",
        magnitude: "2.40",
        confirmation_count: "7",
        first_reported_at: "2026-04-01T12:00:00Z",
        last_confirmed_at: "2026-04-16T08:00:00Z",
        status: "active",
        segment_id: "seg-1",
    }];

    const rows = await createPgFetchTopPotholes(sql as never)(20);

    assertEquals(rows, [{
        id: "p1",
        lat: 44.6498,
        lng: -63.5762,
        magnitude: 2.4,
        confirmation_count: 7,
        first_reported_at: "2026-04-01T12:00:00Z",
        last_confirmed_at: "2026-04-16T08:00:00Z",
        status: "active",
        segment_id: "seg-1",
    }]);
});
