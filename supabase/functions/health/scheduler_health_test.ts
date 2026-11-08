import { assertEquals } from "jsr:@std/assert";
import { buildInfo, createDeepHealthHandler, createHealthHandler } from "./handler.ts";
import { evaluateSchedulerJobs } from "./jobs.ts";
import { createPgDbCheck } from "./pgRuntime.ts";
import type { ScheduledJob } from "../_shared/scheduler.ts";

Deno.test("buildInfo prefers RAILWAY_GIT_COMMIT_SHA, then GIT_COMMIT_SHA, then GIT_SHA", () => {
    const env = (vars: Record<string, string>) => ({ get: (k: string) => vars[k] });

    assertEquals(
        buildInfo(env({ RAILWAY_GIT_COMMIT_SHA: "rail123", GIT_COMMIT_SHA: "gc456", GIT_SHA: "old789", APP_VERSION: "1.2.0" })),
        { version: "1.2.0", commit: "rail123", deployed_at: null },
    );
    assertEquals(buildInfo(env({ GIT_COMMIT_SHA: "gc456", GIT_SHA: "old789" })).commit, "gc456");
    assertEquals(buildInfo(env({ GIT_SHA: "old789" })).commit, "old789");
    assertEquals(buildInfo(env({ RAILWAY_GIT_COMMIT_SHA: "  ", GIT_SHA: "old789" })).commit, "old789");
    assertEquals(buildInfo(env({})), { version: "dev", commit: "local", deployed_at: null });
    assertEquals(buildInfo(env({ DEPLOYED_AT: "2026-11-08T12:00:00Z" })).deployed_at, "2026-11-08T12:00:00Z");
});

Deno.test("lite health handler reports the Railway commit when Railway sets it", async () => {
    Deno.env.set("RAILWAY_GIT_COMMIT_SHA", "railwaysha");
    try {
        const response = await createHealthHandler()(new Request("http://localhost/functions/v1/health"));
        const body = await response.json();
        assertEquals(body.commit, "railwaysha");
        assertEquals(Object.keys(body).sort(), ["commit", "deployed_at", "status", "version"]);
    } finally {
        Deno.env.delete("RAILWAY_GIT_COMMIT_SHA");
    }
});

Deno.test("deep health handler reports ok with a healthy scheduler block", async () => {
    const handler = createDeepHealthHandler({
        checkDb: () =>
            Promise.resolve({
                dbTime: "2026-11-08T12:00:00Z",
                scheduler: {
                    status: "ok" as const,
                    jobs: {
                        "pothole-expiry": {
                            status: "ok" as const,
                            last_success_at: "2026-11-08T03:00:00.000Z",
                            consecutive_failures: 0,
                        },
                    },
                },
            }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.status, "ok");
    assertEquals(body.db, "reachable");
    assertEquals(body.scheduler.jobs["pothole-expiry"].status, "ok");
});

Deno.test("deep health handler returns 503 degraded when a scheduled job is stale", async () => {
    const handler = createDeepHealthHandler({
        checkDb: () =>
            Promise.resolve({
                dbTime: "2026-11-08T12:00:00Z",
                scheduler: {
                    status: "degraded" as const,
                    jobs: {
                        "nightly-aggregate-recompute": {
                            status: "stale" as const,
                            last_success_at: null,
                            consecutive_failures: 0,
                        },
                    },
                },
            }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 503);
    const body = await response.json();
    assertEquals(body.status, "degraded");
    assertEquals(body.db, "reachable");
    assertEquals(body.scheduler.jobs["nightly-aggregate-recompute"].status, "stale");
});

Deno.test("deep health handler returns 503 degraded when job state is unreadable", async () => {
    const handler = createDeepHealthHandler({
        checkDb: () =>
            Promise.resolve({
                dbTime: "2026-11-08T12:00:00Z",
                scheduler: { status: "unavailable" as const, jobs: {} },
            }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/health/deep"));

    assertEquals(response.status, 503);
    assertEquals((await response.json()).status, "degraded");
});

const HOUR_MS = 60 * 60_000;
const DAILY: ScheduledJob = {
    name: "daily-job",
    intervalMs: 24 * HOUR_MS,
    offsetMs: 0,
    timeoutMs: HOUR_MS,
    lockTimeoutMs: 1_000,
    sql: "SELECT 1",
};
const NOW_MS = Date.parse("2026-11-08T12:00:00Z");

Deno.test("evaluateSchedulerJobs classifies ok, stale, failing and pending jobs", () => {
    const iso = (msAgo: number) => new Date(NOW_MS - msAgo).toISOString();
    const jobs = [
        { ...DAILY, name: "fresh" },
        { ...DAILY, name: "old" },
        { ...DAILY, name: "failing" },
        { ...DAILY, name: "never" },
    ];

    const result = evaluateSchedulerJobs(
        [
            { job_name: "fresh", last_success_at: iso(20 * HOUR_MS), consecutive_failures: 1 },
            { job_name: "old", last_success_at: iso(50 * HOUR_MS), consecutive_failures: 0 },
            { job_name: "failing", last_success_at: iso(HOUR_MS), consecutive_failures: 3 },
            { job_name: "unknown-job", last_success_at: iso(1), consecutive_failures: 0 },
        ],
        { nowMs: NOW_MS, uptimeMs: HOUR_MS, jobs },
    );

    assertEquals(result.status, "degraded");
    assertEquals(result.jobs.fresh.status, "ok");
    assertEquals(result.jobs.old.status, "stale");
    assertEquals(result.jobs.failing.status, "failing");
    assertEquals(result.jobs.never.status, "pending");
    assertEquals("unknown-job" in result.jobs, false);
});

Deno.test("evaluateSchedulerJobs treats a never-succeeded job as stale once the scheduler has been up long enough", () => {
    const result = evaluateSchedulerJobs([], { nowMs: NOW_MS, uptimeMs: 3 * 24 * HOUR_MS, jobs: [DAILY] });
    assertEquals(result.jobs[DAILY.name].status, "stale");
    assertEquals(result.status, "degraded");

    const notStarted = evaluateSchedulerJobs([], { nowMs: NOW_MS, uptimeMs: null, jobs: [DAILY] });
    assertEquals(notStarted.jobs[DAILY.name].status, "stale");
});

Deno.test("evaluateSchedulerJobs is ok when every job succeeded recently", () => {
    const result = evaluateSchedulerJobs(
        [{ job_name: DAILY.name, last_success_at: "2026-11-08T03:00:00.123456+00:00", consecutive_failures: 0 }],
        { nowMs: NOW_MS, uptimeMs: HOUR_MS, jobs: [DAILY] },
    );
    assertEquals(result, {
        status: "ok",
        jobs: { [DAILY.name]: { status: "ok", last_success_at: "2026-11-08T03:00:00.123Z", consecutive_failures: 0 } },
    });
});

Deno.test("pg deep check skips the scheduler block when the scheduler is disabled", async () => {
    const sql = () => Promise.resolve([{ ts: new Date("2026-11-08T12:00:00Z") }]);
    const probe = await createPgDbCheck(sql as never, { schedulerEnabled: false })();
    assertEquals(probe, { dbTime: "2026-11-08T12:00:00.000Z" });
});

Deno.test("pg deep check evaluates scheduler_job_runs by the database clock", async () => {
    let call = 0;
    const sql = () => {
        call += 1;
        if (call === 1) return Promise.resolve([{ ts: "2026-11-08T12:00:00Z" }]);
        return Promise.resolve([{
            now_ms: NOW_MS,
            jobs: [{ job_name: DAILY.name, last_success_at: "2026-11-05T12:00:00+00:00", consecutive_failures: 0 }],
        }]);
    };
    const probe = await createPgDbCheck(sql as never, {
        schedulerEnabled: true,
        uptimeMs: () => HOUR_MS,
        jobs: [DAILY],
    })();
    assertEquals(probe?.scheduler?.status, "degraded");
    assertEquals(probe?.scheduler?.jobs[DAILY.name].status, "stale");
});

Deno.test("pg deep check reports the scheduler unavailable when the job table read fails", async () => {
    let call = 0;
    const sql = () => {
        call += 1;
        if (call === 1) return Promise.resolve([{ ts: "2026-11-08T12:00:00Z" }]);
        return Promise.reject(new Error("relation scheduler_job_runs does not exist"));
    };
    const originalError = console.error;
    console.error = () => {};
    try {
        const probe = await createPgDbCheck(sql as never, { schedulerEnabled: true, jobs: [DAILY] })();
        assertEquals(probe?.dbTime, "2026-11-08T12:00:00Z");
        assertEquals(probe?.scheduler, { status: "unavailable", jobs: {} });
    } finally {
        console.error = originalError;
    }
});

Deno.test("pg deep check returns null when db_healthcheck returns nothing", async () => {
    const sql = () => Promise.resolve([]);
    assertEquals(await createPgDbCheck(sql as never, { schedulerEnabled: false })(), null);
});
