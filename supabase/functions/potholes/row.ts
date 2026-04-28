import { toIso } from "../_shared/pg.ts";
import type { PotholeRow } from "./handler.ts";

export type DbPotholeRow = {
    id: string;
    lat: number | string;
    lng: number | string;
    magnitude: number | string;
    confirmation_count: number | string;
    first_reported_at: Date | string | null;
    last_confirmed_at: Date | string | null;
    status: string;
    segment_id: string | null;
};

export function normalizePotholeRow(row: DbPotholeRow): PotholeRow {
    return {
        id: row.id,
        lat: Number(row.lat),
        lng: Number(row.lng),
        magnitude: Number(row.magnitude),
        confirmation_count: Number(row.confirmation_count),
        first_reported_at: toIso(row.first_reported_at) ?? "",
        last_confirmed_at: toIso(row.last_confirmed_at) ?? "",
        status: row.status,
        segment_id: row.segment_id,
    };
}
