// Single Deno entrypoint for the Railway-hosted Edge service.
//
// Mounts every existing function handler under its current /functions/v1/...
// path so the iOS and web clients require zero changes. URL routing via the
// built-in URLPattern API; no router library needed.

import { dispatchMatch, matchRoute, route, type Route, type RouteHandler, type RouteMatch } from "./_shared/routes.ts";
import { assertApiKeyConfiguredForEnvironment, isRunningOnRailway, verifyApiKey } from "./_shared/apikey.ts";
import { createPgRpc } from "./_shared/pgRpc.ts";
import { startScheduler } from "./_shared/scheduler.ts";
import { requestIdFrom, withServiceUnavailableRetryAfter } from "./_shared/http.ts";
import { logHandlerError, logRequest } from "./_shared/log.ts";
import { photoUploadsGate } from "./_shared/photoUploads.ts";
import { hasValidOriginAuth, originAuthRequired } from "./_shared/originAuth.ts";

import { createDeepHealthHandler, createHealthHandler } from "./health/handler.ts";
import { createPgDbCheck } from "./health/pgRuntime.ts";

import { createStatsHandler } from "./stats/handler.ts";
import { createPgFetchStats } from "./stats/pgRuntime.ts";

import { createUploadReadingsHandler } from "./upload-readings/handler.ts";
import { createRateLimitChecker, hashDeviceToken } from "./upload-readings/runtime.ts";
import { createPgFindProcessedBatch, createPgIngestBatch } from "./upload-readings/pgRuntime.ts";

import { createPotholeActionsHandler } from "./pothole-actions/handler.ts";
import { createPotholeActionRateLimitChecker } from "./pothole-actions/runtime.ts";
import { createPgApplyAction } from "./pothole-actions/pgRuntime.ts";

import { createFeedbackHandler } from "./feedback/handler.ts";
import { createFeedbackRateLimitChecker } from "./feedback/runtime.ts";
import { createPgInsertFeedback } from "./feedback/pgRuntime.ts";

import { createTileHandler } from "./tiles/handler.ts";
import { createPgTileRpc } from "./tiles/pgRuntime.ts";

import { createCoverageTileHandler } from "./tiles-coverage/handler.ts";
import { createPgCoverageTileRpc } from "./tiles-coverage/pgRuntime.ts";

import { createPotholesHandler } from "./potholes/handler.ts";
import { createPgFetchPotholes } from "./potholes/pgRuntime.ts";

import { createTopPotholesHandler } from "./top-potholes/handler.ts";
import { createPgFetchTopPotholes } from "./top-potholes/pgRuntime.ts";

import { createSegmentsHandler } from "./segments/handler.ts";
import { createPgFetchSegmentDetail } from "./segments/pgRuntime.ts";

import { createSegmentsWorstHandler } from "./segments-worst/handler.ts";
import {
    createPgFetchKnownMunicipalities,
    createPgFetchWorstSegments,
} from "./segments-worst/pgRuntime.ts";

import {
    attestationGate,
    createDeviceTokenChallengeHandler,
    createDeviceTokenRedeemHandler,
} from "./device-tokens/handler.ts";
import { createChallengeRateLimitChecker, createRedeemRateLimitChecker } from "./device-tokens/runtime.ts";
import {
    createPgIssueChallenge,
    createPgIssueDeviceToken,
    createPgRedeemChallenge,
} from "./device-tokens/pgRuntime.ts";
import { createFakeVerifyAttestation } from "./device-tokens/fakeVerifier.ts";

const CORS_HEADERS: Record<string, string> = {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
    "access-control-allow-headers": "content-type, apikey, authorization, x-request-id",
    "access-control-max-age": "86400",
};

// Read PUBLIC_API_KEY on every call so tests that mutate the env mid-suite
// (server_test.ts) see the change. Cheap on Deno; production payoff isn't
// worth a more complex caching scheme.
function configuredApiKey(): string {
    return Deno.env.get("PUBLIC_API_KEY") ?? "";
}

// Builds each handler lazily on first request so test imports work without a
// live DATABASE_URL. Wraps the resulting handler as a RouteHandler so we can
// register it in ROUTES directly — no second-tier wrapper required.
type AnyHandler = (req: Request) => Promise<Response>;
function lazy(factory: () => AnyHandler): RouteHandler {
    let cached: AnyHandler | null = null;
    return (req) => {
        cached ??= factory();
        return cached(req);
    };
}

export const ROUTES: readonly Route[] = [
    route("/functions/v1/health", lazy(() => createHealthHandler())),
    route(
        "/functions/v1/health/deep",
        lazy(() => createDeepHealthHandler({ checkDb: createPgDbCheck() })),
    ),
    route(
        "/functions/v1/upload-readings",
        lazy(() => {
            const rpc = createPgRpc();
            return createUploadReadingsHandler({
                hashDeviceToken,
                checkRateLimit: createRateLimitChecker(rpc),
                ingestBatch: createPgIngestBatch(),
                findProcessedBatch: createPgFindProcessedBatch(),
            });
        }),
    ),
    route(
        "/functions/v1/pothole-actions",
        lazy(() => {
            const rpc = createPgRpc();
            return createPotholeActionsHandler({
                hashDeviceToken,
                checkRateLimit: createPotholeActionRateLimitChecker(rpc),
                applyAction: createPgApplyAction(),
            });
        }),
    ),
    route(
        "/functions/v1/feedback",
        lazy(() => {
            const rpc = createPgRpc();
            return createFeedbackHandler({
                checkRateLimit: createFeedbackRateLimitChecker(rpc),
                insertFeedback: createPgInsertFeedback(),
            });
        }),
    ),
    // Device attestation (B160): challenge issuance + token redemption. Real
    // attestation verification is stubbed (createFakeVerifyAttestation) until
    // B161 (App Attest) / B163 (Play Integrity) supply real implementations
    // -- see docs/implementation/17-device-attestation-and-trust.md. Both
    // routes answer 503 attestation_disabled unless ATTESTATION_ENABLED=true
    // so the fake verifier can't mint tokens in production by default.
    // More specific path first per the routing convention documented in
    // _shared/routes.ts (matters for URLPattern ordering elsewhere; harmless
    // here since these are disjoint literal paths, but kept consistent).
    route(
        "/functions/v1/device-tokens/challenge",
        attestationGate(lazy(() => {
            const rpc = createPgRpc();
            return createDeviceTokenChallengeHandler({
                checkRateLimit: createChallengeRateLimitChecker(rpc),
                issueChallenge: createPgIssueChallenge(),
            });
        })),
    ),
    route(
        "/functions/v1/device-tokens",
        attestationGate(lazy(() =>
            createDeviceTokenRedeemHandler({
                checkRateLimit: createRedeemRateLimitChecker(createPgRpc()),
                verifyAttestation: createFakeVerifyAttestation(),
                redeemChallenge: createPgRedeemChallenge(),
                issueDeviceToken: createPgIssueDeviceToken(),
            })
        )),
    ),
    route("/functions/v1/stats", lazy(() => createStatsHandler({ fetchStats: createPgFetchStats() }))),
    route(
        "/functions/v1/segments-worst",
        lazy(() => createSegmentsWorstHandler({
            fetchKnownMunicipalities: createPgFetchKnownMunicipalities(),
            fetchWorstSegments: createPgFetchWorstSegments(),
        })),
    ),
    route("/functions/v1/segments/:id", lazy(() => createSegmentsHandler({ fetchSegmentDetail: createPgFetchSegmentDetail() }))),
    route("/functions/v1/potholes", lazy(() => createPotholesHandler({ fetchPotholes: createPgFetchPotholes() }))),
    route("/functions/v1/top-potholes", lazy(() => createTopPotholesHandler({ fetchTopPotholes: createPgFetchTopPotholes() }))),
    route("/functions/v1/tiles/coverage/:z/:x/:y.mvt", lazy(() => createCoverageTileHandler({ rpcGetCoverageTile: createPgCoverageTileRpc() }))),
    route("/functions/v1/tiles/:z/:x/:y.mvt", lazy(() => createTileHandler({ rpcGetTile: createPgTileRpc() }))),

    // Photo flow: deliberately deferred until the R2 bucket exists (backlog
    // B130; review finding NEW-2). Mounted so clients get a stable
    // 503 photos_disabled instead of a raw 404 the retry policy treats as
    // transient. To enable for real: provision R2, set the R2_* env vars
    // (see _shared/photoUploads.ts), port these handlers off supabase-js
    // Storage to an R2 S3 client (fix latent P1-7/P2-8 first), then pass the
    // real handler factories below in place of `null`.
    route("/functions/v1/pothole-photos", photoUploadsGate("pothole-photos", null)),
    route("/functions/v1/pothole-photo-moderation", photoUploadsGate("pothole-photo-moderation", null)),
    route("/functions/v1/pothole-photo-image", photoUploadsGate("pothole-photo-image", null)),
];

// /health stays unauthenticated so uptime probes work without a key. Every
// other route requires apikey when PUBLIC_API_KEY is set.
const PUBLIC_PATHS = new Set<string>(["/functions/v1/health"]);

const UNMATCHED_ROUTE = "unmatched";

function jsonGatewayResponse(status: number, body: Record<string, unknown>): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json; charset=utf-8",
            ...CORS_HEADERS,
        },
    });
}

/// Pins a bounded x-request-id on the request so every handler, the response
/// and the access log agree on one id. Unsafe or missing ids (see
/// _shared/http.ts requestIdFrom) are replaced with a fresh UUID.
function withNormalizedRequestId(req: Request, requestId: string): Request {
    if (req.headers.get("x-request-id") === requestId) {
        return req;
    }
    const headers = new Headers(req.headers);
    headers.set("x-request-id", requestId);
    return new Request(req, { headers });
}

async function routeRequest(req: Request, match: RouteMatch | null): Promise<Response> {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(req.url);

    // Worker -> origin authentication (P0-4). Only enforced when the owner
    // has set both ORIGIN_SHARED_SECRET and REQUIRE_ORIGIN_AUTH=true; see
    // _shared/originAuth.ts for the deploy-order-safe rollout. /health stays
    // reachable so Railway healthchecks (which hit the origin directly) work.
    if (
        url.pathname !== "/functions/v1/health" &&
        originAuthRequired() &&
        !hasValidOriginAuth(req.headers)
    ) {
        return jsonGatewayResponse(403, {
            error: "forbidden",
            message: "Requests must go through api.nsroadsense.ca.",
        });
    }

    if (!PUBLIC_PATHS.has(url.pathname)) {
        // Defense-in-depth (P1-5): the startup check below is the primary
        // guard, but re-check here too so a Railway deploy that somehow
        // reached request handling with an unset key still fails closed
        // (401) instead of the old fail-open behavior, even if the process
        // wasn't restarted after a config change wiped the env var.
        if (isRunningOnRailway() && configuredApiKey().trim().length === 0) {
            return jsonGatewayResponse(401, { error: "service_misconfigured" });
        }

        const auth = verifyApiKey(req, configuredApiKey());
        if (!auth.ok) {
            return jsonGatewayResponse(auth.status, { error: auth.error });
        }
    }

    return await dispatchMatch(match, req);
}

export async function handleRequest(incoming: Request): Promise<Response> {
    const startedAt = performance.now();
    const requestId = requestIdFrom(incoming);
    const req = withNormalizedRequestId(incoming, requestId);
    const match = matchRoute(ROUTES, req.url);
    const routeName = match?.route.path ?? UNMATCHED_ROUTE;

    let response: Response;
    try {
        response = await routeRequest(req, match);
    } catch (error) {
        // Handlers are expected to map their own failures; anything that
        // escapes is a bug. Answer a JSON 500 (instead of Deno's bare one)
        // and log it with the route template only.
        logHandlerError(routeName, requestId, error);
        response = jsonGatewayResponse(500, { error: "internal_error", request_id: requestId });
    }

    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(CORS_HEADERS)) {
        if (!headers.has(key)) headers.set(key, value);
    }
    if (!headers.has("x-request-id")) headers.set("x-request-id", requestId);
    withServiceUnavailableRetryAfter(response.status, headers);

    logRequest({
        method: req.method,
        route: routeName,
        status: response.status,
        durationMs: performance.now() - startedAt,
        requestId,
    });

    return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
    });
}

type ShutdownTarget = { shutdown: () => Promise<void> };
type StoppableScheduler = { stop: () => void };

/// Builds the SIGTERM/SIGINT handler: stop the scheduler so no new jobs start,
/// then let Deno.serve finish in-flight requests. Railway sends SIGTERM on
/// every redeploy. The postgres pool is left to process exit: db.ts exposes no
/// close function and is owned elsewhere. Safe to call more than once.
export function createShutdownHandler(
    server: ShutdownTarget,
    scheduler: StoppableScheduler | null,
    log: (line: string) => void = (line) => console.log(line),
): (signal: string) => Promise<void> {
    let shuttingDown: Promise<void> | null = null;
    return (signal: string) => {
        shuttingDown ??= (async () => {
            log(JSON.stringify({ level: "info", event: "shutdown", signal }));
            try {
                scheduler?.stop();
            } catch (error) {
                logHandlerError("shutdown:scheduler", "shutdown", error);
            }
            try {
                await server.shutdown();
            } catch (error) {
                logHandlerError("shutdown:server", "shutdown", error);
            }
            log(JSON.stringify({ level: "info", event: "shutdown_complete", signal }));
        })();
        return shuttingDown;
    };
}

// Boot only when run as the main module (not when imported by tests).
if (import.meta.main) {
    // Fail closed (P1-5): refuse to start on Railway with auth disabled.
    assertApiKeyConfiguredForEnvironment(configuredApiKey());

    const port = Number(Deno.env.get("PORT") ?? "8000");
    console.log(`server starting on :${port}`);

    // Start the in-process scheduler when running on Railway (no pg_cron).
    // Local dev with `supabase start` uses the real pg_cron and doesn't need
    // this; opt out explicitly to keep tests/dev runs quiet.
    const scheduler = Deno.env.get("RAILWAY_ENVIRONMENT") || Deno.env.get("ENABLE_SCHEDULER") === "true"
        ? startScheduler()
        : null;

    const server = Deno.serve({ port }, handleRequest);
    const shutdown = createShutdownHandler(server, scheduler);
    for (const signal of ["SIGTERM", "SIGINT"] as const) {
        Deno.addSignalListener(signal, () => {
            shutdown(signal).then(() => Deno.exit(0));
        });
    }
}
