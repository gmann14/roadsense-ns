import { errorResponse, jsonResponse, requestIdFrom } from "../_shared/http.ts";
import { readBodyWithLimit } from "../_shared/body.ts";
import { extractClientIp } from "../_shared/clientIp.ts";
import { isRfc3339Timestamp } from "../_shared/validation.ts";
import type { RateLimitResult } from "../_shared/rateLimit.ts";

export { extractClientIp };

const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ACTION_TYPES = new Set(["manual_report", "confirm_present", "confirm_fixed"]);

// Body-size cap (P0-2). A single pothole action is a tiny fixed-shape object;
// 256KB is a generous ceiling that still blocks oversized/junk payloads
// before parsing, mirroring feedback/handler.ts and upload-readings/handler.ts.
export const MAX_PAYLOAD_BYTES = 262_144;

// Freeform client metadata bounds (P0-2), matching upload-readings/handler.ts.
export const MAX_VERSION_STRING_LENGTH = 100;

// World-bounds validation (P1-7), matching upload-readings/handler.ts.
export const LAT_MIN = -90;
export const LAT_MAX = 90;
export const LNG_MIN = -180;
export const LNG_MAX = 180;

// Action-time window (review 2026-10-18 N1). A `confirm_present` with
// recorded_at=2099 used to set last_confirmed_at=2099, making the pothole
// permanent and unresolvable, and back-dated actions slipped past the 24 h
// dedupe. Five minutes of future skew covers client clock drift; 30 days
// covers an action that sat in an offline queue for a long time.
export const RECORDED_AT_MAX_FUTURE_MS = 5 * 60 * 1000;
export const RECORDED_AT_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

// pothole_actions.accuracy_m is NUMERIC(5,2) (max 999.99), so larger values
// used to fail the cast and surface as 502. A manual report from a fix worse
// than 500 m can't be placed on a road anyway.
export const ACCURACY_M_MIN = 0;
export const ACCURACY_M_MAX = 500;

export type PotholeActionPayload = {
    action_id: string;
    device_token: string;
    client_sent_at: string;
    client_app_version: string;
    client_os_version: string;
    action_type: "manual_report" | "confirm_present" | "confirm_fixed";
    pothole_report_id?: string | null;
    lat: number;
    lng: number;
    accuracy_m: number | null;
    recorded_at: string;
    sensor_backed_magnitude_g?: number | null;
    sensor_backed_at?: string | null;
};

export type PotholeActionResult = {
    action_id: string;
    pothole_report_id: string;
    status: string;
};

export type ValidationResult =
    | { ok: true; payload: PotholeActionPayload }
    | { ok: false; fieldErrors: Record<string, string> };

export type { RateLimitResult };

export type PotholeActionHandlerDeps = {
    hashDeviceToken: (deviceToken: string) => Promise<string>;
    checkRateLimit: (tokenHashHex: string, ip: string) => Promise<RateLimitResult>;
    applyAction: (params: {
        payload: PotholeActionPayload;
        tokenHashHex: string;
    }) => Promise<PotholeActionResult>;
};

function isFiniteNumber(value: unknown): value is number {
    return typeof value === "number" && Number.isFinite(value);
}

// Null when the timestamp is inside the accepted window, otherwise the
// field-error message.
function recordedAtWindowError(value: string, now: Date): string | null {
    const at = Date.parse(value);
    if (at > now.getTime() + RECORDED_AT_MAX_FUTURE_MS) {
        return "must not be more than 5 minutes in the future";
    }
    if (at < now.getTime() - RECORDED_AT_MAX_AGE_MS) {
        return "must not be more than 30 days old";
    }
    return null;
}

export function validatePotholeActionPayload(payload: unknown, now: Date = new Date()): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            fieldErrors: { payload: "must be a JSON object" },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};
    const actionType = String(input.action_type ?? "");

    if (!UUID_V4_REGEX.test(String(input.action_id ?? ""))) {
        fieldErrors.action_id = "must be a UUIDv4 string";
    }

    if (!UUID_V4_REGEX.test(String(input.device_token ?? ""))) {
        fieldErrors.device_token = "must be a UUIDv4 string";
    }

    if (!isRfc3339Timestamp(input.client_sent_at)) {
        fieldErrors.client_sent_at = "must be an RFC3339 timestamp";
    }

    if (
        typeof input.client_app_version !== "string" ||
        input.client_app_version.trim().length === 0
    ) {
        fieldErrors.client_app_version = "must be a non-empty string";
    } else if (input.client_app_version.length > MAX_VERSION_STRING_LENGTH) {
        fieldErrors.client_app_version = `must be at most ${MAX_VERSION_STRING_LENGTH} characters`;
    }

    if (
        typeof input.client_os_version !== "string" ||
        input.client_os_version.trim().length === 0
    ) {
        fieldErrors.client_os_version = "must be a non-empty string";
    } else if (input.client_os_version.length > MAX_VERSION_STRING_LENGTH) {
        fieldErrors.client_os_version = `must be at most ${MAX_VERSION_STRING_LENGTH} characters`;
    }

    if (!ACTION_TYPES.has(actionType)) {
        fieldErrors.action_type = "must be one of manual_report, confirm_present, confirm_fixed";
    }

    if (!isFiniteNumber(input.lat)) {
        fieldErrors.lat = "must be numeric";
    } else if (input.lat < LAT_MIN || input.lat > LAT_MAX) {
        fieldErrors.lat = `must be between ${LAT_MIN} and ${LAT_MAX}`;
    }

    if (!isFiniteNumber(input.lng)) {
        fieldErrors.lng = "must be numeric";
    } else if (input.lng < LNG_MIN || input.lng > LNG_MAX) {
        fieldErrors.lng = `must be between ${LNG_MIN} and ${LNG_MAX}`;
    }

    if (!(input.accuracy_m === null || input.accuracy_m === undefined || isFiniteNumber(input.accuracy_m))) {
        fieldErrors.accuracy_m = "must be numeric or null";
    } else if (
        isFiniteNumber(input.accuracy_m) &&
        (input.accuracy_m < ACCURACY_M_MIN || input.accuracy_m > ACCURACY_M_MAX)
    ) {
        fieldErrors.accuracy_m = `must be between ${ACCURACY_M_MIN} and ${ACCURACY_M_MAX}`;
    }

    if (!isRfc3339Timestamp(input.recorded_at)) {
        fieldErrors.recorded_at = "must be an RFC3339 timestamp";
    } else {
        const windowError = recordedAtWindowError(input.recorded_at, now);
        if (windowError) fieldErrors.recorded_at = windowError;
    }

    const sensorBackedMagnitude = input.sensor_backed_magnitude_g;
    const sensorBackedAt = input.sensor_backed_at;
    const hasSensorBackedMagnitude = sensorBackedMagnitude !== undefined && sensorBackedMagnitude !== null;
    const hasSensorBackedAt = sensorBackedAt !== undefined && sensorBackedAt !== null;

    if (hasSensorBackedMagnitude) {
        if (!isFiniteNumber(sensorBackedMagnitude) || sensorBackedMagnitude <= 0 || sensorBackedMagnitude > 8) {
            fieldErrors.sensor_backed_magnitude_g = "must be numeric between 0 and 8";
        }
    }

    if (hasSensorBackedAt) {
        if (!isRfc3339Timestamp(sensorBackedAt)) {
            fieldErrors.sensor_backed_at = "must be an RFC3339 timestamp";
        } else {
            const windowError = recordedAtWindowError(sensorBackedAt, now);
            if (windowError) fieldErrors.sensor_backed_at = windowError;
        }
    }

    if (hasSensorBackedMagnitude !== hasSensorBackedAt) {
        fieldErrors.sensor_backed = "magnitude and timestamp must be provided together";
    }

    const potholeReportID = input.pothole_report_id;
    if (actionType === "manual_report") {
        if (!(potholeReportID === undefined || potholeReportID === null)) {
            fieldErrors.pothole_report_id = "must be omitted for manual_report";
        }
    } else {
        if (!UUID_REGEX.test(String(potholeReportID ?? ""))) {
            fieldErrors.pothole_report_id = "must be a UUID string";
        }

        if (hasSensorBackedMagnitude || hasSensorBackedAt) {
            fieldErrors.sensor_backed = "must be omitted for follow-up actions";
        }
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { ok: false, fieldErrors };
    }

    return {
        ok: true,
        payload: {
            action_id: String(input.action_id),
            device_token: String(input.device_token),
            client_sent_at: String(input.client_sent_at),
            client_app_version: String(input.client_app_version),
            client_os_version: String(input.client_os_version),
            action_type: actionType as PotholeActionPayload["action_type"],
            pothole_report_id: potholeReportID == null ? null : String(potholeReportID),
            lat: Number(input.lat),
            lng: Number(input.lng),
            accuracy_m: input.accuracy_m == null ? null : Number(input.accuracy_m),
            recorded_at: String(input.recorded_at),
            sensor_backed_magnitude_g: hasSensorBackedMagnitude ? Number(sensorBackedMagnitude) : null,
            sensor_backed_at: hasSensorBackedAt ? String(sensorBackedAt) : null,
        },
    };
}

export function createPotholeActionsHandler(deps: PotholeActionHandlerDeps) {
    return async function handlePotholeActions(req: Request): Promise<Response> {
        const requestId = requestIdFrom(req);

        if (req.method !== "POST") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        // Streamed with a byte counter so a chunked body (no Content-Length)
        // or an understated one can't be buffered whole before the cap runs.
        const body = await readBodyWithLimit(req, MAX_PAYLOAD_BYTES);
        if (!body.ok) {
            if (body.reason === "too_large") {
                return errorResponse(
                    "payload_too_large",
                    "Pothole action payload is too large.",
                    413,
                    requestId,
                );
            }
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be readable" } },
            );
        }
        const rawText = body.text;

        let rawPayload: unknown;
        try {
            rawPayload = JSON.parse(rawText);
        } catch {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be valid JSON" } },
            );
        }

        const validation = validatePotholeActionPayload(rawPayload);
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
                    "Device or IP exceeded pothole action rate limit.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            try {
                const result = await deps.applyAction({ payload, tokenHashHex });
                return jsonResponse(result, 200, {}, requestId);
            } catch (error) {
                const message = error instanceof Error ? error.message : "unknown_error";
                if (message === "stale_target") {
                    return errorResponse(
                        "stale_target",
                        "This pothole marker no longer matches your current location.",
                        409,
                        requestId,
                    );
                }

                console.error("pothole-actions failed", {
                    request_id: requestId,
                    action_id: payload.action_id,
                    error,
                });

                return errorResponse(
                    "processing_failed",
                    "Pothole action processing failed.",
                    502,
                    requestId,
                );
            }
        } catch (error) {
            console.error("pothole-actions unavailable", {
                request_id: requestId,
                action_id: payload.action_id,
                error,
            });

            return errorResponse(
                "service_unavailable",
                "Pothole action service unavailable.",
                503,
                requestId,
            );
        }
    };
}
