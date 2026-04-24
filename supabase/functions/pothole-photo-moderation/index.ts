import { createClient } from "npm:@supabase/supabase-js@2";
import { createPotholePhotoModerationHandler, type PotholePhotoModerationResult, type PotholePhotoRecord } from "./handler.ts";
import { isAuthorizedInternalRequest } from "../_shared/internalAuth.ts";
import { requireEnv } from "../upload-readings/runtime.ts";

const BUCKET = "pothole-photos";

type RpcPhotoModerationResult = {
    report_id: string;
    pothole_report_id?: string | null;
    status: string;
    storage_object_path: string;
};

const supabaseURL = requireEnv("SUPABASE_URL");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const supabase = createClient(supabaseURL, serviceRoleKey);

async function getPhoto(reportID: string): Promise<PotholePhotoRecord | null> {
    const { data, error } = await supabase
        .from("pothole_photos")
        .select("report_id, status, storage_object_path")
        .eq("report_id", reportID)
        .maybeSingle();

    if (error) {
        throw new Error(error.message);
    }

    return data as PotholePhotoRecord | null;
}

async function moveObject(fromPath: string, toPath: string): Promise<void> {
    const { error } = await supabase.storage.from(BUCKET).move(fromPath, toPath);
    if (error) {
        throw new Error(error.message);
    }
}

async function deleteObject(path: string): Promise<void> {
    const { error } = await supabase.storage.from(BUCKET).remove([path]);
    if (error) {
        throw new Error(error.message);
    }
}

async function approvePhoto(
    params: {
        reportID: string;
        reviewedBy: string;
        storageObjectPath: string;
    },
): Promise<PotholePhotoModerationResult> {
    const { data, error } = await supabase.rpc("approve_pothole_photo", {
        p_report_id: params.reportID,
        p_reviewed_by: params.reviewedBy,
        p_storage_object_path: params.storageObjectPath,
    });

    if (error) {
        throw new Error(error.message);
    }

    return data as RpcPhotoModerationResult;
}

async function rejectPhoto(
    params: {
        reportID: string;
        reviewedBy: string;
        rejectionReason?: string | null;
    },
): Promise<PotholePhotoModerationResult> {
    const { data, error } = await supabase.rpc("reject_pothole_photo", {
        p_report_id: params.reportID,
        p_reviewed_by: params.reviewedBy,
        p_rejection_reason: params.rejectionReason ?? null,
    });

    if (error) {
        throw new Error(error.message);
    }

    return data as RpcPhotoModerationResult;
}

Deno.serve(
    createPotholePhotoModerationHandler({
        authorize: (headers) => isAuthorizedInternalRequest(headers, serviceRoleKey),
        getPhoto,
        moveObject,
        deleteObject,
        approvePhoto,
        rejectPhoto,
    }),
);
