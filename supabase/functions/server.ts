// Single Deno entrypoint for the Railway-hosted Edge service.
//
// Mounts every existing function handler under its current /functions/v1/...
// path so the iOS and web clients require zero changes. URL routing via the
// built-in URLPattern API; no router library needed.

import { dispatch, route, type RouteHandler } from "./_shared/routes.ts";
import { verifyApiKey } from "./_shared/apikey.ts";
import { createPgRpc } from "./_shared/pgRpc.ts";

import { createHealthHandler } from "./health/handler.ts";
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

import { createSegmentsHandler } from "./segments/handler.ts";
import { createPgFetchSegmentDetail } from "./segments/pgRuntime.ts";

import { createSegmentsWorstHandler } from "./segments-worst/handler.ts";
import {
    createPgFetchKnownMunicipalities,
    createPgFetchWorstSegments,
} from "./segments-worst/pgRuntime.ts";

function configuredApiKey(): string {
    return Deno.env.get("PUBLIC_API_KEY") ?? "";
}

// Each ported handler is built lazily on first call so tests can import this
// module without a live DATABASE_URL. Subsequent calls reuse the same instance.
function lazy<T>(factory: () => T): () => T {
    let cached: T | null = null;
    return () => {
        if (cached === null) cached = factory();
        return cached;
    };
}

const getHealth = lazy(() =>
    createHealthHandler({ checkDb: createPgDbCheck() })
);
const getStats = lazy(() =>
    createStatsHandler({ fetchStats: createPgFetchStats() })
);
const getUploadReadings = lazy(() => {
    const rpc = createPgRpc();
    return createUploadReadingsHandler({
        hashDeviceToken,
        checkRateLimit: createRateLimitChecker(rpc) as (tokenHashHex: string, ip: string) => Promise<UploadRateLimitResult>,
        ingestBatch: createPgIngestBatch(),
    });
});
const getPotholeActions = lazy(() => {
    const rpc = createPgRpc();
    return createPotholeActionsHandler({
        hashDeviceToken,
        checkRateLimit: createPotholeActionRateLimitChecker(rpc) as (tokenHashHex: string, ip: string) => Promise<PotholeActionsRateLimitResult>,
        applyAction: createPgApplyAction(),
    });
});
const getFeedback = lazy(() => {
    const rpc = createPgRpc();
    return createFeedbackHandler({
        checkRateLimit: createFeedbackRateLimitChecker(rpc) as (ip: string) => Promise<FeedbackRateLimitResult>,
        insertFeedback: createPgInsertFeedback(),
    });
});
const getTiles = lazy(() => createTileHandler({ rpcGetTile: createPgTileRpc() }));
const getCoverageTiles = lazy(() => createCoverageTileHandler({ rpcGetCoverageTile: createPgCoverageTileRpc() }));
const getPotholes = lazy(() => createPotholesHandler({ fetchPotholes: createPgFetchPotholes() }));
const getSegments = lazy(() => createSegmentsHandler({ fetchSegmentDetail: createPgFetchSegmentDetail() }));
const getSegmentsWorst = lazy(() => createSegmentsWorstHandler({
    fetchKnownMunicipalities: createPgFetchKnownMunicipalities(),
    fetchWorstSegments: createPgFetchWorstSegments(),
}));

const handleHealth: RouteHandler = (req) => getHealth()(req);
const handleStats: RouteHandler = (req) => getStats()(req);
const handleUploadReadings: RouteHandler = (req) => getUploadReadings()(req);
const handlePotholeActions: RouteHandler = (req) => getPotholeActions()(req);
const handleFeedback: RouteHandler = (req) => getFeedback()(req);
const handleTiles: RouteHandler = (req) => getTiles()(req);
const handleCoverageTiles: RouteHandler = (req) => getCoverageTiles()(req);
const handlePotholes: RouteHandler = (req) => getPotholes()(req);
const handleSegmentDetail: RouteHandler = (req) => getSegments()(req);
const handleSegmentsWorst: RouteHandler = (req) => getSegmentsWorst()(req);

export const ROUTES = [
    route("/functions/v1/health", handleHealth),
    route("/functions/v1/upload-readings", handleUploadReadings),
    route("/functions/v1/pothole-actions", handlePotholeActions),
    route("/functions/v1/feedback", handleFeedback),
    route("/functions/v1/stats", handleStats),
    route("/functions/v1/segments-worst", handleSegmentsWorst),
    route("/functions/v1/segments/:id", handleSegmentDetail),
    route("/functions/v1/potholes", handlePotholes),
    route("/functions/v1/tiles/coverage/:z/:x/:y.mvt", handleCoverageTiles),
    route("/functions/v1/tiles/:z/:x/:y.mvt", handleTiles),
] as const;

export async function handleRequest(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") {
        return new Response(null, {
            status: 204,
            headers: corsHeaders(),
        });
    }

    // Health is unauthenticated so Railway/uptime probes can hit it.
    const url = new URL(req.url);
    if (url.pathname !== "/functions/v1/health") {
        const auth = verifyApiKey(req, configuredApiKey());
        if (!auth.ok) {
            return new Response(
                JSON.stringify({ error: auth.error }),
                {
                    status: auth.status,
                    headers: {
                        "content-type": "application/json; charset=utf-8",
                        ...corsHeaders(),
                    },
                },
            );
        }
    }

    const response = await dispatch(ROUTES, req);
    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(corsHeaders())) {
        if (!headers.has(key)) headers.set(key, value);
    }
    return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
    });
}

function corsHeaders(): Record<string, string> {
    return {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
        "access-control-allow-headers": "content-type, apikey, authorization, x-request-id",
        "access-control-max-age": "86400",
    };
}

// Boot only when run as the main module (not when imported by tests).
if (import.meta.main) {
    const port = Number(Deno.env.get("PORT") ?? "8000");
    console.log(`server starting on :${port}`);
    Deno.serve({ port }, handleRequest);
}
