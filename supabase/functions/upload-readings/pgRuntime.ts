import { db, type DB } from "../db.ts";
import type { UploadPayload, UploadResult } from "./handler.ts";

export function createPgIngestBatch(sqlOverride?: DB) {
    return async ({ payload, tokenHashHex }: { payload: UploadPayload; tokenHashHex: string }): Promise<UploadResult> => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT ingest_reading_batch(
                ${payload.batch_id}::uuid,
                decode(${tokenHashHex}, 'hex')::bytea,
                ${sql.json(payload.readings) as unknown as string}::jsonb,
                ${payload.client_sent_at}::timestamptz,
                ${payload.client_app_version}::text,
                ${payload.client_os_version}::text
            ) AS result
        `) as Array<{ result: UploadResult | null }>;
        const result = rows[0]?.result;
        if (!result) {
            throw new Error("ingest_reading_batch returned no data");
        }
        return result;
    };
}
