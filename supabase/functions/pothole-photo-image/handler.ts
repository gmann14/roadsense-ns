import { errorResponse, jsonResponse } from "../_shared/http.ts";

const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type PotholePhotoImageRecord = {
    report_id: string;
    status: string;
    storage_object_path: string;
};

export type PotholePhotoImageHandlerDeps = {
    authorize: (headers: Headers) => boolean;
    getPhoto: (reportID: string) => Promise<PotholePhotoImageRecord | null>;
    createSignedReadURL: (path: string, expiresInSeconds: number) => Promise<string>;
};

const SIGNED_URL_TTL_SECONDS = 60;

export function createPotholePhotoImageHandler(deps: PotholePhotoImageHandlerDeps) {
    return async function handlePotholePhotoImage(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        if (!deps.authorize(req.headers)) {
            return errorResponse(
                "unauthorized",
                "Internal moderation authorization required.",
                401,
                requestId,
            );
        }

        const reportID = new URL(req.url).searchParams.get("report_id");
        if (!UUID_REGEX.test(String(reportID ?? ""))) {
            return errorResponse(
                "validation_failed",
                "report_id must be a UUID string.",
                400,
                requestId,
            );
        }

        try {
            const photo = await deps.getPhoto(String(reportID));
            if (!photo) {
                return errorResponse(
                    "photo_not_found",
                    "Pothole photo not found.",
                    404,
                    requestId,
                );
            }

            if (photo.status !== "pending_moderation" && photo.status !== "approved") {
                return errorResponse(
                    "invalid_photo_state",
                    "Only moderation-visible photos can be previewed.",
                    409,
                    requestId,
                );
            }

            const signedURL = await deps.createSignedReadURL(photo.storage_object_path, SIGNED_URL_TTL_SECONDS);
            return jsonResponse(
                {
                    report_id: photo.report_id,
                    status: photo.status,
                    signed_url: signedURL,
                    expires_in_s: SIGNED_URL_TTL_SECONDS,
                },
                200,
                {},
                requestId,
            );
        } catch (error) {
            const message = error instanceof Error ? error.message : "unknown_error";
            if (message === "photo_not_found") {
                return errorResponse(
                    "photo_not_found",
                    "Pothole photo not found.",
                    404,
                    requestId,
                );
            }

            console.error("pothole-photo-image failed", {
                request_id: requestId,
                report_id: reportID,
                error,
            });

            return errorResponse(
                "processing_failed",
                "Could not create signed photo preview URL.",
                502,
                requestId,
            );
        }
    };
}
