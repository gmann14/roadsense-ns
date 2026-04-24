import { errorResponse, jsonResponse } from "../_shared/http.ts";

const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type Decision = "approve" | "reject";

export type PotholePhotoModerationPayload = {
    report_id: string;
    decision: Decision;
    reviewed_by: string;
    rejection_reason?: string | null;
};

export type PotholePhotoRecord = {
    report_id: string;
    status: string;
    storage_object_path: string;
};

export type PotholePhotoModerationResult = {
    report_id: string;
    pothole_report_id?: string | null;
    status: string;
    storage_object_path: string;
};

export type ValidationResult =
    | { ok: true; payload: PotholePhotoModerationPayload }
    | { ok: false; fieldErrors: Record<string, string> };

export type PotholePhotoModerationHandlerDeps = {
    authorize: (headers: Headers) => boolean;
    getPhoto: (reportID: string) => Promise<PotholePhotoRecord | null>;
    moveObject: (fromPath: string, toPath: string) => Promise<void>;
    deleteObject: (path: string) => Promise<void>;
    approvePhoto: (params: {
        reportID: string;
        reviewedBy: string;
        storageObjectPath: string;
    }) => Promise<PotholePhotoModerationResult>;
    rejectPhoto: (params: {
        reportID: string;
        reviewedBy: string;
        rejectionReason?: string | null;
    }) => Promise<PotholePhotoModerationResult>;
};

export function validatePotholePhotoModerationPayload(payload: unknown): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            fieldErrors: { payload: "must be a JSON object" },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};

    if (!UUID_REGEX.test(String(input.report_id ?? ""))) {
        fieldErrors.report_id = "must be a UUID string";
    }

    if (input.decision !== "approve" && input.decision !== "reject") {
        fieldErrors.decision = "must be approve or reject";
    }

    if (typeof input.reviewed_by !== "string" || input.reviewed_by.trim().length === 0) {
        fieldErrors.reviewed_by = "must be a non-empty string";
    }

    if (!(input.rejection_reason === undefined || input.rejection_reason === null || typeof input.rejection_reason === "string")) {
        fieldErrors.rejection_reason = "must be a string or null";
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { ok: false, fieldErrors };
    }

    return {
        ok: true,
        payload: {
            report_id: String(input.report_id),
            decision: input.decision as Decision,
            reviewed_by: String(input.reviewed_by).trim(),
            rejection_reason: input.rejection_reason == null ? null : String(input.rejection_reason),
        },
    };
}

export function createPotholePhotoModerationHandler(deps: PotholePhotoModerationHandlerDeps) {
    return async function handlePotholePhotoModeration(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "POST") {
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

        let rawPayload: unknown;
        try {
            rawPayload = await req.json();
        } catch {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be valid JSON" } },
            );
        }

        const validation = validatePotholePhotoModerationPayload(rawPayload);
        if (!validation.ok) {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: validation.fieldErrors },
            );
        }

        const payload = validation.payload;

        try {
            const photo = await deps.getPhoto(payload.report_id);
            if (!photo) {
                return errorResponse(
                    "photo_not_found",
                    "Pothole photo not found.",
                    404,
                    requestId,
                );
            }

            if (payload.decision === "approve") {
                if (photo.status !== "pending_moderation" && photo.status !== "approved") {
                    return errorResponse(
                        "invalid_photo_state",
                        "Only pending moderation photos can be approved.",
                        409,
                        requestId,
                    );
                }

                const targetPath = photo.storage_object_path.startsWith("published/")
                    ? photo.storage_object_path
                    : `published/${payload.report_id}.jpg`;
                const shouldMoveObject = photo.status === "pending_moderation"
                    && photo.storage_object_path !== targetPath;

                if (shouldMoveObject) {
                    await deps.moveObject(photo.storage_object_path, targetPath);
                }

                try {
                    const result = await deps.approvePhoto({
                        reportID: payload.report_id,
                        reviewedBy: payload.reviewed_by,
                        storageObjectPath: targetPath,
                    });
                    return jsonResponse(result, 200, {}, requestId);
                } catch (error) {
                    if (shouldMoveObject) {
                        try {
                            await deps.moveObject(targetPath, photo.storage_object_path);
                        } catch (rollbackError) {
                            console.error("pothole-photo-moderation rollback failed", {
                                request_id: requestId,
                                report_id: payload.report_id,
                                rollbackError,
                            });
                        }
                    }

                    throw error;
                }
            }

            if (photo.status !== "pending_moderation" && photo.status !== "rejected") {
                return errorResponse(
                    "invalid_photo_state",
                    "Only pending moderation photos can be rejected.",
                    409,
                    requestId,
                );
            }

            const result = await deps.rejectPhoto({
                reportID: payload.report_id,
                reviewedBy: payload.reviewed_by,
                rejectionReason: payload.rejection_reason,
            });

            await deps.deleteObject(photo.storage_object_path);
            return jsonResponse(result, 200, {}, requestId);
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

            if (message === "invalid_photo_state") {
                return errorResponse(
                    "invalid_photo_state",
                    "Photo moderation state is not valid for this action.",
                    409,
                    requestId,
                );
            }

            console.error("pothole-photo-moderation failed", {
                request_id: requestId,
                report_id: payload.report_id,
                error,
            });

            return errorResponse(
                "processing_failed",
                "Photo moderation failed.",
                502,
                requestId,
            );
        }
    };
}
