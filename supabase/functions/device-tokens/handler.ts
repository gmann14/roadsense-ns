// B160 — server-issued device tokens: challenge issuance + redemption.
//
// Two endpoints, one module (mirrors the size of pothole-actions/feedback,
// which also keep request/response shapes for closely related actions
// together):
//   POST /functions/v1/device-tokens/challenge  -- issue a 32-byte challenge
//   POST /functions/v1/device-tokens            -- redeem challenge + attestation for a token
//
// Attestation verification itself is NOT implemented here. It is a stubbed
// injected dependency (`verifyAttestation`) -- B161 (App Attest) and B163
// (Play Integrity) supply real implementations later. See the
// VerifyAttestation type below for the exact interface B161/B163 must
// implement.

import { errorResponse, jsonResponse, requestIdFrom } from "../_shared/http.ts";
import { readBodyWithLimit } from "../_shared/body.ts";
import { extractClientIp } from "../_shared/clientIp.ts";
import type { RateLimitResult } from "../_shared/rateLimit.ts";
import type { RouteHandler } from "../_shared/routes.ts";

export { extractClientIp };
export type { RateLimitResult };

// Body-size cap (matches the P0-2 pattern used by every other handler:
// upload-readings, pothole-actions, feedback). These are small fixed-shape
// payloads; a generous ceiling still blocks junk before parsing.
export const MAX_PAYLOAD_BYTES = 262_144;

export const MAX_VERSION_STRING_LENGTH = 100;

export const SUPPORTED_PLATFORMS = new Set(["ios", "android"]);

// key_id is documented as base64url (App Attest key ids are base64); the
// challenge is the base64url string this service issued. Checking the
// charset up front turns junk (including non-Latin-1 text, which made the
// fake verifier's btoa() throw and surface as 503) into a 400 *before* the
// single-use challenge is consumed.
const BASE64ISH_RE = /^[A-Za-z0-9+/_-]+={0,2}$/;
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;
export const MAX_KEY_ID_LENGTH = 512;
export const MAX_CHALLENGE_LENGTH = 128;

// ── Feature gate ────────────────────────────────────────────────────────
//
// Real attestation verification (B161 App Attest / B163 Play Integrity) has
// not landed, and the only verifier wired in server.ts is the fake one, so
// both device-token routes stay off unless ATTESTATION_ENABLED=true (review
// 2026-10-18: "Fake attestation verifier wired into production"). Disabled
// routes answer like the photo gate: a stable 503 code plus Retry-After, so
// clients back off instead of treating it as a hard failure.

export const ATTESTATION_DISABLED_ERROR_CODE = "attestation_disabled";
export const ATTESTATION_DISABLED_RETRY_AFTER_SECONDS = 21_600;

/// Read per request so an env change (or a test) takes effect immediately.
export function attestationEnabled(): boolean {
    return (Deno.env.get("ATTESTATION_ENABLED") ?? "").trim().toLowerCase() === "true";
}

export function attestationGate(enabled: RouteHandler): RouteHandler {
    return (req, params) => {
        if (attestationEnabled()) {
            return enabled(req, params);
        }
        return Promise.resolve(errorResponse(
            ATTESTATION_DISABLED_ERROR_CODE,
            "Device attestation is not enabled yet.",
            503,
            requestIdFrom(req),
            { retry_after_s: ATTESTATION_DISABLED_RETRY_AFTER_SECONDS },
            { "Retry-After": String(ATTESTATION_DISABLED_RETRY_AFTER_SECONDS) },
        ));
    };
}

// ── Challenge issuance ──────────────────────────────────────────────────

export type ChallengeResult = {
    challenge: string; // base64url-encoded 32 random bytes
    expires_at: string;
};

export type ChallengeHandlerDeps = {
    checkRateLimit: (ip: string) => Promise<RateLimitResult>;
    issueChallenge: (params: { clientIp: string }) => Promise<ChallengeResult>;
};

export function createDeviceTokenChallengeHandler(deps: ChallengeHandlerDeps) {
    return async function handleDeviceTokenChallenge(req: Request): Promise<Response> {
        const requestId = requestIdFrom(req);

        if (req.method !== "POST") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const ip = extractClientIp(req.headers);

        try {
            const rateLimit = await deps.checkRateLimit(ip);
            if (!rateLimit.ok) {
                return errorResponse(
                    "rate_limited",
                    "Too many challenge requests from this IP.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            const result = await deps.issueChallenge({ clientIp: ip });
            return jsonResponse(result, 200, {}, requestId);
        } catch (error) {
            console.error("device-tokens/challenge unavailable", {
                request_id: requestId,
                error,
            });
            return errorResponse(
                "service_unavailable",
                "Device token challenge service unavailable.",
                503,
                requestId,
            );
        }
    };
}

// ── Challenge + attestation redemption ──────────────────────────────────

export type DeviceTokenRedeemPayload = {
    platform: string;
    key_id: string; // base64url-encoded raw attestation key id; hashed before persisting, never stored raw
    attestation_object: string; // base64-encoded CBOR (or platform-equivalent) attestation payload
    challenge: string; // base64url-encoded raw challenge as returned by the challenge endpoint
    client_app_version: string;
    client_os_version: string;
};

export type ValidationResult =
    | { ok: true; payload: DeviceTokenRedeemPayload }
    | { ok: false; fieldErrors: Record<string, string> };

function isNonEmptyString(value: unknown): value is string {
    return typeof value === "string" && value.trim().length > 0;
}

export function validateDeviceTokenRedeemPayload(payload: unknown): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            fieldErrors: { payload: "must be a JSON object" },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};

    const platform = String(input.platform ?? "");
    if (!isNonEmptyString(input.platform)) {
        fieldErrors.platform = "must be a non-empty string";
    } else if (!SUPPORTED_PLATFORMS.has(platform)) {
        fieldErrors.platform = "must be one of ios, android";
    }

    if (!isNonEmptyString(input.key_id)) {
        fieldErrors.key_id = "must be a non-empty string";
    } else if (input.key_id.length > MAX_KEY_ID_LENGTH || !BASE64ISH_RE.test(input.key_id)) {
        fieldErrors.key_id = `must be a base64 or base64url string of at most ${MAX_KEY_ID_LENGTH} characters`;
    }

    if (!isNonEmptyString(input.attestation_object)) {
        fieldErrors.attestation_object = "must be a non-empty string";
    }

    if (!isNonEmptyString(input.challenge)) {
        fieldErrors.challenge = "must be a non-empty string";
    } else if (input.challenge.length > MAX_CHALLENGE_LENGTH || !BASE64URL_RE.test(input.challenge)) {
        fieldErrors.challenge = `must be a base64url string of at most ${MAX_CHALLENGE_LENGTH} characters`;
    }

    if (
        !isNonEmptyString(input.client_app_version) ||
        (typeof input.client_app_version === "string" && input.client_app_version.length > MAX_VERSION_STRING_LENGTH)
    ) {
        fieldErrors.client_app_version = isNonEmptyString(input.client_app_version)
            ? `must be at most ${MAX_VERSION_STRING_LENGTH} characters`
            : "must be a non-empty string";
    }

    if (
        !isNonEmptyString(input.client_os_version) ||
        (typeof input.client_os_version === "string" && input.client_os_version.length > MAX_VERSION_STRING_LENGTH)
    ) {
        fieldErrors.client_os_version = isNonEmptyString(input.client_os_version)
            ? `must be at most ${MAX_VERSION_STRING_LENGTH} characters`
            : "must be a non-empty string";
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { ok: false, fieldErrors };
    }

    return {
        ok: true,
        payload: {
            platform,
            key_id: String(input.key_id),
            attestation_object: String(input.attestation_object),
            challenge: String(input.challenge),
            client_app_version: String(input.client_app_version),
            client_os_version: String(input.client_os_version),
        },
    };
}

// The interface B161 (App Attest) and B163 (Play Integrity) implement for
// real. For B160, only a stub/fake verifier is wired in production wiring
// (index.ts) -- this ticket does not verify any real attestation.
//
// Contract for future implementers:
//   - `platform` is one of SUPPORTED_PLATFORMS ("ios" | "android").
//   - `keyId` / `attestationObject` / `challenge` are exactly the raw
//     (un-hashed, decoded-from-base64/base64url is the implementer's
//     choice) strings the client sent -- this handler does not transform
//     them before calling verifyAttestation.
//   - On success, return `{ ok: true, publicKey, signCount, trustTier }`.
//     `publicKey` is the raw device public key bytes (base64 or Uint8Array
//     both acceptable -- pgRuntime is responsible for coercing to BYTEA).
//     `trustTier` lets the verifier decide the initial tier (e.g. B163's
//     sideload-beta decision maps a partial Play Integrity verdict to
//     'attested' instead of 'established').
//   - On failure, return `{ ok: false, reason }` with a short machine
//     reason string; the handler maps every failure to the single
//     `attestation_failed` error code (400) -- verifiers should NOT throw
//     for expected verification failures, only for genuine infrastructure
//     errors (e.g. Google Play Integrity decode endpoint unreachable),
//     which the handler surfaces as 503 service_unavailable.
export type AttestationVerification =
    | { ok: true; publicKey: string; signCount: number; trustTier: "unverified" | "attested" | "established" }
    | { ok: false; reason: string };

export type VerifyAttestation = (
    platform: string,
    params: { keyId: string; attestationObject: string; challenge: string },
) => Promise<AttestationVerification>;

export type DeviceTokenResult = {
    device_token: string;
    expires_at: string;
};

export type RedeemChallengeResult =
    | { ok: true }
    | { ok: false; reason: "missing" | "expired" };

export type DeviceTokenRedeemHandlerDeps = {
    // Per-IP limit on redemption attempts, checked after validation and
    // before the challenge is consumed or the verifier runs.
    checkRateLimit: (ip: string) => Promise<RateLimitResult>;
    verifyAttestation: VerifyAttestation;
    redeemChallenge: (challenge: string) => Promise<RedeemChallengeResult>;
    issueDeviceToken: (params: {
        platform: string;
        keyId: string;
        publicKey: string;
        signCount: number;
        trustTier: "unverified" | "attested" | "established";
    }) => Promise<DeviceTokenResult>;
};

export function createDeviceTokenRedeemHandler(deps: DeviceTokenRedeemHandlerDeps) {
    return async function handleDeviceTokenRedeem(req: Request): Promise<Response> {
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
                    "Device token payload is too large.",
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

        const validation = validateDeviceTokenRedeemPayload(rawPayload);
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

        // Unknown platform values are already rejected by validation above
        // with validation_failed; SUPPORTED_PLATFORMS is the single source
        // of truth so this can't drift.

        try {
            const rateLimit = await deps.checkRateLimit(extractClientIp(req.headers));
            if (!rateLimit.ok) {
                return errorResponse(
                    "rate_limited",
                    "Too many device token requests from this IP.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            const redemption = await deps.redeemChallenge(payload.challenge);
            if (!redemption.ok) {
                if (redemption.reason === "expired") {
                    return errorResponse(
                        "challenge_expired",
                        "This challenge has expired. Request a new one.",
                        400,
                        requestId,
                    );
                }
                return errorResponse(
                    "challenge_invalid",
                    "This challenge is missing or has already been used.",
                    400,
                    requestId,
                );
            }

            const verification = await deps.verifyAttestation(payload.platform, {
                keyId: payload.key_id,
                attestationObject: payload.attestation_object,
                challenge: payload.challenge,
            });

            if (!verification.ok) {
                return errorResponse(
                    "attestation_failed",
                    "Device attestation could not be verified.",
                    400,
                    requestId,
                    { reason: verification.reason },
                );
            }

            const result = await deps.issueDeviceToken({
                platform: payload.platform,
                keyId: payload.key_id,
                publicKey: verification.publicKey,
                signCount: verification.signCount,
                trustTier: verification.trustTier,
            });

            return jsonResponse(result, 200, {}, requestId);
        } catch (error) {
            console.error("device-tokens redeem failed", {
                request_id: requestId,
                error,
            });
            return errorResponse(
                "service_unavailable",
                "Device token service unavailable.",
                503,
                requestId,
            );
        }
    };
}
