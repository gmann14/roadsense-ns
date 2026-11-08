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

type ProcessedBatchRow = {
    accepted_count: number | string | null;
    rejected_count: number | string | null;
    rejected_reasons: unknown;
};

function normalizeRejectedReasons(value: unknown): Record<string, number> {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        return {};
    }
    const reasons: Record<string, number> = {};
    for (const [key, count] of Object.entries(value)) {
        const numeric = Number(count);
        if (Number.isFinite(numeric)) {
            reasons[key] = numeric;
        }
    }
    return reasons;
}

/// Stored outcome of a batch this device already uploaded, or null. Primary
/// key lookup on processed_batches(batch_id), filtered to the same token hash.
export function createPgFindProcessedBatch(sqlOverride?: DB) {
    return async (
        { batchId, tokenHashHex }: { batchId: string; tokenHashHex: string },
    ): Promise<UploadResult | null> => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT accepted_count, rejected_count, rejected_reasons
            FROM processed_batches
            WHERE batch_id = ${batchId}::uuid
              AND device_token_hash = decode(${tokenHashHex}, 'hex')
        `) as ProcessedBatchRow[];
        const row = rows[0];
        if (!row) {
            return null;
        }
        return {
            accepted: Number(row.accepted_count ?? 0),
            rejected: Number(row.rejected_count ?? 0),
            duplicate: true,
            rejected_reasons: normalizeRejectedReasons(row.rejected_reasons),
        };
    };
}
