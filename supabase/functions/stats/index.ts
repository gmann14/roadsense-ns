import { createClient } from "npm:@supabase/supabase-js@2";
import { createStatsHandler, type PublicStats } from "./handler.ts";

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
                generated_at
            `)
            .maybeSingle();

        if (error) {
            throw error;
        }

        return data;
    };
}

Deno.serve(
    createStatsHandler({
        fetchStats: createFetchStats(),
    }),
);
