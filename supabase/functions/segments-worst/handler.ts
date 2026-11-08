import { errorResponse, jsonResponse, PUBLIC_JSON_CACHE_CONTROL_MEDIUM, requestIdFrom } from "../_shared/http.ts";
import { logHandlerError } from "../_shared/log.ts";

export type WorstSegmentRow = {
    rank: number;
    segment_id: string;
    road_name: string | null;
    municipality: string | null;
    road_type: string;
    category: string;
    confidence: string;
    avg_roughness_score: number;
    score_last_30d: number | null;
    score_30_60d: number | null;
    trend: string;
    total_readings: number;
    unique_contributors: number;
    pothole_count: number;
    last_reading_at: string | null;
};

export type WorstSegmentsResult = {
    generated_at: string | null;
    rows: WorstSegmentRow[];
};

export type WorstSegmentsQuery = {
    municipality: string | null;
    limit: number;
};

export function parseWorstSegmentsQuery(url: URL): WorstSegmentsQuery | null {
    const rawLimit = url.searchParams.get("limit");
    const limit = rawLimit ? Number.parseInt(rawLimit, 10) : Number.NaN;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
        return null;
    }

    const municipality = url.searchParams.get("municipality")?.trim() || null;
    return { municipality, limit };
}

// The municipality allowlist is a DISTINCT over road_segments, which only
// changes when the road network is re-imported. Without a cache every
// filtered request ran that scan (review 2026-10-18 P2), so it is held
// in-process for ten minutes.
export const MUNICIPALITY_CACHE_TTL_MS = 10 * 60 * 1000;

/// Wraps the allowlist query with an in-process TTL cache. Concurrent callers
/// share one in-flight query; a failed query is not cached, so the next
/// request retries.
export function createCachedMunicipalityLookup(
    fetchKnownMunicipalities: () => Promise<string[]>,
    options: { ttlMs?: number; now?: () => number } = {},
): () => Promise<string[]> {
    const ttlMs = options.ttlMs ?? MUNICIPALITY_CACHE_TTL_MS;
    const now = options.now ?? (() => Date.now());
    let cached: { value: string[]; expiresAt: number } | null = null;
    let inFlight: Promise<string[]> | null = null;

    return () => {
        if (cached && now() < cached.expiresAt) {
            return Promise.resolve(cached.value);
        }
        if (!inFlight) {
            inFlight = fetchKnownMunicipalities()
                .then((value) => {
                    cached = { value, expiresAt: now() + ttlMs };
                    return value;
                })
                .finally(() => {
                    inFlight = null;
                });
        }
        return inFlight;
    };
}

export function createSegmentsWorstHandler(
    deps: {
        fetchKnownMunicipalities: () => Promise<string[]>;
        fetchWorstSegments: (query: WorstSegmentsQuery) => Promise<WorstSegmentsResult>;
    },
) {
    return async function handleSegmentsWorstRequest(req: Request): Promise<Response> {
        const requestId = requestIdFrom(req);

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const query = parseWorstSegmentsQuery(new URL(req.url));
        if (!query) {
            return errorResponse(
                "validation_failed",
                "limit must be an integer between 1 and 100.",
                400,
                requestId,
            );
        }

        try {
            if (query.municipality) {
                const municipalities = await deps.fetchKnownMunicipalities();
                if (!municipalities.includes(query.municipality)) {
                    return errorResponse(
                        "validation_failed",
                        "municipality must be a known display name.",
                        400,
                        requestId,
                    );
                }
            }

            const result = await deps.fetchWorstSegments(query);
            return jsonResponse(
                {
                    generated_at: result.generated_at,
                    municipality: query.municipality,
                    rows: result.rows,
                },
                200,
                { "cache-control": PUBLIC_JSON_CACHE_CONTROL_MEDIUM },
                requestId,
            );
        } catch (error) {
            logHandlerError("segments-worst", requestId, error);
            return errorResponse(
                "service_unavailable",
                "Worst-segments lookup failed.",
                503,
                requestId,
            );
        }
    };
}
