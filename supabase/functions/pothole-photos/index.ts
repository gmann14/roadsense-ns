import { createClient } from "npm:@supabase/supabase-js@2";
import { createPotholePhotosHandler, type PotholePhotoPayload, type PotholePhotoResult, type RateLimitResult } from "./handler.ts";
import { createPotholePhotoRateLimitChecker } from "./runtime.ts";
import { hashDeviceToken, requireEnv, type RpcResponse } from "../upload-readings/runtime.ts";

const BUCKET = "pothole-photos";
const SIGNED_UPLOAD_TTL_SECONDS = 2 * 60 * 60;

type ExistingPotholePhoto = {
    report_id: string;
    status: string;
    storage_object_path: string;
    content_sha256: string;
    byte_size: number;
    content_type: string;
};

function normalizeStoredHash(value: string): string {
    return value.startsWith("\\x") ? value.slice(2) : value;
}

function objectPathFor(reportID: string): string {
    return `pending/${reportID}.jpg`;
}

function signedUploadUrlFor(
    supabaseURL: string,
    bucket: string,
    objectPath: string,
    signedUrl?: string | null,
    token?: string | null,
): string {
    if (signedUrl) {
        return signedUrl;
    }

    const encodedPath = objectPath.split("/").map(encodeURIComponent).join("/");
    return `${supabaseURL}/storage/v1/object/upload/sign/${bucket}/${encodedPath}?token=${token ?? ""}`;
}

function createPrepareUpload(
    supabase: ReturnType<typeof createClient>,
    supabaseURL: string,
) {
    return async ({ payload, tokenHashHex }: { payload: PotholePhotoPayload; tokenHashHex: string }): Promise<PotholePhotoResult> => {
        const objectPath = objectPathFor(payload.report_id);

        const { data: existing, error: existingError } = await supabase
            .from("pothole_photos")
            .select("report_id, status, storage_object_path, content_sha256, byte_size, content_type")
            .eq("report_id", payload.report_id)
            .maybeSingle();

        if (existingError) {
            throw new Error(existingError.message);
        }

        const existingPhoto = existing as ExistingPotholePhoto | null;

        if (existingPhoto) {
            if (normalizeStoredHash(existingPhoto.content_sha256) !== payload.sha256
                || existingPhoto.byte_size !== payload.byte_size
                || existingPhoto.content_type !== payload.content_type) {
                throw new Error("content_sha_mismatch");
            }

            if (existingPhoto.status !== "pending_upload") {
                return { kind: "already_uploaded" };
            }
        } else {
            const { error: insertError } = await supabase
                .from("pothole_photos")
                .insert({
                    report_id: payload.report_id,
                    device_token_hash: `\\x${tokenHashHex}`,
                    geom: {
                        type: "Point",
                        coordinates: [payload.lng, payload.lat],
                    },
                    accuracy_m: payload.accuracy_m,
                    captured_at: payload.captured_at,
                    status: "pending_upload",
                    storage_object_path: objectPath,
                    content_sha256: `\\x${payload.sha256}`,
                    byte_size: payload.byte_size,
                    content_type: payload.content_type,
                });

            if (insertError) {
                throw new Error(insertError.message);
            }
        }

        const { data, error } = await supabase
            .storage
            .from(BUCKET)
            .createSignedUploadUrl(objectPath, { upsert: true });

        if (error || !data) {
            throw new Error(error?.message ?? "createSignedUploadUrl returned no data");
        }

        const uploadURL = signedUploadUrlFor(
            supabaseURL,
            BUCKET,
            objectPath,
            "signedUrl" in data ? data.signedUrl : null,
            "token" in data ? data.token : null,
        );

        return {
            kind: "ready",
            report_id: payload.report_id,
            upload_url: uploadURL,
            upload_expires_at: new Date(Date.now() + SIGNED_UPLOAD_TTL_SECONDS * 1000).toISOString(),
            expected_object_path: objectPath,
        };
    };
}

const supabaseURL = requireEnv("SUPABASE_URL");
const supabase = createClient(
    supabaseURL,
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
);

async function invokeRpc<T>(fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> {
    const { data, error } = await supabase.rpc(fn, params);
    return { data, error };
}

Deno.serve(
    createPotholePhotosHandler({
        hashDeviceToken,
        checkRateLimit: createPotholePhotoRateLimitChecker(invokeRpc) as (tokenHashHex: string, ip: string) => Promise<RateLimitResult>,
        prepareUpload: createPrepareUpload(supabase, supabaseURL),
    }),
);
