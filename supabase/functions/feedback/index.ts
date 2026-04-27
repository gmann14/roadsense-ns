import { createClient } from "npm:@supabase/supabase-js@2";
import {
    createFeedbackHandler,
    type FeedbackInsertResult,
    type FeedbackPayload,
    type RateLimitResult,
} from "./handler.ts";
import { createFeedbackRateLimitChecker } from "./runtime.ts";
import { requireEnv, type RpcResponse } from "../upload-readings/runtime.ts";

const supabase = createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
);

async function invokeRpc<T>(fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> {
    const { data, error } = await supabase.rpc(fn, params);
    return { data, error };
}

async function insertFeedback(params: {
    payload: FeedbackPayload;
    clientIp: string;
    userAgent: string | null;
    requestId: string;
}): Promise<FeedbackInsertResult> {
    const { data, error } = await supabase
        .from("feedback_submissions")
        .insert({
            source: params.payload.source,
            category: params.payload.category,
            message: params.payload.message,
            reply_email: params.payload.reply_email,
            contact_consent: params.payload.contact_consent,
            app_version: params.payload.app_version,
            platform: params.payload.platform,
            locale: params.payload.locale,
            route: params.payload.route,
            user_agent: params.userAgent,
            client_ip: params.clientIp,
            request_id: params.requestId,
        })
        .select("id")
        .single();

    if (error) {
        throw new Error(error.message ?? "feedback insert failed");
    }

    return { id: String(data?.id) };
}

Deno.serve(
    createFeedbackHandler({
        checkRateLimit: createFeedbackRateLimitChecker(invokeRpc) as (ip: string) => Promise<RateLimitResult>,
        insertFeedback,
    }),
);
