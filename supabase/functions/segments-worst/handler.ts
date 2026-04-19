import { errorResponse, jsonResponse } from "../_shared/http.ts";

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

export function createSegmentsWorstHandler(
    deps: {
        fetchKnownMunicipalities: () => Promise<string[]>;
        fetchWorstSegments: (query: WorstSegmentsQuery) => Promise<WorstSegmentsResult>;
    },
) {
    return async function handleSegmentsWorstRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

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
                { "cache-control": "public, max-age=900, s-maxage=900" },
                requestId,
            );
        } catch {
            return errorResponse(
                "service_unavailable",
                "Worst-segments lookup failed.",
                503,
                requestId,
            );
        }
    };
}
