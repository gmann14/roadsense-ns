import { errorResponse, jsonResponse } from "../_shared/http.ts";

export type PublicStats = {
    total_km_mapped: number;
    total_readings: number;
    segments_scored: number;
    active_potholes: number;
    municipalities_covered: number;
    map_bounds: PublicMapBounds | null;
    pothole_bounds: PublicMapBounds | null;
    generated_at: string;
};

export type PublicMapBounds = {
    minLng: number;
    minLat: number;
    maxLng: number;
    maxLat: number;
};

export function createStatsHandler(
    deps: { fetchStats: () => Promise<PublicStats | null> },
) {
    return async function handleStatsRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        try {
            const stats = await deps.fetchStats();
            if (!stats) {
                return errorResponse(
                    "service_unavailable",
                    "Stats are unavailable.",
                    503,
                    requestId,
                );
            }

            return jsonResponse(
                stats,
                200,
                { "cache-control": "public, max-age=300" },
                requestId,
            );
        } catch {
            return errorResponse(
                "service_unavailable",
                "Stats are unavailable.",
                503,
                requestId,
            );
        }
    };
}
