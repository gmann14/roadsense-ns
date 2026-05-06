import { db, type DB } from "../db.ts";
import type { PotholeRow } from "../potholes/handler.ts";
import { normalizePotholeRow, type DbPotholeRow } from "../potholes/row.ts";

export function createPgFetchTopPotholes(sqlOverride?: DB): (limit: number) => Promise<PotholeRow[]> {
    return async (limit) => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT id, lat, lng, magnitude, confirmation_count,
                   first_reported_at, last_confirmed_at, status, segment_id
            FROM (
                SELECT
                    id,
                    ST_Y(geom) AS lat,
                    ST_X(geom) AS lng,
                    magnitude,
                    confirmation_count,
                    first_reported_at,
                    last_confirmed_at,
                    status,
                    segment_id
                FROM pothole_reports
                WHERE status = 'active'
                ORDER BY
                    confirmation_count DESC,
                    magnitude DESC,
                    last_confirmed_at DESC
                LIMIT LEAST(GREATEST(${limit}::INTEGER, 1), 100)
            ) ranked_potholes
        `) as DbPotholeRow[];
        return rows.map(normalizePotholeRow);
    };
}
