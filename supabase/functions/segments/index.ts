import { createClient } from "npm:@supabase/supabase-js@2";
import {
    createSegmentsHandler,
    type SegmentAggregate,
    type SegmentDetail,
    type SegmentPothole,
} from "./handler.ts";

function createFetchSegmentDetail() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
    );

    return async (segmentId: string): Promise<SegmentDetail | null> => {
        const { data: segment, error: segmentError } = await supabase
            .from("road_segments")
            .select(`
                id,
                road_name,
                road_type,
                municipality,
                length_m,
                has_speed_bump,
                has_rail_crossing,
                surface_type
            `)
            .eq("id", segmentId)
            .maybeSingle();

        if (segmentError || !segment) {
            return null;
        }

        const { data: aggregate, error: aggregateError } = await supabase
            .from("segment_aggregates")
            .select(`
                avg_roughness_score,
                roughness_category,
                confidence,
                total_readings,
                unique_contributors,
                pothole_count,
                trend,
                score_last_30d,
                score_30_60d,
                last_reading_at,
                updated_at
            `)
            .eq("segment_id", segmentId)
            .maybeSingle();

        if (aggregateError || !aggregate) {
            return null;
        }

        const aggregatePayload: SegmentAggregate = {
            avg_roughness_score: aggregate.avg_roughness_score,
            category: aggregate.roughness_category,
            confidence: aggregate.confidence,
            total_readings: aggregate.total_readings,
            unique_contributors: aggregate.unique_contributors,
            pothole_count: aggregate.pothole_count,
            trend: aggregate.trend,
            score_last_30d: aggregate.score_last_30d,
            score_30_60d: aggregate.score_30_60d,
            last_reading_at: aggregate.last_reading_at,
            updated_at: aggregate.updated_at,
        };

        const { data: potholes, error: potholesError } = await supabase
            .from("pothole_reports")
            .select(`
                id,
                status,
                geom,
                confirmation_count,
                unique_reporters,
                last_confirmed_at
            `)
            .eq("segment_id", segmentId)
            .in("status", ["active", "resolved"])
            .order("last_confirmed_at", { ascending: false })
            .limit(6);

        if (potholesError) {
            return null;
        }

        const potholePayload: SegmentPothole[] = (potholes ?? []).map((pothole) => ({
            id: pothole.id,
            status: pothole.status,
            lat: pothole.geom.coordinates[1],
            lng: pothole.geom.coordinates[0],
            confirmation_count: pothole.confirmation_count,
            unique_reporters: pothole.unique_reporters,
            last_confirmed_at: pothole.last_confirmed_at,
        }));

        return {
            ...segment,
            aggregate: aggregatePayload,
            potholes: potholePayload,
        };
    };
}

Deno.serve(
    createSegmentsHandler({
        fetchSegmentDetail: createFetchSegmentDetail(),
    }),
);
