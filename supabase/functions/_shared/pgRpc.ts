// Generic Postgres RPC adapter for functions with plain-type args (text,
// numeric, timestamptz, integer, jsonb). Wraps the call result in the same
// {data, error} shape supabase-js returns so existing runtimes drop in.
//
// IMPORTANT: do not use this for functions that need bytea or other types
// requiring explicit casts. For those, write a per-function pgRuntime that
// emits the raw SQL with `decode(...)::bytea` etc.

import { db, type DB } from "../db.ts";

export type RpcResponse<T> = { data: T | null; error: { message?: string } | null };

export type PgRpc = <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>;

export function createPgRpc(sqlOverride?: DB): PgRpc {
    return async <T>(fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
        const sql = sqlOverride ?? db();
        try {
            const keys = Object.keys(params);
            const placeholders = keys.map((_, i) => `$${i + 1}`).join(", ");
            const values = keys.map((k) => params[k] === undefined ? null : params[k]);
            const query = `SELECT ${fn}(${placeholders}) AS result`;
            const rows = (await sql.unsafe(query, values)) as Array<{ result: T | null }>;
            return { data: rows[0]?.result ?? null, error: null };
        } catch (error) {
            return {
                data: null,
                error: { message: error instanceof Error ? error.message : String(error) },
            };
        }
    };
}
