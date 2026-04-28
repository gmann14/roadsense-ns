// Singleton Postgres pool for the standalone Deno service. Created once at
// module load so each Deno process holds one pool, not one per request.
//
// The Railway internal hostname (postgis.railway.internal) does not present a
// TLS cert; the public TCP proxy does. We toggle SSL accordingly.

import postgres, { type Sql } from "https://deno.land/x/postgresjs@v3.4.4/mod.js";

let _pool: Sql | null = null;

export function db(): Sql {
    if (_pool) return _pool;

    const url = Deno.env.get("DATABASE_URL");
    if (!url || url.trim().length === 0) {
        throw new Error("DATABASE_URL is not set");
    }

    const isRailwayInternal = url.includes("railway.internal");

    _pool = postgres(url, {
        max: Number(Deno.env.get("PG_POOL_MAX") ?? "10"),
        idle_timeout: Number(Deno.env.get("PG_POOL_IDLE_SECONDS") ?? "30"),
        connect_timeout: Number(Deno.env.get("PG_POOL_CONNECT_TIMEOUT") ?? "10"),
        // Internal Railway traffic is on a private network; no TLS overhead.
        // Public connections (anything else) require TLS.
        ssl: isRailwayInternal ? false : "require",
    });

    return _pool;
}

/// For tests: replace the pool with a mock; pass null to re-enable env-driven init.
export function setPoolForTests(pool: Sql | null): void {
    _pool = pool;
}
