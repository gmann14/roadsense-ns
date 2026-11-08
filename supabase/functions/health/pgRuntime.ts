import { db, type DB } from "../db.ts";
import {
    isSchedulerEnabled,
    SCHEDULED_JOBS,
    type ScheduledJob,
    schedulerUptimeMs,
} from "../_shared/scheduler.ts";
import type { DeepHealthProbe } from "./handler.ts";
import { evaluateSchedulerJobs, type SchedulerHealth, type SchedulerJobRow } from "./jobs.ts";

type SchedulerRunsRow = { now_ms: number | string | null; jobs: unknown };

function toJobRows(value: unknown): SchedulerJobRow[] {
    if (!Array.isArray(value)) return [];
    const rows: SchedulerJobRow[] = [];
    for (const item of value) {
        if (!item || typeof item !== "object") continue;
        const candidate = item as Record<string, unknown>;
        if (typeof candidate.job_name !== "string") continue;
        rows.push({
            job_name: candidate.job_name,
            last_success_at: typeof candidate.last_success_at === "string" ? candidate.last_success_at : null,
            consecutive_failures: Number(candidate.consecutive_failures ?? 0) || 0,
        });
    }
    return rows;
}

export function createPgDbCheck(
    sqlOverride?: DB,
    opts?: {
        schedulerEnabled?: boolean;
        uptimeMs?: () => number | null;
        jobs?: readonly ScheduledJob[];
    },
): () => Promise<DeepHealthProbe | null> {
    return async () => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`SELECT db_healthcheck() AS ts`) as Array<{ ts: string | Date | null }>;
        const ts = rows?.[0]?.ts;
        if (!ts) return null;
        const dbTime = ts instanceof Date ? ts.toISOString() : String(ts);

        if (!(opts?.schedulerEnabled ?? isSchedulerEnabled())) {
            return { dbTime };
        }

        let scheduler: SchedulerHealth;
        try {
            const runs = (await sql`
                SELECT
                    (extract(epoch FROM now()) * 1000)::FLOAT8 AS now_ms,
                    COALESCE(
                        jsonb_agg(jsonb_build_object(
                            'job_name', job_name,
                            'last_success_at', last_success_at,
                            'consecutive_failures', consecutive_failures
                        )),
                        '[]'::JSONB
                    ) AS jobs
                FROM scheduler_job_runs
            `) as SchedulerRunsRow[];
            const nowMs = Number(runs?.[0]?.now_ms);
            scheduler = evaluateSchedulerJobs(toJobRows(runs?.[0]?.jobs), {
                nowMs: Number.isFinite(nowMs) ? nowMs : Date.now(),
                uptimeMs: (opts?.uptimeMs ?? schedulerUptimeMs)(),
                jobs: opts?.jobs ?? SCHEDULED_JOBS,
            });
        } catch (error) {
            // The database answered the liveness probe, so report it reachable
            // but the scheduler state unknown (degraded) rather than failing
            // the whole check.
            console.error("deep-health scheduler_job_runs read failed", { error });
            scheduler = { status: "unavailable", jobs: {} };
        }

        return { dbTime, scheduler };
    };
}
