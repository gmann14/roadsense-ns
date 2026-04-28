import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { extractClientIp } from "../_shared/clientIp.ts";

const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_REGEX = /^[0-9a-f]{64}$/i;

export type PotholePhotoPayload = {
    report_id: string;
    segment_id?: string | null;
    device_token: string;
    client_sent_at: string;
    client_app_version: string;
    client_os_version: string;
    lat: number;
    lng: number;
    accuracy_m: number | null;
    captured_at: string;
    content_type: "image/jpeg";
    byte_size: number;
    sha256: string;
};

export type PotholePhotoResult =
    | {
        kind: "ready";
        report_id: string;
        upload_url: string;
        upload_expires_at: string;
        expected_object_path: string;
    }
    | { kind: "already_uploaded" };

export type ValidationResult =
    | { ok: true; payload: PotholePhotoPayload }
    | { ok: false; fieldErrors: Record<string, string> };

export type RateLimitResult = { ok: true; retryAfterSeconds: 0 } | { ok: false; retryAfterSeconds: number };

export type PotholePhotoHandlerDeps = {
    hashDeviceToken: (deviceToken: string) => Promise<string>;
    checkRateLimit: (tokenHashHex: string, ip: string) => Promise<RateLimitResult>;
    prepareUpload: (params: {
        payload: PotholePhotoPayload;
        tokenHashHex: string;
    }) => Promise<PotholePhotoResult>;
};

function isFiniteNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value);
}

function isIsoTimestamp(value: unknown): value is string {
    return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export function validatePotholePhotoPayload(payload: unknown): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            fieldErrors: { payload: "must be a JSON object" },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};

    if (!UUID_V4_REGEX.test(String(input.report_id ?? ""))) {
        fieldErrors.report_id = "must be a UUIDv4 string";
    }

    if (!(input.segment_id === undefined || input.segment_id === null || UUID_V4_REGEX.test(String(input.segment_id)))) {
        fieldErrors.segment_id = "must be a UUIDv4 string or null";
    }

    if (!UUID_V4_REGEX.test(String(input.device_token ?? ""))) {
        fieldErrors.device_token = "must be a UUIDv4 string";
    }

    if (!isIsoTimestamp(input.client_sent_at)) {
        fieldErrors.client_sent_at = "must be an RFC3339 timestamp";
    }

    if (typeof input.client_app_version !== "string" || input.client_app_version.trim().length === 0) {
        fieldErrors.client_app_version = "must be a non-empty string";
    }

    if (typeof input.client_os_version !== "string" || input.client_os_version.trim().length === 0) {
        fieldErrors.client_os_version = "must be a non-empty string";
    }

    if (!isFiniteNumber(input.lat)) {
        fieldErrors.lat = "must be numeric";
    }

    if (!isFiniteNumber(input.lng)) {
        fieldErrors.lng = "must be numeric";
    }

    if (!(input.accuracy_m === null || input.accuracy_m === undefined || isFiniteNumber(input.accuracy_m))) {
        fieldErrors.accuracy_m = "must be numeric or null";
    }

    if (!isIsoTimestamp(input.captured_at)) {
        fieldErrors.captured_at = "must be an RFC3339 timestamp";
    }

    if (input.content_type !== "image/jpeg") {
        fieldErrors.content_type = "must be image/jpeg";
    }

    if (!Number.isInteger(input.byte_size) || Number(input.byte_size) <= 0 || Number(input.byte_size) > 1_500_000) {
        fieldErrors.byte_size = "must be an integer between 1 and 1500000";
    }

    if (!SHA256_REGEX.test(String(input.sha256 ?? ""))) {
        fieldErrors.sha256 = "must be a lowercase SHA-256 hex string";
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { ok: false, fieldErrors };
    }

    return {
        ok: true,
        payload: {
            report_id: String(input.report_id),
            segment_id: input.segment_id == null ? null : String(input.segment_id),
            device_token: String(input.device_token),
            client_sent_at: String(input.client_sent_at),
            client_app_version: String(input.client_app_version),
            client_os_version: String(input.client_os_version),
            lat: Number(input.lat),
            lng: Number(input.lng),
            accuracy_m: input.accuracy_m == null ? null : Number(input.accuracy_m),
            captured_at: String(input.captured_at),
            content_type: "image/jpeg",
            byte_size: Number(input.byte_size),
            sha256: String(input.sha256),
        },
    };
}

export function createPotholePhotosHandler(deps: PotholePhotoHandlerDeps) {
    return async function handlePotholePhotos(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "POST") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
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

        const validation = validatePotholePhotoPayload(rawPayload);
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
            const tokenHashHex = await deps.hashDeviceToken(payload.device_token);
            const ip = extractClientIp(req.headers);
            const rateLimit = await deps.checkRateLimit(tokenHashHex, ip);

            if (!rateLimit.ok) {
                return errorResponse(
                    "rate_limited",
                    "Device or IP exceeded pothole photo rate limit.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            try {
                const result = await deps.prepareUpload({ payload, tokenHashHex });
                if (result.kind === "already_uploaded") {
                    return errorResponse(
                        "already_uploaded",
                        "This report_id has already been submitted.",
                        409,
                        requestId,
                    );
                }

                return jsonResponse(
                    {
                        report_id: result.report_id,
                        upload_url: result.upload_url,
                        upload_expires_at: result.upload_expires_at,
                        expected_object_path: result.expected_object_path,
                    },
                    200,
                    {},
                    requestId,
                );
            } catch (error) {
                const message = error instanceof Error ? error.message : "unknown_error";
                if (message === "content_sha_mismatch") {
                    return errorResponse(
                        "content_sha_mismatch",
                        "This report_id was retried with different image bytes.",
                        400,
                        requestId,
                    );
                }

                console.error("pothole-photos failed", {
                    request_id: requestId,
                    report_id: payload.report_id,
                    error,
                });

                return errorResponse(
                    "processing_failed",
                    "Pothole photo processing failed.",
                    502,
                    requestId,
                );
            }
        } catch (error) {
            console.error("pothole-photos unavailable", {
                request_id: requestId,
                report_id: payload.report_id,
                error,
            });

            return errorResponse(
                "service_unavailable",
                "Pothole photo service unavailable.",
                503,
                requestId,
            );
        }
    };
}
