import { db, type DB } from "../db.ts";
import type { PotholeActionPayload, PotholeActionResult } from "./handler.ts";

export function createPgApplyAction(sqlOverride?: DB) {
    return async ({ payload, tokenHashHex }: { payload: PotholeActionPayload; tokenHashHex: string }): Promise<PotholeActionResult> => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT apply_pothole_action(
                ${payload.action_id}::uuid,
                decode(${tokenHashHex}, 'hex')::bytea,
                ${payload.action_type}::pothole_action_type,
                ${payload.lat}::double precision,
                ${payload.lng}::double precision,
                ${payload.accuracy_m}::numeric,
                ${payload.recorded_at}::timestamptz,
                ${payload.pothole_report_id ?? null}::uuid,
                ${payload.sensor_backed_magnitude_g ?? null}::numeric,
                ${payload.sensor_backed_at ?? null}::timestamptz
            ) AS result
        `) as Array<{ result: PotholeActionResult | null }>;
        const result = rows[0]?.result;
        if (!result) {
            throw new Error("apply_pothole_action returned no data");
        }
        return result;
    };
}
