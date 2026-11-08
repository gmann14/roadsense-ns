import { errorResponse, jsonResponse } from "../_shared/http.ts";

export type PublicStats = {
    total_km_mapped: number;
    total_readings: number;
    segments_scored: number;
    active_potholes: number;
    municipalities_covered: number;
    map_bounds: PublicMapBounds | null;
    focus_bounds: PublicMapBounds | null;
    pothole_bounds: PublicMapBounds | null;
    /// UTC calendar day (YYYY-MM-DD) of the newest reading on a publicly
    /// visible (k >= 3) segment. Day granularity on purpose: a fresher
    /// timestamp would let an observer time a single contributor's drive.
    /// Null when no segment is public yet.
    data_updated_at: string | null;
    generated_at: string;
};

/// Normalizes a database date/timestamp to a UTC calendar day (YYYY-MM-DD).
export function toPublicDay(value: unknown): string | null {
    if (value === null || value === undefined) return null;
    const date = value instanceof Date ? value : new Date(String(value));
    if (Number.isNaN(date.getTime())) return null;
    return date.toISOString().slice(0, 10);
}

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
        } catch (error) {
            console.error("stats fetch failed", { request_id: requestId, error });
            return errorResponse(
                "service_unavailable",
                "Stats are unavailable.",
                503,
                requestId,
            );
        }
    };
}
