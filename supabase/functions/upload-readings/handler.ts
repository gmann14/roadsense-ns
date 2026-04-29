import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { extractClientIp } from "../_shared/clientIp.ts";

export { extractClientIp };

const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type UploadReading = {
    lat: number;
    lng: number;
    roughness_rms: number;
    speed_kmh: number;
    heading: number | null;
    gps_accuracy_m: number;
    recorded_at: string;
    is_pothole?: boolean;
    pothole_magnitude?: number | null;
};

export type UploadPayload = {
    batch_id: string;
    device_token: string;
    client_sent_at: string;
    client_app_version: string;
    client_os_version: string;
    readings: UploadReading[];
};

export type ValidationResult =
    | { ok: true; payload: UploadPayload }
    | { ok: false; error: "validation_failed" | "batch_too_large"; fieldErrors?: Record<string, string> };

export type RateLimitResult = { ok: true; retryAfterSeconds: 0 } | { ok: false; retryAfterSeconds: number };

export type UploadResult = {
    accepted: number;
    rejected: number;
    duplicate: boolean;
    rejected_reasons: Record<string, number>;
};

export type UploadHandlerDeps = {
    hashDeviceToken: (deviceToken: string) => Promise<string>;
    checkRateLimit: (tokenHashHex: string, ip: string) => Promise<RateLimitResult>;
    ingestBatch: (params: {
        payload: UploadPayload;
        tokenHashHex: string;
    }) => Promise<UploadResult>;
};

function isFiniteNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value);
}

function isIsoTimestamp(value: unknown): value is string {
    return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export function validateUploadPayload(payload: unknown): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            error: "validation_failed",
            fieldErrors: {
                payload: "must be a JSON object",
            },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};

    if (!UUID_V4_REGEX.test(String(input.batch_id ?? ""))) {
        fieldErrors.batch_id = "must be a UUIDv4 string";
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

    if (!Array.isArray(input.readings)) {
        fieldErrors.readings = "must be an array";
    } else {
        if (input.readings.length > 1000) {
            return { ok: false, error: "batch_too_large" };
        }

        input.readings.forEach((reading, index) => {
            if (typeof reading !== "object" || reading === null || Array.isArray(reading)) {
                fieldErrors[`readings[${index}]`] = "must be an object";
                return;
            }

            const row = reading as Record<string, unknown>;

            if (!isFiniteNumber(row.lat)) {
                fieldErrors[`readings[${index}].lat`] = "must be numeric";
            }
            if (!isFiniteNumber(row.lng)) {
                fieldErrors[`readings[${index}].lng`] = "must be numeric";
            }
            if (!isFiniteNumber(row.roughness_rms)) {
                fieldErrors[`readings[${index}].roughness_rms`] = "must be numeric";
            }
            if (!isFiniteNumber(row.speed_kmh)) {
                fieldErrors[`readings[${index}].speed_kmh`] = "must be numeric";
            }
            if (!(row.heading === null || isFiniteNumber(row.heading))) {
                fieldErrors[`readings[${index}].heading`] = "must be numeric or null";
            }
            if (!isFiniteNumber(row.gps_accuracy_m)) {
                fieldErrors[`readings[${index}].gps_accuracy_m`] = "must be numeric";
            }
            if (!isIsoTimestamp(row.recorded_at)) {
                fieldErrors[`readings[${index}].recorded_at`] = "must be an RFC3339 timestamp";
            }
            if (!(row.is_pothole === undefined || typeof row.is_pothole === "boolean")) {
                fieldErrors[`readings[${index}].is_pothole`] = "must be boolean when present";
            }
            if (!(row.pothole_magnitude === undefined || row.pothole_magnitude === null || isFiniteNumber(row.pothole_magnitude))) {
                fieldErrors[`readings[${index}].pothole_magnitude`] = "must be numeric or null";
            }
        });
    }

    if (Object.keys(fieldErrors).length > 0) {
        return {
            ok: false,
            error: "validation_failed",
            fieldErrors,
        };
    }

    return {
        ok: true,
        payload: input as unknown as UploadPayload,
    };
}

export function createUploadReadingsHandler(deps: UploadHandlerDeps) {
    return async function handleUploadReadings(req: Request): Promise<Response> {
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

        const validation = validateUploadPayload(rawPayload);
        if (!validation.ok) {
            if (validation.error === "batch_too_large") {
                return errorResponse(
                    "batch_too_large",
                    "readings exceeded 1000 items.",
                    400,
                    requestId,
                );
            }

            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: validation.fieldErrors ?? {} },
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
                    "Device or IP exceeded rate limit.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            try {
                const result = await deps.ingestBatch({
                    payload,
                    tokenHashHex,
                });

                return jsonResponse(
                    {
                        batch_id: payload.batch_id,
                        accepted: result.accepted,
                        rejected: result.rejected,
                        duplicate: result.duplicate,
                        rejected_reasons: result.rejected_reasons ?? {},
                    },
                    200,
                    {},
                    requestId,
                );
            } catch (error) {
                console.error("upload-readings failed", {
                    request_id: requestId,
                    batch_id: payload.batch_id,
                    token_hash_prefix: tokenHashHex.slice(0, 4),
                    error,
                });

                return errorResponse(
                    "processing_failed",
                    "Upload processing failed.",
                    502,
                    requestId,
                );
            }
        } catch (error) {
            console.error("upload-readings unavailable", {
                request_id: requestId,
                batch_id: payload.batch_id,
                error,
            });

            return errorResponse(
                "service_unavailable",
                "Upload service is unavailable.",
                503,
                requestId,
            );
        }
    };
}
