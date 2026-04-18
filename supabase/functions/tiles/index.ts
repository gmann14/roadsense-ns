import { createClient } from "npm:@supabase/supabase-js@2";
import { createTileHandler, type TileRpcResult } from "./handler.ts";

function createTileRpc() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async ({ z, x, y }: { z: number; x: number; y: number }): Promise<TileRpcResult> => {
        const { data, error } = await supabase.rpc("get_tile", { z, x, y });
        return { data, error };
    };
}

Deno.serve(createTileHandler({ rpcGetTile: createTileRpc() }));
