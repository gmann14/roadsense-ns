import { createClient } from "npm:@supabase/supabase-js@2";
import { createPotholeActionsHandler, type PotholeActionPayload, type PotholeActionResult, type RateLimitResult } from "./handler.ts";
import { createPotholeActionRateLimitChecker } from "./runtime.ts";
import { hashDeviceToken, requireEnv, type RpcResponse } from "../upload-readings/runtime.ts";

function createApplyAction(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
) {
    return async ({ payload, tokenHashHex }: { payload: PotholeActionPayload; tokenHashHex: string }): Promise<PotholeActionResult> => {
        const result = await rpc<PotholeActionResult>("apply_pothole_action", {
            p_action_id: payload.action_id,
            p_device_token_hash: `\\x${tokenHashHex}`,
            p_action_type: payload.action_type,
            p_lat: payload.lat,
            p_lng: payload.lng,
            p_accuracy_m: payload.accuracy_m,
            p_recorded_at: payload.recorded_at,
            p_pothole_report_id: payload.pothole_report_id,
            p_sensor_backed_magnitude_g: payload.sensor_backed_magnitude_g,
            p_sensor_backed_at: payload.sensor_backed_at,
        });

        if (result.error) {
            throw new Error(result.error.message ?? "apply_pothole_action failed");
        }

        if (!result.data) {
            throw new Error("apply_pothole_action returned no data");
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
    createPotholeActionsHandler({
        hashDeviceToken,
        checkRateLimit: createPotholeActionRateLimitChecker(invokeRpc) as (tokenHashHex: string, ip: string) => Promise<RateLimitResult>,
        applyAction: createApplyAction(invokeRpc),
    }),
);
