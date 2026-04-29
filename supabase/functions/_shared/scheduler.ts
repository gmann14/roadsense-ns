// In-process scheduler for the deployments where pg_cron isn't available
// (Railway PostGIS template). The migrations install no-op stubs for
// cron.schedule/cron.unschedule so the schema applies cleanly, but the
// scheduled jobs never fire on those environments. This file fires them
// from the Deno service instead.
//
// Cadences match the cron.schedule(...) entries in the migrations:
//   - public_stats_mv: every 5 min
//   - public_worst_segments_mv: every 15 min
//   - create_next_readings_partition: daily (cheap, idempotent — saves us
//     from a hard outage at the next month boundary if it falls between
//     manual checks)
//   - drop_old_readings_partitions / nightly_recompute_aggregates /
//     expire_unconfirmed_potholes / rate-limit GC: daily, at startup-aligned
//     intervals.
//
// Best-effort: errors are logged, never thrown — a transient query failure
// must not crash the request loop. Multiple replicas all run their own
// schedulers; that's safe because each job is idempotent (REFRESH CONCURRENTLY,
// CREATE PARTITION IF NOT EXISTS, etc).

import { db, type DB } from "../db.ts";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

type Job = {
    name: string;
    intervalMs: number;
    sql: string;
};

const JOBS: Job[] = [
    { name: "refresh-public-stats-mv",          intervalMs: 5 * MINUTE,  sql: "REFRESH MATERIALIZED VIEW CONCURRENTLY public_stats_mv" },
    { name: "refresh-public-worst-segments-mv", intervalMs: 15 * MINUTE, sql: "REFRESH MATERIALIZED VIEW CONCURRENTLY public_worst_segments_mv" },
    { name: "create-next-readings-partition",   intervalMs: DAY,         sql: "SELECT create_next_readings_partition()" },
    { name: "nightly-aggregate-recompute",      intervalMs: DAY,         sql: "SELECT nightly_recompute_aggregates()" },
    { name: "pothole-expiry",                   intervalMs: DAY,         sql: "SELECT expire_unconfirmed_potholes()" },
    { name: "rate-limit-gc",                    intervalMs: DAY,         sql: "DELETE FROM rate_limits WHERE bucket_start < now() - INTERVAL '7 days'" },
    // drop_old_readings_partitions runs monthly in pg_cron; daily here is
    // wasteful but safe — the function is a no-op when there's nothing to drop.
    { name: "drop-old-readings-partitions",     intervalMs: DAY,         sql: "SELECT drop_old_readings_partitions()" },
];

export type ScheduledHandle = { stop: () => void };

export function startScheduler(opts?: { sqlOverride?: DB; logger?: (msg: string) => void }): ScheduledHandle {
    const log = opts?.logger ?? ((msg: string) => console.log(`[scheduler] ${msg}`));
    const handles: number[] = [];

    for (const job of JOBS) {
        // Run once at startup so the very first request after deploy doesn't
        // see stale data. Stagger by a small jitter so a fleet of replicas
        // doesn't dogpile.
        const jitterMs = Math.floor(Math.random() * 30_000);
        setTimeout(() => runOnce(job, opts?.sqlOverride, log), jitterMs);

        const handle = setInterval(() => runOnce(job, opts?.sqlOverride, log), job.intervalMs);
        handles.push(handle);
    }

    log(`started ${JOBS.length} background jobs`);
    return {
        stop: () => {
            for (const h of handles) clearInterval(h);
        },
    };
}

async function runOnce(job: Job, sqlOverride: DB | undefined, log: (msg: string) => void): Promise<void> {
    const sql = sqlOverride ?? db();
    const startedAt = Date.now();
    try {
        await sql.unsafe(job.sql);
        log(`${job.name} ok in ${Date.now() - startedAt}ms`);
    } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        log(`${job.name} FAILED in ${Date.now() - startedAt}ms: ${message}`);
    }
}
