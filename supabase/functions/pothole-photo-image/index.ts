import { createClient } from "npm:@supabase/supabase-js@2";
import { createPotholePhotoImageHandler, type PotholePhotoImageRecord } from "./handler.ts";
import { isAuthorizedInternalRequest } from "../_shared/internalAuth.ts";
import { requireEnv } from "../upload-readings/runtime.ts";

const BUCKET = "pothole-photos";

const supabaseURL = requireEnv("SUPABASE_URL");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const supabase = createClient(supabaseURL, serviceRoleKey);

async function getPhoto(reportID: string): Promise<PotholePhotoImageRecord | null> {
    const { data, error } = await supabase
        .from("pothole_photos")
        .select("report_id, status, storage_object_path")
        .eq("report_id", reportID)
        .maybeSingle();

    if (error) {
        throw new Error(error.message);
    }

    return data as PotholePhotoImageRecord | null;
}

async function createSignedReadURL(path: string, expiresInSeconds: number): Promise<string> {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, expiresInSeconds);
    if (error || !data?.signedUrl) {
        throw new Error(error?.message ?? "signed_url_failed");
    }

    return data.signedUrl;
}

Deno.serve(
    createPotholePhotoImageHandler({
        authorize: (headers) => isAuthorizedInternalRequest(headers, serviceRoleKey),
        getPhoto,
        createSignedReadURL,
    }),
);
