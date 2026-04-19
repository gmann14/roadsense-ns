import { createClient } from "npm:@supabase/supabase-js@2";
import {
    createSegmentsWorstHandler,
    type WorstSegmentRow,
    type WorstSegmentsQuery,
    type WorstSegmentsResult,
} from "./handler.ts";

function createSupabase() {
    return createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
}

function createFetchKnownMunicipalities() {
    const supabase = createSupabase();

    return async (): Promise<string[]> => {
        const { data, error } = await supabase
            .from("road_segments")
            .select("municipality")
            .not("municipality", "is", null)
            .limit(5000);

        if (error) {
            throw error;
        }

        return [...new Set((data ?? []).map((row) => row.municipality).filter(Boolean))].sort();
    };
}

function createFetchWorstSegments() {
    const supabase = createSupabase();

    return async (query: WorstSegmentsQuery): Promise<WorstSegmentsResult> => {
        let request = supabase
            .from("public_worst_segments_mv")
            .select(`
                segment_id,
                road_name,
                municipality,
                road_type,
                category,
                confidence,
                avg_roughness_score,
                score_last_30d,
                score_30_60d,
                trend,
                total_readings,
                unique_contributors,
                pothole_count,
                last_reading_at,
                generated_at
            `)
            .order("avg_roughness_score", { ascending: false })
            .order("pothole_count", { ascending: false })
            .order("total_readings", { ascending: false })
            .limit(query.limit);

        if (query.municipality) {
            request = request.eq("municipality", query.municipality);
        }

        const { data, error } = await request;
        if (error) {
            throw error;
        }

        const rows = (data ?? []).map((row, index): WorstSegmentRow => ({
            rank: index + 1,
            segment_id: row.segment_id,
            road_name: row.road_name,
            municipality: row.municipality,
            road_type: row.road_type,
            category: row.category,
            confidence: row.confidence,
            avg_roughness_score: row.avg_roughness_score,
            score_last_30d: row.score_last_30d,
            score_30_60d: row.score_30_60d,
            trend: row.trend,
            total_readings: row.total_readings,
            unique_contributors: row.unique_contributors,
            pothole_count: row.pothole_count,
            last_reading_at: row.last_reading_at,
        }));

        return {
            generated_at: data?.[0]?.generated_at ?? null,
            rows,
        };
    };
}

Deno.serve(
    createSegmentsWorstHandler({
        fetchKnownMunicipalities: createFetchKnownMunicipalities(),
        fetchWorstSegments: createFetchWorstSegments(),
    }),
);
