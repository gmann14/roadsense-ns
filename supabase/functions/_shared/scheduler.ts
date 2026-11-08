// In-process scheduler for the deployments where pg_cron isn't available
// (Railway PostGIS template). The migrations install no-op stubs for
// cron.schedule/cron.unschedule so the schema applies cleanly, but the
// scheduled jobs never fire on those environments. This file fires them
// from the Deno service instead.
//
// 2026-11 hardening (docs/reviews/2026-10-18-full-codebase-review.md,
// "Railway scheduler is fragile"):
//   - Jobs run on a dedicated pool (`schedulerDb()`) with no session
//     statement_timeout; each job sets its own `statement_timeout` and
//     `lock_timeout` with SET LOCAL semantics inside its transaction, so the
//     request pool's 8 s limit no longer kills the nightly recompute or the
//     MV refreshes, and a job can still never run unbounded.
//   - Each run takes `pg_try_advisory_xact_lock` on a per-job key, so two
//     replicas (or a slow run overlapping its next tick) never run the same
//     job concurrently.
//   - Whether a job is due is decided by the database clock from
//     `scheduler_job_runs`, not by process uptime. A redeploy no longer
//     re-runs every daily job, and a crash-looping process no longer skips
//     them: a job that has not succeeded within its interval runs at the next
//     check, and a failed job is retried after `retryMs`.
//   - Every run (success or failure) is recorded in `scheduler_job_runs`;
//     /health/deep reports a job as stale when it has not succeeded recently.
//   - First checks are staggered (`offsetMs` plus jitter) so the heavy daily
//     jobs never start at the same moment.
//
// Cadences mirror the cron.schedule(...) entries in the migrations.

import { schedulerDb } from "../db.ts";

const SECOND = 1_000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export type ScheduledJob = {
    name: string;
    intervalMs: number;
    /// Delay before the first due-check after startup (staggering).
    offsetMs: number;
    /// Per-run statement_timeout, applied with SET LOCAL semantics.
    timeoutMs: number;
    /// Per-run lock_timeout, applied with SET LOCAL semantics.
    lockTimeoutMs: number;
    sql: string;
};

export const SCHEDULED_JOBS: readonly ScheduledJob[] = [
    {
        name: "refresh-public-stats-mv",
        intervalMs: 5 * MINUTE,
        offsetMs: 1 * MINUTE,
        timeoutMs: 2 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv",
    },
    {
        name: "refresh-public-worst-segments-mv",
        intervalMs: 15 * MINUTE,
        offsetMs: 2 * MINUTE,
        timeoutMs: 5 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv",
    },
    {
        // Cheap and idempotent; daily so a missed month boundary can't cause
        // an ingest outage.
        name: "create-next-readings-partition",
        intervalMs: DAY,
        offsetMs: 3 * MINUTE,
        timeoutMs: 1 * MINUTE,
        lockTimeoutMs: 10 * SECOND,
        sql: "SELECT create_next_readings_partition()",
    },
    {
        // Deletes readings older than the 6-month window from the partition
        // that straddles it, then recomputes the segments it touched.
        name: "purge-expired-readings",
        intervalMs: DAY,
        offsetMs: 10 * MINUTE,
        timeoutMs: 20 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "SELECT purge_expired_readings() AS result",
    },
    {
        // Monthly in pg_cron; daily here is a no-op when nothing is due.
        // DROP TABLE needs an ACCESS EXCLUSIVE lock on the readings parent,
        // so the lock wait is kept short: better to retry later than to
        // queue every ingest behind it.
        name: "drop-old-readings-partitions",
        intervalMs: DAY,
        offsetMs: 15 * MINUTE,
        timeoutMs: 2 * MINUTE,
        lockTimeoutMs: 5 * SECOND,
        sql: "SELECT drop_old_readings_partitions()",
    },
    {
        name: "replay-unmatched-readings",
        intervalMs: DAY,
        offsetMs: 20 * MINUTE,
        timeoutMs: 15 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "SELECT replay_unmatched_readings() AS result",
    },
    {
        name: "nightly-aggregate-recompute",
        intervalMs: DAY,
        offsetMs: 30 * MINUTE,
        timeoutMs: 30 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "SELECT nightly_recompute_aggregates()",
    },
    {
        name: "pothole-expiry",
        intervalMs: DAY,
        offsetMs: 40 * MINUTE,
        timeoutMs: 5 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "SELECT expire_unconfirmed_potholes()",
    },
    {
        // rate_limits, token_challenges, feedback client_ip, processed_batches,
        // pothole_actions, reporter/contributor marks and unmatched_readings
        // retention (run_retention_sweeps in 20261108150000).
        name: "retention-sweeps",
        intervalMs: DAY,
        offsetMs: 45 * MINUTE,
        timeoutMs: 10 * MINUTE,
        lockTimeoutMs: 30 * SECOND,
        sql: "SELECT run_retention_sweeps() AS result",
    },
];

/// A failed run is retried after this long (never later than its interval).
export function retryMsFor(job: ScheduledJob): number {
    return Math.min(job.intervalMs, 15 * MINUTE);
}

/// How long since the last success before /health/deep calls a job stale:
/// two missed intervals plus one full run.
export function staleAfterMsFor(job: ScheduledJob): number {
    return 2 * job.intervalMs + job.timeoutMs;
}

/// The same condition server.ts uses to start the scheduler.
export function isSchedulerEnabled(
    env: { get(key: string): string | undefined } = Deno.env,
): boolean {
    return Boolean(env.get("RAILWAY_ENVIRONMENT")) || env.get("ENABLE_SCHEDULER") === "true";
}

let _startedAtMs: number | null = null;

/// Milliseconds since this process started its scheduler, or null if it never did.
export function schedulerUptimeMs(nowMs: number = Date.now()): number | null {
    return _startedAtMs === null ? null : Math.max(0, nowMs - _startedAtMs);
}

// Minimal surface of the postgres.js client the scheduler needs; lets tests
// pass a fake without a database.
export type SchedulerRow = Record<string, unknown>;
export type SchedulerTx = {
    unsafe(query: string, params?: unknown[]): Promise<readonly SchedulerRow[]>;
};
export type SchedulerSql = SchedulerTx & {
    begin<T>(fn: (tx: SchedulerTx) => Promise<T>): Promise<T>;
};

export type JobOutcome =
    | { status: "ran"; durationMs: number }
    | { status: "locked" }
    | { status: "not_due"; secondsUntilDue: number }
    | { status: "failed"; durationMs: number; error: string };

type Logger = (msg: string) => void;

const defaultLog: Logger = (msg) => console.log(`[scheduler] ${msg}`);
const defaultErrorLog: Logger = (msg) => console.error(`[scheduler] ${msg}`);

function lockKey(job: ScheduledJob): string {
    return `roadsense-scheduler:${job.name}`;
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}

// A job's own result (e.g. run_retention_sweeps' counts) is kept in
// scheduler_job_runs.last_result when it is a JSON object.
function jsonResult(rows: readonly SchedulerRow[]): string | null {
    const value = rows?.[0]?.result;
    if (value === null || value === undefined || typeof value !== "object") return null;
    try {
        return JSON.stringify(value);
    } catch {
        return null;
    }
}

type RunResult =
    | { kind: "locked" }
    | { kind: "not_due"; seconds: number }
    | { kind: "ran" };

/// Runs one due-check-and-maybe-run cycle for `job` in a single transaction.
/// Never throws: failures are recorded in scheduler_job_runs and logged.
export async function runJobOnce(
    sql: SchedulerSql,
    job: ScheduledJob,
    opts?: { log?: Logger; errorLog?: Logger; nowMs?: () => number },
): Promise<JobOutcome> {
    const log = opts?.log ?? defaultLog;
    const errorLog = opts?.errorLog ?? defaultErrorLog;
    const nowMs = opts?.nowMs ?? Date.now;
    const startedMs = nowMs();
    const startedIso = new Date(startedMs).toISOString();

    let result: RunResult;
    try {
        result = await sql.begin(async (tx): Promise<RunResult> => {
            await tx.unsafe(
                "SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)",
                [String(Math.trunc(job.timeoutMs)), String(Math.trunc(job.lockTimeoutMs))],
            );

            const lockRows = await tx.unsafe(
                "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0)) AS locked",
                [lockKey(job)],
            );
            if (lockRows?.[0]?.locked !== true) {
                return { kind: "locked" };
            }

            const dueRows = await tx.unsafe(
                "SELECT scheduler_job_seconds_until_due($1, $2, $3) AS seconds",
                [job.name, Math.ceil(job.intervalMs / SECOND), Math.ceil(retryMsFor(job) / SECOND)],
            );
            const seconds = Number(dueRows?.[0]?.seconds ?? 0);
            if (Number.isFinite(seconds) && seconds > 0) {
                return { kind: "not_due", seconds };
            }

            const jobRows = await tx.unsafe(job.sql);
            await tx.unsafe(
                "SELECT record_scheduler_job_run($1, now(), true, $2, NULL, $3::text::jsonb)",
                [job.name, Math.max(0, Math.round(nowMs() - startedMs)), jsonResult(jobRows)],
            );
            return { kind: "ran" };
        });
    } catch (error) {
        const durationMs = Math.max(0, Math.round(nowMs() - startedMs));
        const message = errorMessage(error);
        errorLog(`${job.name} FAILED in ${durationMs}ms: ${message}`);
        try {
            await sql.unsafe(
                "SELECT record_scheduler_job_run($1, $2::timestamptz, false, $3, $4, NULL)",
                [job.name, startedIso, durationMs, message],
            );
        } catch (recordError) {
            errorLog(`${job.name}: could not record the failed run: ${errorMessage(recordError)}`);
        }
        return { status: "failed", durationMs, error: message };
    }

    if (result.kind === "locked") {
        log(`${job.name} skipped: another run holds the job lock`);
        return { status: "locked" };
    }
    if (result.kind === "not_due") {
        return { status: "not_due", secondsUntilDue: result.seconds };
    }
    const durationMs = Math.max(0, Math.round(nowMs() - startedMs));
    log(`${job.name} ok in ${durationMs}ms`);
    return { status: "ran", durationMs };
}

/// Delay until the next due-check after an outcome.
export function nextCheckDelayMs(job: ScheduledJob, outcome: JobOutcome): number {
    const retryMs = retryMsFor(job);
    switch (outcome.status) {
        case "ran":
            return job.intervalMs;
        case "failed":
            return retryMs;
        case "locked":
            // Another replica is running it; look again once a retry window
            // has passed (it will usually be not_due by then).
            return retryMs;
        case "not_due":
            // Land just after the database says it is due, but keep checking
            // at least every retry window in case another replica's run fails.
            return Math.min(Math.max(outcome.secondsUntilDue * SECOND + SECOND, SECOND), retryMs);
    }
}

export type ScheduledHandle = { stop: () => Promise<void> };

export function startScheduler(opts?: {
    sqlOverride?: SchedulerSql;
    logger?: Logger;
    errorLogger?: Logger;
    jobs?: readonly ScheduledJob[];
    jitterMs?: () => number;
}): ScheduledHandle {
    const log = opts?.logger ?? defaultLog;
    const errorLog = opts?.errorLogger ?? defaultErrorLog;
    const jobs = opts?.jobs ?? SCHEDULED_JOBS;
    const jitter = opts?.jitterMs ?? (() => Math.floor(Math.random() * 30 * SECOND));
    const timers = new Map<string, number>();
    const inFlight = new Set<Promise<void>>();
    let stopped = false;

    _startedAtMs = Date.now();

    // postgres.js' Sql type is far richer than SchedulerSql; the scheduler
    // only uses begin() and unsafe().
    const sql = (): SchedulerSql => opts?.sqlOverride ?? (schedulerDb() as unknown as SchedulerSql);

    const schedule = (job: ScheduledJob, delayMs: number) => {
        if (stopped) return;
        const handle = setTimeout(() => {
            timers.delete(job.name);
            const run = (async () => {
                let outcome: JobOutcome;
                try {
                    outcome = await runJobOnce(sql(), job, { log, errorLog });
                } catch (error) {
                    // runJobOnce records its own failures; this only catches a
                    // pool that could not be created at all (e.g. missing
                    // DATABASE_URL).
                    errorLog(`${job.name} could not start: ${errorMessage(error)}`);
                    outcome = { status: "failed", durationMs: 0, error: errorMessage(error) };
                }
                schedule(job, nextCheckDelayMs(job, outcome));
            })();
            inFlight.add(run);
            run.finally(() => inFlight.delete(run));
        }, delayMs);
        timers.set(job.name, handle);
    };

    for (const job of jobs) {
        schedule(job, job.offsetMs + jitter());
    }

    log(`started ${jobs.length} background jobs`);
    return {
        stop: async () => {
            stopped = true;
            for (const handle of timers.values()) clearTimeout(handle);
            timers.clear();
            await Promise.allSettled([...inFlight]);
        },
    };
}
