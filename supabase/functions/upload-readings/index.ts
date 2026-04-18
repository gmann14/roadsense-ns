import { createClient } from "npm:@supabase/supabase-js@2";
import { createUploadReadingsHandler, type RateLimitResult, type UploadPayload, type UploadResult } from "./handler.ts";
import { createRateLimitChecker, hashDeviceToken, requireEnv, type RpcResponse } from "./runtime.ts";

function createIngestBatch(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
) {
    return async ({ payload, tokenHashHex }: { payload: UploadPayload; tokenHashHex: string }): Promise<UploadResult> => {
        const result = await rpc<UploadResult>("ingest_reading_batch", {
            p_batch_id: payload.batch_id,
            p_device_token_hash: `\\x${tokenHashHex}`,
            p_readings: payload.readings,
            p_client_sent_at: payload.client_sent_at,
            p_client_app_version: payload.client_app_version,
            p_client_os_version: payload.client_os_version,
        });

        if (result.error || !result.data) {
            throw new Error(result.error?.message ?? "ingest_reading_batch returned no data");
        }

        return result.data;
    };
}

const supabase = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
);

async function invokeRpc<T>(fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> {
    const { data, error } = await supabase.rpc(fn, params);
    return { data, error };
}

Deno.serve(
    createUploadReadingsHandler({
        hashDeviceToken,
        checkRateLimit: createRateLimitChecker(invokeRpc) as (tokenHashHex: string, ip: string) => Promise<RateLimitResult>,
        ingestBatch: createIngestBatch(invokeRpc),
    }),
);
