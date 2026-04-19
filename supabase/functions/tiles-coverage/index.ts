import { createClient } from "npm:@supabase/supabase-js@2";
import { createCoverageTileHandler } from "./handler.ts";

function createCoverageTileRpc() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async ({ z, x, y }: { z: number; x: number; y: number }) =>
        await supabase.rpc("get_coverage_tile", { z, x, y });
}

Deno.serve(
    createCoverageTileHandler({
        rpcGetCoverageTile: createCoverageTileRpc(),
    }),
);
