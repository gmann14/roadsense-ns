// pg-deno backed implementation of the stats fetch dependency.
//
// Reads a single row from public_stats_mv. Bounds columns are JSONB; we
// already-parsed objects come back as plain objects from postgres-deno.

import { db, type DB as Sql } from "../db.ts";
import type { PublicMapBounds, PublicStats } from "./handler.ts";

type PublicStatsRow = {
    total_km_mapped: number | string;
    total_readings: number | string;
    segments_scored: number | string;
    active_potholes: number | string;
    municipalities_covered: number | string;
    map_bounds: unknown;
    pothole_bounds: unknown;
    generated_at: Date | string;
};

export function createPgFetchStats(
    sqlOverride?: Sql,
): () => Promise<PublicStats | null> {
    return async () => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT
                total_km_mapped,
                total_readings,
                segments_scored,
                active_potholes,
                municipalities_covered,
                map_bounds,
                pothole_bounds,
                generated_at
            FROM public_stats_mv
            LIMIT 1
        `) as PublicStatsRow[];
        if (rows.length === 0) return null;
        const row = rows[0];
        return {
            total_km_mapped: Number(row.total_km_mapped),
            total_readings: Number(row.total_readings),
            segments_scored: Number(row.segments_scored),
            active_potholes: Number(row.active_potholes),
            municipalities_covered: Number(row.municipalities_covered),
            map_bounds: normalizeBounds(row.map_bounds),
            pothole_bounds: normalizeBounds(row.pothole_bounds),
            generated_at: row.generated_at instanceof Date
                ? row.generated_at.toISOString()
                : String(row.generated_at),
        };
    };
}

function normalizeBounds(value: unknown): PublicMapBounds | null {
    if (!value || typeof value !== "object") return null;
    const candidate = value as Record<string, unknown>;
    const minLng = Number(candidate.minLng);
    const minLat = Number(candidate.minLat);
    const maxLng = Number(candidate.maxLng);
    const maxLat = Number(candidate.maxLat);
    if (![minLng, minLat, maxLng, maxLat].every(Number.isFinite)) {
        return null;
    }
    return { minLng, minLat, maxLng, maxLat };
}
