// Feature gate for the pothole-photo flow on the Railway gateway.
//
// The Railway migration deliberately deferred the photo endpoints
// (`pothole-photos`, `pothole-photo-moderation`, `pothole-photo-image`)
// "until R2 bucket is set up" — see backlog B130 and
// docs/implementation/13-railway-deno-migration.md. Leaving them unmounted
// meant shipped iOS builds hit a raw 404 `not_found`, which the client retry
// policy treats as a transient missing route and retries forever (review
// finding NEW-2, docs/reviews/2026-06-11-backend-prelaunch-review.md).
//
// This module mounts the routes with an explicit, contract-shaped response
// instead: 503 `photos_disabled` plus a Retry-After header, so clients see a
// stable "feature disabled" signal they can back off on. The gate is wired so
// that once the owner provisions the R2 bucket, sets the R2_* env vars, and
// ports the handlers off supabase-js Storage to an R2-compatible S3 client
// (fix latent P1-7/P2-8 first), passing the real handler factory to
// `photoUploadsGate` enables the route with zero routing changes.

import { errorResponse } from "./http.ts";
import type { RouteHandler } from "./routes.ts";

/// Stable error code clients key off; documented alongside the standard
/// codes in docs/implementation/03-api-contracts.md (503 service class).
export const PHOTOS_DISABLED_ERROR_CODE = "photos_disabled";

/// How long clients should wait before re-probing a disabled photo route.
/// Six hours keeps already-queued photos on old builds down to ~4 probes/day
/// (vs hourly with the client's default capped backoff) without making the
/// eventual enablement take unreasonably long to propagate.
export const PHOTOS_DISABLED_RETRY_AFTER_SECONDS = 21_600;

/// Env vars that must all be present (non-blank) before the photo flow can
/// be considered enableable. These match the R2 plan in
/// docs/implementation/13-railway-deno-migration.md — an S3-compatible
/// Cloudflare R2 bucket accessed with account-scoped credentials.
export const R2_REQUIRED_ENV_VARS = [
    "R2_ACCOUNT_ID",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "R2_BUCKET",
] as const;

/// True when every R2 env var is set and non-blank. Read per-request (same
/// rationale as `configuredApiKey()` in server.ts: cheap, and lets tests
/// mutate the env mid-suite).
export function photoStorageConfigured(): boolean {
    return R2_REQUIRED_ENV_VARS.every(
        (name) => (Deno.env.get(name) ?? "").trim().length > 0,
    );
}

/// Handler that answers every request with the structured feature-disabled
/// response. Method-agnostic on purpose: a disabled feature is disabled for
/// GET, HEAD, and POST alike, and a stable shape beats per-method nuance.
export function createPhotosDisabledHandler(endpoint: string): RouteHandler {
    return (req) => {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
        return Promise.resolve(errorResponse(
            PHOTOS_DISABLED_ERROR_CODE,
            "Photo uploads are temporarily disabled.",
            503,
            requestId,
            {
                endpoint,
                retry_after_s: PHOTOS_DISABLED_RETRY_AFTER_SECONDS,
            },
            { "Retry-After": String(PHOTOS_DISABLED_RETRY_AFTER_SECONDS) },
        ));
    };
}

/// Routes a photo endpoint through the storage-config gate.
///
/// - R2 not configured → 503 `photos_disabled` (the shipping state).
/// - R2 configured and a real handler factory is wired → dispatch to it
///   (built lazily once, mirroring server.ts's `lazy`).
/// - R2 configured but no factory yet (current code: the handlers still
///   target supabase-js Storage and haven't been ported) → keep serving the
///   disabled response, with a one-time warning so a half-configured deploy
///   is visible in logs instead of silently flipping behavior.
export function photoUploadsGate(
    endpoint: string,
    enabledFactory: (() => RouteHandler) | null,
): RouteHandler {
    const disabled = createPhotosDisabledHandler(endpoint);
    let enabled: RouteHandler | null = null;
    let warnedUnported = false;

    return (req, params) => {
        if (photoStorageConfigured()) {
            if (enabledFactory) {
                enabled ??= enabledFactory();
                return enabled(req, params);
            }
            if (!warnedUnported) {
                console.warn(
                    `[photo-uploads] R2 env vars are set but ${endpoint} has no R2-backed handler wired; ` +
                        "still serving 503 photos_disabled. Port the handler off supabase-js Storage " +
                        "(and fix latent P1-7/P2-8) before enabling.",
                );
                warnedUnported = true;
            }
        }
        return disabled(req, params);
    };
}
