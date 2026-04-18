import { createClient } from "npm:@supabase/supabase-js@2";
import { createPotholesHandler, type Bbox, type PotholeRow } from "./handler.ts";

function createFetchPotholes() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async (bbox: Bbox): Promise<PotholeRow[]> => {
        const { data: rows, error: rpcError } = await supabase.rpc("get_potholes_in_bbox", {
            p_min_lng: bbox.minLng,
            p_min_lat: bbox.minLat,
            p_max_lng: bbox.maxLng,
            p_max_lat: bbox.maxLat,
        });

        if (rpcError) {
            throw rpcError;
        }

        return rows ?? [];
    };
}

Deno.serve(
    createPotholesHandler({
        fetchPotholes: createFetchPotholes(),
    }),
);
