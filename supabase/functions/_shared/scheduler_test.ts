import { assert, assertEquals, assertMatch } from "jsr:@std/assert";
import {
    isSchedulerEnabled,
    nextCheckDelayMs,
    retryMsFor,
    runJobOnce,
    SCHEDULED_JOBS,
    type ScheduledJob,
    type SchedulerRow,
    type SchedulerSql,
    type SchedulerTx,
    staleAfterMsFor,
    startScheduler,
} from "./scheduler.ts";

type Call = { query: string; params?: unknown[]; inTx: boolean };

const JOB: ScheduledJob = {
    name: "test-job",
    intervalMs: 60 * 60_000,
    offsetMs: 0,
    timeoutMs: 120_000,
    lockTimeoutMs: 5_000,
    sql: "SELECT run_retention_sweeps() AS result",
};

function fakeSql(opts: {
    locked?: boolean;
    secondsUntilDue?: number;
    jobError?: Error;
    recordFailureError?: Error;
    jobRows?: readonly SchedulerRow[];
}): { sql: SchedulerSql; calls: Call[] } {
    const calls: Call[] = [];

    const respond = (query: string, inTx: boolean): readonly SchedulerRow[] => {
        if (query.includes("pg_try_advisory_xact_lock")) return [{ locked: opts.locked ?? true }];
        if (query.includes("scheduler_job_seconds_until_due")) return [{ seconds: opts.secondsUntilDue ?? 0 }];
        if (query.includes("record_scheduler_job_run")) {
            if (!inTx && opts.recordFailureError) throw opts.recordFailureError;
            return [{}];
        }
        if (query === JOB.sql) {
            if (opts.jobError) throw opts.jobError;
            return opts.jobRows ?? [{ result: { rate_limits: 3 } }];
        }
        return [{}];
    };

    const tx: SchedulerTx = {
        unsafe: (query, params) => {
            calls.push({ query, params, inTx: true });
            try {
                return Promise.resolve(respond(query, true));
            } catch (error) {
                return Promise.reject(error);
            }
        },
    };

    const sql: SchedulerSql = {
        unsafe: (query, params) => {
            calls.push({ query, params, inTx: false });
            try {
                return Promise.resolve(respond(query, false));
            } catch (error) {
                return Promise.reject(error);
            }
        },
        begin: (fn) => fn(tx),
    };

    return { sql, calls };
}

const quiet = { log: () => {}, errorLog: () => {} };

Deno.test("runJobOnce sets per-job timeouts, takes the job lock, runs and records success in one transaction", async () => {
    const { sql, calls } = fakeSql({});

    const outcome = await runJobOnce(sql, JOB, quiet);

    assertEquals(outcome.status, "ran");
    assert(calls.every((c) => c.inTx), "every statement ran inside the transaction");
    assertMatch(calls[0].query, /set_config\('statement_timeout', \$1, true\).*set_config\('lock_timeout', \$2, true\)/);
    assertEquals(calls[0].params, ["120000", "5000"]);
    assertMatch(calls[1].query, /pg_try_advisory_xact_lock\(hashtextextended\(\$1, 0\)\)/);
    assertEquals(calls[1].params, ["roadsense-scheduler:test-job"]);
    assertEquals(calls[2].params, ["test-job", 3600, 900]);
    assertEquals(calls[3].query, JOB.sql);
    assertMatch(calls[4].query, /record_scheduler_job_run\(\$1, now\(\), true/);
    assertEquals(calls[4].params?.[0], "test-job");
    assertEquals(calls[4].params?.[2], JSON.stringify({ rate_limits: 3 }));
});

Deno.test("runJobOnce does not run the job when another run holds the lock", async () => {
    const { sql, calls } = fakeSql({ locked: false });

    const outcome = await runJobOnce(sql, JOB, quiet);

    assertEquals(outcome.status, "locked");
    assertEquals(calls.some((c) => c.query === JOB.sql), false);
    assertEquals(calls.some((c) => c.query.includes("record_scheduler_job_run")), false);
});

Deno.test("runJobOnce does not run a job that is not due yet", async () => {
    const { sql, calls } = fakeSql({ secondsUntilDue: 120 });

    const outcome = await runJobOnce(sql, JOB, quiet);

    assertEquals(outcome, { status: "not_due", secondsUntilDue: 120 });
    assertEquals(calls.some((c) => c.query === JOB.sql), false);
});

Deno.test("runJobOnce records a failure outside the rolled-back transaction and logs it", async () => {
    const { sql, calls } = fakeSql({ jobError: new Error("canceling statement due to statement timeout") });
    const errors: string[] = [];

    const outcome = await runJobOnce(sql, JOB, { log: () => {}, errorLog: (m) => errors.push(m) });

    assertEquals(outcome.status, "failed");
    if (outcome.status === "failed") assertMatch(outcome.error, /statement timeout/);
    const record = calls.find((c) => !c.inTx && c.query.includes("record_scheduler_job_run"));
    assert(record, "failure recorded via the pool, not the aborted transaction");
    assertMatch(record.query, /false/);
    assertEquals(record.params?.[0], "test-job");
    assertEquals(record.params?.[3], "canceling statement due to statement timeout");
    assertEquals(errors.length, 1);
});

Deno.test("runJobOnce never throws when recording the failure also fails", async () => {
    const { sql } = fakeSql({ jobError: new Error("boom"), recordFailureError: new Error("db gone") });
    const errors: string[] = [];

    const outcome = await runJobOnce(sql, JOB, { log: () => {}, errorLog: (m) => errors.push(m) });

    assertEquals(outcome.status, "failed");
    assertEquals(errors.length, 2);
    assertMatch(errors[1], /could not record the failed run: db gone/);
});

Deno.test("runJobOnce records a null result when the job returns no JSON object", async () => {
    const { sql, calls } = fakeSql({ jobRows: [] });

    await runJobOnce(sql, JOB, quiet);

    const record = calls.find((c) => c.query.includes("record_scheduler_job_run"));
    assertEquals(record?.params?.[2], null);
});

Deno.test("nextCheckDelayMs follows the outcome", () => {
    assertEquals(nextCheckDelayMs(JOB, { status: "ran", durationMs: 1 }), JOB.intervalMs);
    assertEquals(nextCheckDelayMs(JOB, { status: "failed", durationMs: 1, error: "x" }), retryMsFor(JOB));
    assertEquals(nextCheckDelayMs(JOB, { status: "locked" }), retryMsFor(JOB));
    assertEquals(nextCheckDelayMs(JOB, { status: "not_due", secondsUntilDue: 30 }), 31_000);
    assertEquals(nextCheckDelayMs(JOB, { status: "not_due", secondsUntilDue: 86_400 }), retryMsFor(JOB));
});

Deno.test("scheduled jobs cover the retention work, are staggered and have bounded timeouts", () => {
    const names = SCHEDULED_JOBS.map((j) => j.name);
    for (const required of [
        "refresh-public-stats-mv",
        "refresh-public-worst-segments-mv",
        "create-next-readings-partition",
        "purge-expired-readings",
        "drop-old-readings-partitions",
        "replay-unmatched-readings",
        "nightly-aggregate-recompute",
        "pothole-expiry",
        "retention-sweeps",
    ]) {
        assert(names.includes(required), `${required} is scheduled`);
    }
    assertEquals(names.includes("rate-limit-gc"), false);
    assertEquals(new Set(names).size, names.length);
    assertEquals(new Set(SCHEDULED_JOBS.map((j) => j.offsetMs)).size, SCHEDULED_JOBS.length);
    for (const job of SCHEDULED_JOBS) {
        assert(job.timeoutMs > 0 && job.timeoutMs < job.intervalMs, `${job.name} timeout is inside its interval`);
        assert(job.lockTimeoutMs > 0 && job.lockTimeoutMs <= job.timeoutMs, `${job.name} lock timeout is bounded`);
        assert(staleAfterMsFor(job) > job.intervalMs, `${job.name} stale threshold exceeds its interval`);
        assert(retryMsFor(job) <= job.intervalMs, `${job.name} retries no later than its interval`);
    }
});

Deno.test("isSchedulerEnabled mirrors the server.ts start condition", () => {
    const env = (vars: Record<string, string>) => ({ get: (k: string) => vars[k] });
    assertEquals(isSchedulerEnabled(env({})), false);
    assertEquals(isSchedulerEnabled(env({ RAILWAY_ENVIRONMENT: "production" })), true);
    assertEquals(isSchedulerEnabled(env({ ENABLE_SCHEDULER: "true" })), true);
    assertEquals(isSchedulerEnabled(env({ ENABLE_SCHEDULER: "1" })), false);
});

Deno.test("startScheduler runs each job after its offset and stop() waits for in-flight runs", async () => {
    const { sql, calls } = fakeSql({});
    const handle = startScheduler({
        sqlOverride: sql,
        logger: () => {},
        errorLogger: () => {},
        jobs: [{ ...JOB, offsetMs: 0 }],
        jitterMs: () => 0,
    });

    await new Promise((resolve) => setTimeout(resolve, 20));
    await handle.stop();

    assert(calls.some((c) => c.query === JOB.sql), "job ran once at startup");
});
