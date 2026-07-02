import { errorResponse, jsonResponse } from "../_shared/http.ts";
import { extractClientIp } from "../_shared/clientIp.ts";

export { extractClientIp };

const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Body-size cap (P0-2). Mirrors feedback/handler.ts's MAX_PAYLOAD_BYTES pattern.
// 256KB comfortably covers a full 1000-reading batch of legitimate JSON
// (~250 bytes/reading) while blocking oversized/junk payloads before they're
// even parsed.
export const MAX_PAYLOAD_BYTES = 262_144;

// Freeform client metadata bounds (P0-2). These are short human-readable
// version strings (e.g. "0.1.3 (42)", "iOS 17.4.1"); 100 chars is generous
// headroom without letting a client attach an unbounded string.
export const MAX_VERSION_STRING_LENGTH = 100;

// Anti-forgery bounds (P0-1). Sourced from the rest of the pipeline rather than invented:
//
// - SPEED: physically implausible speeds are rejected outright. The SQL ingest path
//   (ingest_reading_batch) already soft-rejects anything outside 15-160 km/h as
//   `low_quality`; the gateway bound is deliberately looser (0-220) so the DB stays the
//   quality gate while obviously forged values never reach hashing/rate-limit/DB work.
// - MAGNITUDE: the manual report path clamps sensor-backed magnitude to (0, 8] G
//   (`apply_pothole_action`, migration 20260425221500). The on-device PotholeDetector
//   documents moderate strikes at ~0.8-1.6 G and deep ones 2 G+
//   (ios/Sources/RoadSenseNSBootstrap/Pipeline/PotholeDetector.swift); 8 G is far beyond
//   any real suspension event, so the bulk-ingest path now uses the same 0-8 ceiling.
// - FLAG CONSISTENCY: an honest client only sets is_pothole=true when the detector saw a
//   spike above its 1.0 G threshold (PotholeDetector.spikeThresholdG), and it always
//   attaches that spike's magnitude. A flagged reading without a magnitude of at least
//   1.0 G cannot come from the shipped detector and is rejected.
export const SPEED_KMH_MIN = 0;
export const SPEED_KMH_MAX = 220;
export const POTHOLE_MAGNITUDE_MIN_G = 0;
export const POTHOLE_MAGNITUDE_MAX_G = 8;
export const POTHOLE_FLAG_MIN_MAGNITUDE_G = 1.0;

// World-bounds validation (P1-7). Coordinates outside these ranges are not
// physically valid lat/lng values regardless of anything else in the batch.
export const LAT_MIN = -90;
export const LAT_MAX = 90;
export const LNG_MIN = -180;
export const LNG_MAX = 180;

// Per-batch pothole-flag sanity cap (P0-1). Each reading window covers >= 40 m of travel
// (ReadingBuilder.targetDistanceMeters) and is only flagged when the detector saw a
// dip-then-spike above 1.0 G inside that window. Even on the roughest scored NS roads
// that fires in a small minority of windows; a batch where more than a quarter of all
// readings are pothole-flagged would mean a sustained >= 1 G strike every ~160 m for the
// entire drive, which is forged data, not a road. The flat allowance keeps small honest
// batches (e.g. 4 readings with 2 hits on one bad street) clear of the cap.
export const MAX_POTHOLE_READING_FRACTION = 0.25;
export const MIN_POTHOLE_READING_ALLOWANCE = 5;

export function maxPotholeReadingsForBatch(readingCount: number): number {
    return Math.max(
        MIN_POTHOLE_READING_ALLOWANCE,
        Math.ceil(readingCount * MAX_POTHOLE_READING_FRACTION),
    );
}

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

    if (!Array.isArray(input.readings)) {
        fieldErrors.readings = "must be an array";
    } else {
        if (input.readings.length > 1000) {
            return { ok: false, error: "batch_too_large" };
        }

        let potholeFlaggedCount = 0;

        input.readings.forEach((reading, index) => {
            if (typeof reading !== "object" || reading === null || Array.isArray(reading)) {
                fieldErrors[`readings[${index}]`] = "must be an object";
                return;
            }

            const row = reading as Record<string, unknown>;

            if (!isFiniteNumber(row.lat)) {
                fieldErrors[`readings[${index}].lat`] = "must be numeric";
            } else if (row.lat < LAT_MIN || row.lat > LAT_MAX) {
                fieldErrors[`readings[${index}].lat`] = `must be between ${LAT_MIN} and ${LAT_MAX}`;
            }
            if (!isFiniteNumber(row.lng)) {
                fieldErrors[`readings[${index}].lng`] = "must be numeric";
            } else if (row.lng < LNG_MIN || row.lng > LNG_MAX) {
                fieldErrors[`readings[${index}].lng`] = `must be between ${LNG_MIN} and ${LNG_MAX}`;
            }
            if (!isFiniteNumber(row.roughness_rms)) {
                fieldErrors[`readings[${index}].roughness_rms`] = "must be numeric";
            }
            if (!isFiniteNumber(row.speed_kmh)) {
                fieldErrors[`readings[${index}].speed_kmh`] = "must be numeric";
            } else if (row.speed_kmh < SPEED_KMH_MIN || row.speed_kmh > SPEED_KMH_MAX) {
                fieldErrors[`readings[${index}].speed_kmh`] =
                    `must be between ${SPEED_KMH_MIN} and ${SPEED_KMH_MAX}`;
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

            if (row.is_pothole === true) {
                potholeFlaggedCount += 1;
            }

            const magnitude = row.pothole_magnitude;
            if (!(magnitude === undefined || magnitude === null || isFiniteNumber(magnitude))) {
                fieldErrors[`readings[${index}].pothole_magnitude`] = "must be numeric or null";
            } else if (
                isFiniteNumber(magnitude) &&
                (magnitude < POTHOLE_MAGNITUDE_MIN_G || magnitude > POTHOLE_MAGNITUDE_MAX_G)
            ) {
                fieldErrors[`readings[${index}].pothole_magnitude`] =
                    `must be between ${POTHOLE_MAGNITUDE_MIN_G} and ${POTHOLE_MAGNITUDE_MAX_G}`;
            } else if (row.is_pothole === true) {
                if (!isFiniteNumber(magnitude)) {
                    fieldErrors[`readings[${index}].pothole_magnitude`] =
                        "must be numeric when is_pothole is true";
                } else if (magnitude < POTHOLE_FLAG_MIN_MAGNITUDE_G) {
                    fieldErrors[`readings[${index}].pothole_magnitude`] =
                        `must be at least ${POTHOLE_FLAG_MIN_MAGNITUDE_G} when is_pothole is true`;
                }
            }
        });

        const maxPotholeReadings = maxPotholeReadingsForBatch(input.readings.length);
        if (potholeFlaggedCount > maxPotholeReadings) {
            fieldErrors.readings =
                `too many pothole-flagged readings (${potholeFlaggedCount} of ${input.readings.length}; max ${maxPotholeReadings})`;
        }
    }

    if (Object.keys(fieldErrors).length > 0) {
        return {
            ok: false,
            error: "validation_failed",
            fieldErrors,
        };
    }

    // Rebuild from an explicit whitelist of known fields (P0-2) rather than
    // passing the input object through verbatim. Without this, arbitrary
    // extra fields on the top-level payload or on each reading survive
    // validation and get serialized straight into jsonb by pgRuntime.ts.
    const readings = input.readings as Array<Record<string, unknown>>;
    const sanitizedReadings: UploadReading[] = readings.map((row) => ({
        lat: Number(row.lat),
        lng: Number(row.lng),
        roughness_rms: Number(row.roughness_rms),
        speed_kmh: Number(row.speed_kmh),
        heading: row.heading === null || row.heading === undefined ? null : Number(row.heading),
        gps_accuracy_m: Number(row.gps_accuracy_m),
        recorded_at: String(row.recorded_at),
        is_pothole: row.is_pothole === true,
        pothole_magnitude:
            row.pothole_magnitude === null || row.pothole_magnitude === undefined
                ? null
                : Number(row.pothole_magnitude),
    }));

    return {
        ok: true,
        payload: {
            batch_id: String(input.batch_id),
            device_token: String(input.device_token),
            client_sent_at: String(input.client_sent_at),
            client_app_version: String(input.client_app_version),
            client_os_version: String(input.client_os_version),
            readings: sanitizedReadings,
        },
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

        const contentLengthHeader = req.headers.get("content-length");
        if (contentLengthHeader) {
            const declaredLength = Number(contentLengthHeader);
            if (Number.isFinite(declaredLength) && declaredLength > MAX_PAYLOAD_BYTES) {
                return errorResponse(
                    "payload_too_large",
                    "Upload payload is too large.",
                    413,
                    requestId,
                );
            }
        }

        let rawText: string;
        try {
            rawText = await req.text();
        } catch {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be readable" } },
            );
        }

        if (rawText.length > MAX_PAYLOAD_BYTES) {
            return errorResponse(
                "payload_too_large",
                "Upload payload is too large.",
                413,
                requestId,
            );
        }

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
