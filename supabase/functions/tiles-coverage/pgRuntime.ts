import { db, type DB } from "../db.ts";

export function createPgCoverageTileRpc(sqlOverride?: DB) {
    return async ({ z, x, y }: { z: number; x: number; y: number }) => {
        const sql = sqlOverride ?? db();
        try {
            const rows = (await sql`SELECT get_coverage_tile(${z}, ${x}, ${y}) AS bytes`) as Array<{
                bytes: Uint8Array | null;
            }>;
            return { data: rows[0]?.bytes ?? null, error: null };
        } catch (error) {
            return {
                data: null,
                error: { message: error instanceof Error ? error.message : String(error) },
            };
        }
    };
}
