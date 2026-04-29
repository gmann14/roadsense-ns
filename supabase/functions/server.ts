// Single Deno entrypoint for the Railway-hosted Edge service.
//
// Mounts every existing function handler under its current /functions/v1/...
// path so the iOS and web clients require zero changes. URL routing via the
// built-in URLPattern API; no router library needed.

import { dispatch, route, type RouteHandler } from "./_shared/routes.ts";
import { verifyApiKey } from "./_shared/apikey.ts";
import { createPgRpc } from "./_shared/pgRpc.ts";
import { startScheduler } from "./_shared/scheduler.ts";

import { createDeepHealthHandler, createHealthHandler } from "./health/handler.ts";
import { createPgDbCheck } from "./health/pgRuntime.ts";

import { createStatsHandler } from "./stats/handler.ts";
import { createPgFetchStats } from "./stats/pgRuntime.ts";

import { createUploadReadingsHandler, type RateLimitResult as UploadRateLimitResult } from "./upload-readings/handler.ts";
import { createRateLimitChecker, hashDeviceToken } from "./upload-readings/runtime.ts";
import { createPgIngestBatch } from "./upload-readings/pgRuntime.ts";

import { createPotholeActionsHandler, type RateLimitResult as PotholeActionsRateLimitResult } from "./pothole-actions/handler.ts";
import { createPotholeActionRateLimitChecker } from "./pothole-actions/runtime.ts";
import { createPgApplyAction } from "./pothole-actions/pgRuntime.ts";

import { createFeedbackHandler, type RateLimitResult as FeedbackRateLimitResult } from "./feedback/handler.ts";
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

export const ROUTES = [
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
                checkRateLimit: createRateLimitChecker(rpc) as (tokenHashHex: string, ip: string) => Promise<UploadRateLimitResult>,
                ingestBatch: createPgIngestBatch(),
            });
        }),
    ),
    route(
        "/functions/v1/pothole-actions",
        lazy(() => {
            const rpc = createPgRpc();
            return createPotholeActionsHandler({
                hashDeviceToken,
                checkRateLimit: createPotholeActionRateLimitChecker(rpc) as (tokenHashHex: string, ip: string) => Promise<PotholeActionsRateLimitResult>,
                applyAction: createPgApplyAction(),
            });
        }),
    ),
    route(
        "/functions/v1/feedback",
        lazy(() => {
            const rpc = createPgRpc();
            return createFeedbackHandler({
                checkRateLimit: createFeedbackRateLimitChecker(rpc) as (ip: string) => Promise<FeedbackRateLimitResult>,
                insertFeedback: createPgInsertFeedback(),
            });
        }),
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
] as const;

// /health stays unauthenticated so uptime probes work without a key. Every
// other route requires apikey when PUBLIC_API_KEY is set.
const PUBLIC_PATHS = new Set<string>(["/functions/v1/health"]);

export async function handleRequest(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(req.url);
    if (!PUBLIC_PATHS.has(url.pathname)) {
        const auth = verifyApiKey(req, configuredApiKey());
        if (!auth.ok) {
            return new Response(
                JSON.stringify({ error: auth.error }),
                {
                    status: auth.status,
                    headers: {
                        "content-type": "application/json; charset=utf-8",
                        ...CORS_HEADERS,
                    },
                },
            );
        }
    }

    const response = await dispatch(ROUTES, req);
    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(CORS_HEADERS)) {
        if (!headers.has(key)) headers.set(key, value);
    }
    return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
    });
}

// Boot only when run as the main module (not when imported by tests).
if (import.meta.main) {
    const port = Number(Deno.env.get("PORT") ?? "8000");
    console.log(`server starting on :${port}`);

    // Start the in-process scheduler when running on Railway (no pg_cron).
    // Local dev with `supabase start` uses the real pg_cron and doesn't need
    // this; opt out explicitly to keep tests/dev runs quiet.
    if (Deno.env.get("RAILWAY_ENVIRONMENT") || Deno.env.get("ENABLE_SCHEDULER") === "true") {
        startScheduler();
    }

    Deno.serve({ port }, handleRequest);
}
