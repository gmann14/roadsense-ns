import { db, type DB } from "../db.ts";
import type { WorstSegmentRow, WorstSegmentsQuery, WorstSegmentsResult } from "./handler.ts";

type WorstRow = {
    segment_id: string;
    road_name: string | null;
    municipality: string | null;
    road_type: string;
    category: string;
    confidence: string;
    avg_roughness_score: number | string;
    score_last_30d: number | string | null;
    score_30_60d: number | string | null;
    trend: string;
    total_readings: number | string;
    unique_contributors: number | string;
    pothole_count: number | string;
    last_reading_at: Date | string | null;
    generated_at: Date | string | null;
};

export function createPgFetchKnownMunicipalities(sqlOverride?: DB) {
    return async (): Promise<string[]> => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            SELECT DISTINCT municipality FROM road_segments
            WHERE municipality IS NOT NULL
            ORDER BY municipality
            LIMIT 5000
        `) as Array<{ municipality: string }>;
        return rows.map((r) => r.municipality);
    };
}

export function createPgFetchWorstSegments(sqlOverride?: DB) {
    return async (query: WorstSegmentsQuery): Promise<WorstSegmentsResult> => {
        const sql = sqlOverride ?? db();
        const rows = query.municipality
            ? (await sql`
                SELECT segment_id, road_name, municipality, road_type, category, confidence,
                       avg_roughness_score, score_last_30d, score_30_60d, trend,
                       total_readings, unique_contributors, pothole_count, last_reading_at, generated_at
                FROM public_worst_segments_mv
                WHERE municipality = ${query.municipality}
                ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC
                LIMIT ${query.limit}
            `) as WorstRow[]
            : (await sql`
                SELECT segment_id, road_name, municipality, road_type, category, confidence,
                       avg_roughness_score, score_last_30d, score_30_60d, trend,
                       total_readings, unique_contributors, pothole_count, last_reading_at, generated_at
                FROM public_worst_segments_mv
                ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC
                LIMIT ${query.limit}
            `) as WorstRow[];

        const result: WorstSegmentRow[] = rows.map((row, index) => ({
            rank: index + 1,
            segment_id: row.segment_id,
            road_name: row.road_name,
            municipality: row.municipality,
            road_type: row.road_type,
            category: row.category as WorstSegmentRow["category"],
            confidence: row.confidence as WorstSegmentRow["confidence"],
            avg_roughness_score: Number(row.avg_roughness_score),
            score_last_30d: row.score_last_30d == null ? null : Number(row.score_last_30d),
            score_30_60d: row.score_30_60d == null ? null : Number(row.score_30_60d),
            trend: row.trend as WorstSegmentRow["trend"],
            total_readings: Number(row.total_readings),
            unique_contributors: Number(row.unique_contributors),
            pothole_count: Number(row.pothole_count),
            last_reading_at: toIso(row.last_reading_at),
        }));

        return {
            generated_at: toIso(rows[0]?.generated_at ?? null),
            rows: result,
        };
    };
}

function toIso(value: Date | string | null | undefined): string | null {
    if (!value) return null;
    return value instanceof Date ? value.toISOString() : String(value);
}
