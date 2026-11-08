// Integration test for the scheduler against a real Postgres with the
// migrations applied (scheduler_job_runs, record_scheduler_job_run,
// scheduler_job_seconds_until_due, run_retention_sweeps).
//
// Skipped unless RUN_PG_INTEGRATION=1 and DATABASE_URL are set, e.g.:
//
//   RUN_PG_INTEGRATION=1 \
//   DATABASE_URL="postgres://postgres:postgres@127.0.0.1:54322/postgres" \
//     deno test --allow-all supabase/functions/_shared/scheduler_pg_integration_test.ts

import { assert, assertEquals } from "jsr:@std/assert";
import postgres from "https://deno.land/x/postgresjs@v3.4.4/mod.js";
import { runJobOnce, type ScheduledJob, type SchedulerSql } from "./scheduler.ts";

const DATABASE_URL = Deno.env.get("DATABASE_URL");
const RUN = Boolean(DATABASE_URL) && Deno.env.get("RUN_PG_INTEGRATION") === "1";

const OK_JOB: ScheduledJob = {
    name: "integration-test-retention-sweeps",
    intervalMs: 60 * 60_000,
    offsetMs: 0,
    timeoutMs: 60_000,
    lockTimeoutMs: 5_000,
    sql: "SELECT run_retention_sweeps() AS result",
};

const FAILING_JOB: ScheduledJob = {
    name: "integration-test-timeout",
    intervalMs: 60 * 60_000,
    offsetMs: 0,
    // pg_sleep(2) must be cancelled by the per-job statement_timeout.
    timeoutMs: 200,
    lockTimeoutMs: 100,
    sql: "SELECT pg_sleep(2)",
};

const quiet = { log: () => {}, errorLog: () => {} };

Deno.test({
    name: "scheduler records runs, honours the due window, the job lock and the per-job timeout",
    ignore: !RUN,
    sanitizeOps: false,
    sanitizeResources: false,
    fn: async () => {
        const url = DATABASE_URL ?? "";
        const sql = postgres(url, { max: 3, ssl: url.includes("railway.internal") ? false : undefined });
        const schedulerSql = sql as unknown as SchedulerSql;
        try {
            await sql`DELETE FROM scheduler_job_runs WHERE job_name IN (${OK_JOB.name}, ${FAILING_JOB.name})`;

            const first = await runJobOnce(schedulerSql, OK_JOB, quiet);
            assertEquals(first.status, "ran");

            const rows = await sql`
                SELECT last_status, consecutive_failures, last_result ? 'rate_limits' AS has_counts
                FROM scheduler_job_runs WHERE job_name = ${OK_JOB.name}
            `;
            assertEquals(rows[0]?.last_status, "ok");
            assertEquals(rows[0]?.consecutive_failures, 0);
            assertEquals(rows[0]?.has_counts, true);

            const second = await runJobOnce(schedulerSql, OK_JOB, quiet);
            assertEquals(second.status, "not_due");

            // Hold the job's advisory lock from another session: the run must skip.
            await sql`DELETE FROM scheduler_job_runs WHERE job_name = ${OK_JOB.name}`;
            const holder = await sql.reserve();
            try {
                await holder`SELECT pg_advisory_lock(hashtextextended(${"roadsense-scheduler:" + OK_JOB.name}, 0))`;
                const locked = await runJobOnce(schedulerSql, OK_JOB, quiet);
                assertEquals(locked.status, "locked");
                await holder`SELECT pg_advisory_unlock(hashtextextended(${"roadsense-scheduler:" + OK_JOB.name}, 0))`;
            } finally {
                holder.release();
            }

            const failed = await runJobOnce(schedulerSql, FAILING_JOB, quiet);
            assertEquals(failed.status, "failed");
            if (failed.status === "failed") assert(/statement timeout/.test(failed.error), failed.error);
            const failedRows = await sql`
                SELECT last_status, consecutive_failures, last_success_at
                FROM scheduler_job_runs WHERE job_name = ${FAILING_JOB.name}
            `;
            assertEquals(failedRows[0]?.last_status, "error");
            assertEquals(failedRows[0]?.consecutive_failures, 1);
            assertEquals(failedRows[0]?.last_success_at, null);

            // The session the job ran on must not keep the short timeout.
            const timeoutRows = await sql`SHOW statement_timeout`;
            assert(timeoutRows[0]?.statement_timeout !== "200ms", "SET LOCAL did not leak into the pool");
        } finally {
            await sql`DELETE FROM scheduler_job_runs WHERE job_name IN (${OK_JOB.name}, ${FAILING_JOB.name})`;
            await sql.end({ timeout: 5 });
        }
    },
});
