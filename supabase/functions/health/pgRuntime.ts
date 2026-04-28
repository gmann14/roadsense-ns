import { db, type DB } from "../db.ts";

export function createPgDbCheck(sqlOverride?: DB): () => Promise<string | null> {
    return async () => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`SELECT db_healthcheck() AS ts`) as Array<{ ts: string | Date | null }>;
        const ts = rows[0]?.ts;
        if (!ts) return null;
        return ts instanceof Date ? ts.toISOString() : String(ts);
    };
}
