// Integration test for the deep-health probe against a real Postgres with the
// migrations applied. Skipped unless RUN_PG_INTEGRATION=1 and DATABASE_URL
// are set (see stats/pg_integration_test.ts).

import { assertEquals } from "jsr:@std/assert";
import postgres from "https://deno.land/x/postgresjs@v3.4.4/mod.js";
import { createPgDbCheck } from "./pgRuntime.ts";
import type { ScheduledJob } from "../_shared/scheduler.ts";

const DATABASE_URL = Deno.env.get("DATABASE_URL");
const RUN = Boolean(DATABASE_URL) && Deno.env.get("RUN_PG_INTEGRATION") === "1";

const JOBS: ScheduledJob[] = [
    { name: "integration-health-fresh", intervalMs: 3_600_000, offsetMs: 0, timeoutMs: 60_000, lockTimeoutMs: 1_000, sql: "SELECT 1" },
    { name: "integration-health-missing", intervalMs: 3_600_000, offsetMs: 0, timeoutMs: 60_000, lockTimeoutMs: 1_000, sql: "SELECT 1" },
];

Deno.test({
    name: "pg deep check reads scheduler_job_runs and flags never-run jobs",
    ignore: !RUN,
    sanitizeOps: false,
    sanitizeResources: false,
    fn: async () => {
        const url = DATABASE_URL ?? "";
        const sql = postgres(url, { max: 1, ssl: url.includes("railway.internal") ? false : undefined });
        try {
            await sql`DELETE FROM scheduler_job_runs WHERE job_name LIKE 'integration-health-%'`;
            await sql`SELECT record_scheduler_job_run(${JOBS[0].name}, now(), true, 5, NULL, NULL)`;

            const probe = await createPgDbCheck(sql, {
                schedulerEnabled: true,
                uptimeMs: () => 24 * 3_600_000,
                jobs: JOBS,
            })();

            assertEquals(typeof probe?.dbTime, "string");
            assertEquals(probe?.scheduler?.jobs[JOBS[0].name]?.status, "ok");
            assertEquals(probe?.scheduler?.jobs[JOBS[1].name]?.status, "stale");
            assertEquals(probe?.scheduler?.status, "degraded");
        } finally {
            await sql`DELETE FROM scheduler_job_runs WHERE job_name LIKE 'integration-health-%'`;
            await sql.end({ timeout: 5 });
        }
    },
});
