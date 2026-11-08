import { errorResponse, jsonResponse } from "../_shared/http.ts";
import type { SchedulerHealth } from "./jobs.ts";

export type BuildInfo = {
    version: string;
    commit: string;
    deployed_at: string | null;
};

type Env = { get(key: string): string | undefined };

function firstSet(env: Env, keys: readonly string[]): string | null {
    for (const key of keys) {
        const value = env.get(key)?.trim();
        if (value) return value;
    }
    return null;
}

/// Build metadata for /health. Railway injects RAILWAY_GIT_COMMIT_SHA for
/// GitHub-triggered deploys; GIT_COMMIT_SHA (and the legacy GIT_SHA) cover
/// CLI/image deploys that set it explicitly. The version is APP_VERSION.
export function buildInfo(env: Env = Deno.env): BuildInfo {
    return {
        version: firstSet(env, ["APP_VERSION"]) ?? "dev",
        commit: firstSet(env, ["RAILWAY_GIT_COMMIT_SHA", "GIT_COMMIT_SHA", "GIT_SHA"]) ?? "local",
        deployed_at: firstSet(env, ["DEPLOYED_AT"]),
    };
}

// /health is intentionally a process-liveness probe with NO database call so a
// flood of unauthenticated probes can't exhaust PG_POOL_MAX. Use /health/deep
// (apikey-gated) for the database round-trip.
export function createHealthHandler() {
    return function handleHealthRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return Promise.resolve(
                new Response(null, {
                    status: 405,
                    headers: { "x-request-id": requestId },
                }),
            );
        }

        return Promise.resolve(
            jsonResponse(
                { status: "ok", ...buildInfo() },
                200,
                { "cache-control": "no-store" },
                requestId,
            ),
        );
    };
}

/// Result of the deep check. A bare string (the database timestamp) is still
/// accepted for checkers that only probe the database.
export type DeepHealthProbe = {
    dbTime: string;
    /// Present when this deployment runs the in-process scheduler.
    scheduler?: SchedulerHealth;
};

export function createDeepHealthHandler(
    deps: { checkDb: () => Promise<string | DeepHealthProbe | null> },
) {
    return async function handleDeepHealthRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        try {
            const result = await deps.checkDb();
            const probe: DeepHealthProbe | null = typeof result === "string"
                ? (result ? { dbTime: result } : null)
                : result;
            if (!probe?.dbTime) {
                return errorResponse(
                    "service_unavailable",
                    "Database is unreachable.",
                    503,
                    requestId,
                    { status: "error", db: "unreachable" },
                    { "cache-control": "no-store" },
                );
            }

            const info = buildInfo();
            // A stale or failing scheduled job (or an unreadable job table)
            // marks the service degraded: 503 so uptime monitors alert, with
            // the per-job breakdown in the body.
            const degraded = probe.scheduler !== undefined && probe.scheduler.status !== "ok";

            return jsonResponse(
                {
                    status: degraded ? "degraded" : "ok",
                    version: info.version,
                    commit: info.commit,
                    deployed_at: info.deployed_at ?? probe.dbTime,
                    db: "reachable",
                    ...(probe.scheduler ? { scheduler: probe.scheduler } : {}),
                },
                degraded ? 503 : 200,
                { "cache-control": "no-store" },
                requestId,
            );
        } catch (error) {
            console.error("deep-health database check failed", {
                request_id: requestId,
                error,
            });

            return errorResponse(
                "service_unavailable",
                "Database is unreachable.",
                503,
                requestId,
                { status: "error", db: "unreachable" },
                { "cache-control": "no-store" },
            );
        }
    };
}
