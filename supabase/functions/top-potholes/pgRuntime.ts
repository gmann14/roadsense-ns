import { db, type DB } from "../db.ts";
import type { PotholeRow } from "../potholes/handler.ts";
import { normalizePotholeRow, type DbPotholeRow } from "../potholes/row.ts";

export function createPgFetchTopPotholes(sqlOverride?: DB): (limit: number) => Promise<PotholeRow[]> {
    return async (limit) => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT id, lat, lng, magnitude, confirmation_count,
                   first_reported_at, last_confirmed_at, status, segment_id
            FROM get_top_potholes(${limit}::INTEGER)
        `) as DbPotholeRow[];
        return rows.map(normalizePotholeRow);
    };
}
