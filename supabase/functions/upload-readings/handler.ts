import { errorResponse, jsonResponse, requestIdFrom } from "../_shared/http.ts";
import { readBodyWithLimit } from "../_shared/body.ts";
import { extractClientIp } from "../_shared/clientIp.ts";
import { isRfc3339Timestamp } from "../_shared/validation.ts";
import type { RateLimitResult } from "../_shared/rateLimit.ts";

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

// Anti-forgery / sanity bounds (P0-1). Sourced from the rest of the pipeline rather
// than invented. A reading outside one of these bounds is rejected on its own
// (counted in `rejected_reasons`), not by failing the whole batch: one bad
// value used to 400 a 1000-reading batch that the client then marked
// permanently failed (review 2026-10-18 theme 3 / N8).
//
// - SPEED: physically implausible speeds (outside 0-220 km/h) -> `invalid_speed`.
//   The SQL ingest path (ingest_reading_batch) separately soft-rejects anything
//   outside 15-160 km/h as `low_quality`; the gateway bound is looser so the DB
//   stays the quality gate.
// - MAGNITUDE: the manual report path clamps sensor-backed magnitude to (0, 8] G
//   (`apply_pothole_action`, migration 20260425221500). The on-device PotholeDetector
//   documents moderate strikes at ~0.8-1.6 G and deep ones 2 G+
//   (ios/Sources/RoadSenseNSBootstrap/Pipeline/PotholeDetector.swift); 8 G is far beyond
//   any real suspension event (a phone falling off its mount, for example), so a
//   magnitude outside 0-8 -> `invalid_pothole_magnitude`.
// - FLAG CONSISTENCY: an honest client only sets is_pothole=true when the detector saw a
//   spike above its 1.0 G threshold (PotholeDetector.spikeThresholdG), and it always
//   attaches that spike's magnitude. A flagged reading without a magnitude of at least
//   1.0 G cannot come from the shipped detector -> `invalid_pothole_magnitude`.
// - GPS ACCURACY: iOS reports -1 for an invalid fix, and values past 1000 m are not a
//   fix at all (and overflow readings.gps_accuracy_m NUMERIC(5,1) territory). Outside
//   0-1000 -> `invalid_gps_accuracy`. 20-1000 m still reaches SQL as `low_quality`.
// - HEADING: course is only meaningful in [0, 360). Anything else (iOS sends -1 for an
//   invalid course; 10000 overflowed NUMERIC(5,1) and 500'd the batch) is stored as
//   NULL, which the matcher already handles, rather than rejecting the reading.
export const SPEED_KMH_MIN = 0;
export const SPEED_KMH_MAX = 220;
export const POTHOLE_MAGNITUDE_MIN_G = 0;
export const POTHOLE_MAGNITUDE_MAX_G = 8;
export const POTHOLE_FLAG_MIN_MAGNITUDE_G = 1.0;
export const GPS_ACCURACY_M_MIN = 0;
export const GPS_ACCURACY_M_MAX = 1000;
export const HEADING_MIN_DEGREES = 0;
export const HEADING_MAX_DEGREES_EXCLUSIVE = 360;

// World-bounds validation (P1-7). Coordinates outside these ranges are not
// physically valid lat/lng values; such a reading is rejected as
// `out_of_bounds` (the same code SQL uses for "outside Nova Scotia").
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

/// Reasons the gateway itself rejects an individual reading. They are merged
/// into the SQL ingest's `rejected` / `rejected_reasons` in the response.
export type GatewayRejectionReason =
    | "out_of_bounds"
    | "invalid_speed"
    | "invalid_gps_accuracy"
    | "invalid_pothole_magnitude";

export type ValidationResult =
    | {
        ok: true;
        // Only the readings that passed the per-reading checks; this is what
        // reaches ingest_reading_batch.
        payload: UploadPayload;
        gatewayRejectedReasons: Partial<Record<GatewayRejectionReason, number>>;
    }
    | { ok: false; error: "validation_failed" | "batch_too_large"; fieldErrors?: Record<string, string> };

export type { RateLimitResult };

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

// Value-level checks for a reading whose fields already have the right types.
// Returns the first rejection reason, or null when the reading is usable.
function readingRejectionReason(reading: UploadReading): GatewayRejectionReason | null {
    if (
        reading.lat < LAT_MIN || reading.lat > LAT_MAX ||
        reading.lng < LNG_MIN || reading.lng > LNG_MAX
    ) {
        return "out_of_bounds";
    }

    if (reading.speed_kmh < SPEED_KMH_MIN || reading.speed_kmh > SPEED_KMH_MAX) {
        return "invalid_speed";
    }

    if (reading.gps_accuracy_m < GPS_ACCURACY_M_MIN || reading.gps_accuracy_m > GPS_ACCURACY_M_MAX) {
        return "invalid_gps_accuracy";
    }

    const magnitude = reading.pothole_magnitude ?? null;
    if (magnitude !== null && (magnitude < POTHOLE_MAGNITUDE_MIN_G || magnitude > POTHOLE_MAGNITUDE_MAX_G)) {
        return "invalid_pothole_magnitude";
    }
    if (reading.is_pothole === true && (magnitude === null || magnitude < POTHOLE_FLAG_MIN_MAGNITUDE_G)) {
        return "invalid_pothole_magnitude";
    }

    return null;
}

function normalizedHeading(value: unknown): number | null {
    if (!isFiniteNumber(value)) return null;
    return value >= HEADING_MIN_DEGREES && value < HEADING_MAX_DEGREES_EXCLUSIVE ? value : null;
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
            if (!isRfc3339Timestamp(row.recorded_at)) {
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

    // Rebuild from an explicit whitelist of known fields (P0-2) rather
    // than passing the input object through verbatim. Without this, arbitrary
    // extra fields on the top-level payload or on each reading survive
    // validation and get serialized straight into jsonb by pgRuntime.ts.
    // Readings with out-of-range values are dropped here and counted instead.
    const readings = input.readings as Array<Record<string, unknown>>;
    const gatewayRejectedReasons: Partial<Record<GatewayRejectionReason, number>> = {};
    const sanitizedReadings: UploadReading[] = [];
    for (const row of readings) {
        const reading: UploadReading = {
            lat: Number(row.lat),
            lng: Number(row.lng),
            roughness_rms: Number(row.roughness_rms),
            speed_kmh: Number(row.speed_kmh),
            heading: normalizedHeading(row.heading),
            gps_accuracy_m: Number(row.gps_accuracy_m),
            recorded_at: String(row.recorded_at),
            is_pothole: row.is_pothole === true,
            pothole_magnitude:
                row.pothole_magnitude === null || row.pothole_magnitude === undefined
                    ? null
                    : Number(row.pothole_magnitude),
        };
        const reason = readingRejectionReason(reading);
        if (reason) {
            gatewayRejectedReasons[reason] = (gatewayRejectedReasons[reason] ?? 0) + 1;
            continue;
        }
        sanitizedReadings.push(reading);
    }

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
        gatewayRejectedReasons,
    };
}

/// Folds the gateway's own per-reading rejections into the SQL ingest result
/// so the response still satisfies `accepted + rejected = readings.length`.
/// Deterministic for a given payload, so a duplicate `batch_id` replay (which
/// returns SQL's stored counts) yields the same merged numbers as the first
/// response.
export function mergeGatewayRejections(
    result: UploadResult,
    gatewayRejectedReasons: Partial<Record<GatewayRejectionReason, number>>,
): UploadResult {
    const reasons: Record<string, number> = { ...(result.rejected_reasons ?? {}) };
    let gatewayRejected = 0;
    for (const [reason, count] of Object.entries(gatewayRejectedReasons)) {
        if (!count) continue;
        gatewayRejected += count;
        reasons[reason] = (reasons[reason] ?? 0) + count;
    }
    return {
        accepted: result.accepted,
        rejected: (result.rejected ?? 0) + gatewayRejected,
        duplicate: result.duplicate,
        rejected_reasons: reasons,
    };
}

export function createUploadReadingsHandler(deps: UploadHandlerDeps) {
    return async function handleUploadReadings(req: Request): Promise<Response> {
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
                    "Upload payload is too large.",
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
                const ingested = await deps.ingestBatch({
                    payload,
                    tokenHashHex,
                });
                const result = mergeGatewayRejections(ingested, validation.gatewayRejectedReasons);

                return jsonResponse(
                    {
                        batch_id: payload.batch_id,
                        accepted: result.accepted,
                        rejected: result.rejected,
                        duplicate: result.duplicate,
                        rejected_reasons: result.rejected_reasons,
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
