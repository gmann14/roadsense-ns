import { db, type DB } from "../db.ts";
import type {
    SegmentAggregate,
    SegmentDetail,
    SegmentPothole,
} from "./handler.ts";

type SegmentRow = {
    id: string;
    road_name: string | null;
    road_type: string;
    municipality: string | null;
    length_m: number | string;
    has_speed_bump: boolean;
    has_rail_crossing: boolean;
    surface_type: string | null;
};

type AggregateRow = {
    avg_roughness_score: number | string;
    roughness_category: string;
    confidence: string;
    total_readings: number | string;
    unique_contributors: number | string;
    pothole_count: number | string;
    trend: string;
    score_last_30d: number | string | null;
    score_30_60d: number | string | null;
    last_reading_at: Date | string | null;
    updated_at: Date | string;
};

type PotholeRow = {
    id: string;
    status: string;
    geom: { coordinates: [number, number] };
    confirmation_count: number | string;
    unique_reporters: number | string;
    last_confirmed_at: Date | string;
};

export function createPgFetchSegmentDetail(sqlOverride?: DB) {
    return async (segmentId: string): Promise<SegmentDetail | null> => {
        const sql = sqlOverride ?? db();

        const segments = (await sql`
            SELECT id, road_name, road_type, municipality, length_m,
                   has_speed_bump, has_rail_crossing, surface_type
            FROM road_segments
            WHERE id = ${segmentId}::uuid
            LIMIT 1
        `) as SegmentRow[];

        if (segments.length === 0) return null;
        const segment = segments[0];

        const aggregates = (await sql`
            SELECT avg_roughness_score, roughness_category, confidence,
                   total_readings, unique_contributors, pothole_count, trend,
                   score_last_30d, score_30_60d, last_reading_at, updated_at
            FROM segment_aggregates
            WHERE segment_id = ${segmentId}::uuid
            LIMIT 1
        `) as AggregateRow[];

        if (aggregates.length === 0) return null;
        const aggregate = aggregates[0];

        const potholes = (await sql`
            SELECT id, status, ST_AsGeoJSON(geom)::jsonb AS geom,
                   confirmation_count, unique_reporters, last_confirmed_at
            FROM pothole_reports
            WHERE segment_id = ${segmentId}::uuid
              AND status IN ('active', 'resolved')
            ORDER BY last_confirmed_at DESC
            LIMIT 6
        `) as PotholeRow[];

        const aggregatePayload: SegmentAggregate = {
            avg_roughness_score: Number(aggregate.avg_roughness_score),
            category: aggregate.roughness_category as SegmentAggregate["category"],
            confidence: aggregate.confidence as SegmentAggregate["confidence"],
            total_readings: Number(aggregate.total_readings),
            unique_contributors: Number(aggregate.unique_contributors),
            pothole_count: Number(aggregate.pothole_count),
            trend: aggregate.trend as SegmentAggregate["trend"],
            score_last_30d: aggregate.score_last_30d == null ? null : Number(aggregate.score_last_30d),
            score_30_60d: aggregate.score_30_60d == null ? null : Number(aggregate.score_30_60d),
            last_reading_at: toIso(aggregate.last_reading_at),
            updated_at: toIso(aggregate.updated_at) ?? new Date().toISOString(),
        };

        const potholePayload: SegmentPothole[] = potholes.map((p) => ({
            id: p.id,
            status: p.status as SegmentPothole["status"],
            lat: p.geom.coordinates[1],
            lng: p.geom.coordinates[0],
            confirmation_count: Number(p.confirmation_count),
            unique_reporters: Number(p.unique_reporters),
            last_confirmed_at: toIso(p.last_confirmed_at) ?? new Date().toISOString(),
        }));

        return {
            id: segment.id,
            road_name: segment.road_name,
            road_type: segment.road_type,
            municipality: segment.municipality,
            length_m: Number(segment.length_m),
            has_speed_bump: segment.has_speed_bump,
            has_rail_crossing: segment.has_rail_crossing,
            surface_type: segment.surface_type,
            aggregate: aggregatePayload,
            potholes: potholePayload,
        };
    };
}

function toIso(value: Date | string | null | undefined): string | null {
    if (!value) return null;
    return value instanceof Date ? value.toISOString() : String(value);
}
