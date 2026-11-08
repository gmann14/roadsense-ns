// Scheduler freshness for /health/deep (2026-10-18 review, "Railway
// scheduler is fragile": a failing nightly job was invisible).
//
// Reads the rows the scheduler writes to scheduler_job_runs and classifies
// every configured job. Error text is deliberately not exposed: it can carry
// SQL fragments, and the operator reads it from the table or the logs.

import { type ScheduledJob, staleAfterMsFor } from "../_shared/scheduler.ts";

export type SchedulerJobRow = {
    job_name: string;
    last_success_at: string | null;
    consecutive_failures: number | null;
};

export type JobHealthStatus = "ok" | "pending" | "stale" | "failing";

export type JobHealth = {
    status: JobHealthStatus;
    last_success_at: string | null;
    consecutive_failures: number;
};

export type SchedulerHealth = {
    status: "ok" | "degraded" | "unavailable";
    jobs: Record<string, JobHealth>;
};

/// Consecutive failures at which a job counts as failing even if its last
/// success is still inside the stale window.
export const FAILING_AFTER_CONSECUTIVE_FAILURES = 3;

function parseMs(value: string | null | undefined): number | null {
    if (!value) return null;
    const ms = Date.parse(value);
    return Number.isFinite(ms) ? ms : null;
}

export function evaluateSchedulerJobs(
    rows: readonly SchedulerJobRow[],
    opts: {
        /// Database clock, so a skewed container clock can't hide a stale job.
        nowMs: number;
        /// How long this process's scheduler has been running (null: never started).
        uptimeMs: number | null;
        jobs: readonly ScheduledJob[];
    },
): SchedulerHealth {
    const byName = new Map<string, SchedulerJobRow>();
    for (const row of rows ?? []) {
        if (row?.job_name) byName.set(row.job_name, row);
    }

    const jobs: Record<string, JobHealth> = {};
    let degraded = false;

    for (const job of opts.jobs) {
        const row = byName.get(job.name);
        const failures = Math.max(0, Number(row?.consecutive_failures ?? 0) || 0);
        const successMs = parseMs(row?.last_success_at);
        const staleAfterMs = staleAfterMsFor(job);

        let status: JobHealthStatus;
        if (failures >= FAILING_AFTER_CONSECUTIVE_FAILURES) {
            status = "failing";
        } else if (successMs !== null) {
            status = opts.nowMs - successMs > staleAfterMs ? "stale" : "ok";
        } else if (opts.uptimeMs !== null && opts.uptimeMs < staleAfterMs) {
            // Never succeeded yet, but the scheduler has not been up long
            // enough to have owed a success (first deploy of a new job).
            status = "pending";
        } else {
            status = "stale";
        }

        if (status === "stale" || status === "failing") degraded = true;
        jobs[job.name] = {
            status,
            last_success_at: successMs === null ? null : new Date(successMs).toISOString(),
            consecutive_failures: failures,
        };
    }

    return { status: degraded ? "degraded" : "ok", jobs };
}
