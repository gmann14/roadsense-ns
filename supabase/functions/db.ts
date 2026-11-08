// Singleton Postgres pool for the standalone Deno service. Created once at
// module load so each Deno process holds one pool, not one per request.
//
// The Railway internal hostname (postgis.railway.internal) does not present a
// TLS cert; the public TCP proxy does. We toggle SSL accordingly.

import postgres from "https://deno.land/x/postgresjs@v3.4.4/mod.js";

export type DB = ReturnType<typeof postgres>;

let _pool: DB | null = null;

export function db(): DB {
    if (_pool) return _pool;

    const url = Deno.env.get("DATABASE_URL");
    if (!url || url.trim().length === 0) {
        throw new Error("DATABASE_URL is not set");
    }

    const isRailwayInternal = isRailwayInternalUrl(url);

    _pool = postgres(url, {
        max: Number(Deno.env.get("PG_POOL_MAX") ?? "10"),
        idle_timeout: Number(Deno.env.get("PG_POOL_IDLE_SECONDS") ?? "30"),
        connect_timeout: Number(Deno.env.get("PG_POOL_CONNECT_TIMEOUT") ?? "10"),
        // Internal Railway traffic is on a private network; no TLS overhead.
        // Public connections (anything else) require TLS.
        ssl: isRailwayInternal ? false : "require",
        // Statement-level timeout (P1-3): sent as a Postgres startup/session
        // parameter on every pooled connection. Without this, one wedged
        // query (bad plan, lock wait, runaway RPC) can hold a connection
        // indefinitely and starve the whole `max`-sized pool. Comfortably
        // above any real query here (tile/segment/stats reads and the
        // ingest/action RPCs) but well below "stuck forever".
        connection: {
            statement_timeout: Number(Deno.env.get("PG_STATEMENT_TIMEOUT_MS") ?? "8000"),
        },
    });

    return _pool;
}

/// For tests: replace the pool with a mock; pass null to re-enable env-driven init.
export function setPoolForTests(pool: DB | null): void {
    _pool = pool;
}

let _schedulerPool: DB | null = null;

// Dedicated pool for the in-process scheduler (_shared/scheduler.ts).
//
// The request pool's 8 s session statement_timeout is right for API reads but
// guarantees that nightly_recompute_aggregates, the readings purge and the
// materialized-view refreshes fail once the dataset grows (2026-10-18 review,
// "Railway scheduler is fragile"). This pool has no session statement_timeout;
// every job sets its own `SET LOCAL statement_timeout` / `lock_timeout` inside
// its transaction instead. It is small (one job runs at a time per replica,
// plus one connection for run bookkeeping) so it cannot starve the request
// pool's connection budget.
export function schedulerDb(): DB {
    if (_schedulerPool) return _schedulerPool;

    const url = Deno.env.get("DATABASE_URL");
    if (!url || url.trim().length === 0) {
        throw new Error("DATABASE_URL is not set");
    }

    _schedulerPool = postgres(url, {
        max: Number(Deno.env.get("PG_SCHEDULER_POOL_MAX") ?? "2"),
        idle_timeout: Number(Deno.env.get("PG_POOL_IDLE_SECONDS") ?? "30"),
        connect_timeout: Number(Deno.env.get("PG_POOL_CONNECT_TIMEOUT") ?? "10"),
        ssl: isRailwayInternalUrl(url) ? false : "require",
        connection: {
            application_name: "roadsense-scheduler",
        },
    });

    return _schedulerPool;
}

/// For tests: replace the scheduler pool; pass null to re-enable env-driven init.
export function setSchedulerPoolForTests(pool: DB | null): void {
    _schedulerPool = pool;
}

// Anchored hostname check so a malicious URL like
// `evil.railway.internal.attacker.com` cannot trick us into disabling TLS.
export function isRailwayInternalUrl(rawUrl: string): boolean {
    let host: string;
    try {
        host = new URL(rawUrl).hostname.toLowerCase();
    } catch {
        return false;
    }
    return host === "railway.internal" || host.endsWith(".railway.internal");
}
