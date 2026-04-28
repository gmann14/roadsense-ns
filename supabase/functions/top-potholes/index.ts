import { createClient } from "npm:@supabase/supabase-js@2";
import { createTopPotholesHandler, type PotholeRow } from "./handler.ts";

function createFetchTopPotholes() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async (limit: number): Promise<PotholeRow[]> => {
        const { data: rows, error: rpcError } = await supabase.rpc("get_top_potholes", {
            p_limit: limit,
        });

        if (rpcError) {
            throw rpcError;
        }

        return rows ?? [];
    };
}

Deno.serve(
    createTopPotholesHandler({
        fetchTopPotholes: createFetchTopPotholes(),
    }),
);
