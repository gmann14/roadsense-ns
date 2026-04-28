// Integration test for the pg-deno stats runtime.
//
// Skipped when DATABASE_URL is not set (e.g. CI without a Postgres). Locally,
// run against the Supabase-managed dev DB via:
//
//   DATABASE_URL="postgres://postgres:postgres@127.0.0.1:54322/postgres" \
//     deno test --allow-all supabase/functions/stats/pg_integration_test.ts

import { assertEquals } from "jsr:@std/assert";
import postgres from "https://deno.land/x/postgresjs@v3.4.4/mod.js";
import { createPgFetchStats } from "./pgRuntime.ts";

const DATABASE_URL = Deno.env.get("DATABASE_URL");
const RUN = DATABASE_URL && Deno.env.get("RUN_PG_INTEGRATION") === "1";

Deno.test({
    name: "pg-backed fetchStats returns the public_stats_mv shape",
    ignore: !RUN,
    sanitizeOps: false,
    sanitizeResources: false,
    fn: async () => {
        const sql = postgres(DATABASE_URL!, {
            ssl: DATABASE_URL!.includes("railway.internal") ? false : undefined,
            max: 2,
        });
        try {
            const fetchStats = createPgFetchStats(sql);
            const stats = await fetchStats();

            // We don't assert specific values (DB content varies). We assert
            // the shape and that numerics came back as numbers, not strings.
            if (stats === null) {
                // Fresh DB might have an empty MV. That's acceptable; just verify the call succeeded.
                return;
            }
            assertEquals(typeof stats.total_km_mapped, "number");
            assertEquals(typeof stats.total_readings, "number");
            assertEquals(typeof stats.segments_scored, "number");
            assertEquals(typeof stats.active_potholes, "number");
            assertEquals(typeof stats.municipalities_covered, "number");
            assertEquals(typeof stats.generated_at, "string");
        } finally {
            await sql.end({ timeout: 5 });
        }
    },
});
