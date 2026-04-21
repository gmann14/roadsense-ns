import { errorResponse, jsonResponse } from "../_shared/http.ts";

const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const UUID_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ACTION_TYPES = new Set(["manual_report", "confirm_present", "confirm_fixed"]);

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
};

export type PotholeActionResult = {
    action_id: string;
    pothole_report_id: string;
    status: string;
};

export type ValidationResult =
    | { ok: true; payload: PotholeActionPayload }
    | { ok: false; fieldErrors: Record<string, string> };

export type RateLimitResult = { ok: true; retryAfterSeconds: 0 } | { ok: false; retryAfterSeconds: number };

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

function isIsoTimestamp(value: unknown): value is string {
    return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export function extractClientIp(headers: Headers): string {
    const forwarded = headers.get("x-forwarded-for") ?? "";
    const firstForwarded = forwarded.split(",")[0]?.trim();

    return firstForwarded
        || headers.get("x-real-ip")
        || headers.get("cf-connecting-ip")
        || "unknown";
}

export function validatePotholeActionPayload(payload: unknown): ValidationResult {
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

    if (!isIsoTimestamp(input.client_sent_at)) {
        fieldErrors.client_sent_at = "must be an RFC3339 timestamp";
    }

    if (typeof input.client_app_version !== "string" || input.client_app_version.trim().length === 0) {
        fieldErrors.client_app_version = "must be a non-empty string";
    }

    if (typeof input.client_os_version !== "string" || input.client_os_version.trim().length === 0) {
        fieldErrors.client_os_version = "must be a non-empty string";
    }

    if (!ACTION_TYPES.has(actionType)) {
        fieldErrors.action_type = "must be one of manual_report, confirm_present, confirm_fixed";
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

    if (!isIsoTimestamp(input.recorded_at)) {
        fieldErrors.recorded_at = "must be an RFC3339 timestamp";
    }

    const potholeReportID = input.pothole_report_id;
    if (actionType === "manual_report") {
        if (!(potholeReportID === undefined || potholeReportID === null)) {
            fieldErrors.pothole_report_id = "must be omitted for manual_report";
        }
    } else if (!UUID_REGEX.test(String(potholeReportID ?? ""))) {
        fieldErrors.pothole_report_id = "must be a UUID string";
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
        },
    };
}

export function createPotholeActionsHandler(deps: PotholeActionHandlerDeps) {
    return async function handlePotholeActions(req: Request): Promise<Response> {
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
