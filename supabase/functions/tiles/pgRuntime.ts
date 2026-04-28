import { db, type DB } from "../db.ts";
import type { TileRpc, TileRpcResult } from "./handler.ts";

export function createPgTileRpc(sqlOverride?: DB): TileRpc {
    return async ({ z, x, y }) => {
        const sql = sqlOverride ?? db();
        try {
            const rows = (await sql`SELECT get_tile(${z}, ${x}, ${y}) AS bytes`) as Array<{
                bytes: Uint8Array | null;
            }>;
            return { data: rows[0]?.bytes ?? null, error: null } as TileRpcResult;
        } catch (error) {
            return {
                data: null,
                error: { message: error instanceof Error ? error.message : String(error) },
            } as TileRpcResult;
        }
    };
}
