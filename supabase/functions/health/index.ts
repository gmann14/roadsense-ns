import { createClient } from "npm:@supabase/supabase-js@2";
import { createHealthHandler } from "./handler.ts";

function createDbCheck() {
    const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    return async (): Promise<string | null> => {
        const { data, error } = await supabase.rpc("db_healthcheck");
        if (error) {
            throw error;
        }

        return typeof data === "string" ? data : null;
    };
}

Deno.serve(
    createHealthHandler({
        checkDb: createDbCheck(),
    }),
);
