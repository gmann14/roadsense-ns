import { createClient } from "npm:@supabase/supabase-js@2";
import { createStatsHandler, type PublicMapBounds, type PublicStats } from "./handler.ts";

type PublicStatsRow = Omit<PublicStats, "map_bounds" | "pothole_bounds"> & {
    map_bounds?: unknown;
    pothole_bounds?: unknown;
};

function createFetchStats() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async (): Promise<PublicStats | null> => {
        const { data, error } = await supabase
            .from("public_stats_mv")
            .select(`
                total_km_mapped,
                total_readings,
                segments_scored,
                active_potholes,
                municipalities_covered,
                map_bounds,
                pothole_bounds,
                generated_at
            `)
            .maybeSingle();

        if (error) {
            throw error;
        }

        if (!data) {
            return null;
        }

        const row = data as PublicStatsRow;
        return {
            total_km_mapped: row.total_km_mapped,
            total_readings: row.total_readings,
            segments_scored: row.segments_scored,
            active_potholes: row.active_potholes,
            municipalities_covered: row.municipalities_covered,
            map_bounds: normalizeBounds(row.map_bounds),
            pothole_bounds: normalizeBounds(row.pothole_bounds),
            generated_at: row.generated_at,
        };
    };
}

function normalizeBounds(value: unknown): PublicMapBounds | null {
    if (!value || typeof value !== "object") {
        return null;
    }

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

Deno.serve(
    createStatsHandler({
        fetchStats: createFetchStats(),
    }),
);
