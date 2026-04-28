import { db, type DB } from "../db.ts";
import type { Bbox, PotholeRow } from "./handler.ts";

export function createPgFetchPotholes(sqlOverride?: DB): (bbox: Bbox) => Promise<PotholeRow[]> {
    return async (bbox) => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT * FROM get_potholes_in_bbox(
                ${bbox.minLng}::DOUBLE PRECISION,
                ${bbox.minLat}::DOUBLE PRECISION,
                ${bbox.maxLng}::DOUBLE PRECISION,
                ${bbox.maxLat}::DOUBLE PRECISION
            )
        `) as PotholeRow[];
        return rows;
    };
}
