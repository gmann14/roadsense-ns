import { errorResponse, jsonResponse } from "../_shared/http.ts";

export type SegmentAggregate = {
    avg_roughness_score: number;
    category: string;
    confidence: string;
    total_readings: number;
    unique_contributors: number;
    pothole_count: number;
    trend: string;
    score_last_30d: number | null;
    score_30_60d: number | null;
    last_reading_at: string | null;
    updated_at: string | null;
};

export type SegmentDetail = {
    id: string;
    road_name: string | null;
    road_type: string;
    municipality: string | null;
    length_m: number;
    has_speed_bump: boolean;
    has_rail_crossing: boolean;
    surface_type: string | null;
    aggregate: SegmentAggregate;
    potholes: SegmentPothole[];
};

export type SegmentPothole = {
    id: string;
    status: string;
    lat: number;
    lng: number;
    confirmation_count: number;
    unique_reporters: number;
    last_confirmed_at: string;
};

export function parseSegmentPath(pathname: string): string | null {
    const match = pathname.match(
        /\/segments\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i,
    );
    return match?.[1]?.toLowerCase() ?? null;
}

export function createSegmentsHandler(
    deps: { fetchSegmentDetail: (segmentId: string) => Promise<SegmentDetail | null> },
) {
    return async function handleSegmentsRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const segmentId = parseSegmentPath(new URL(req.url).pathname);
        if (!segmentId) {
            return errorResponse("not_found", "Segment not found.", 404, requestId);
        }

        try {
            const detail = await deps.fetchSegmentDetail(segmentId);
            if (!detail) {
                return errorResponse("not_found", "Segment not found.", 404, requestId);
            }

            return jsonResponse(
                {
                    ...detail,
                    history: [],
                    neighbors: null,
                },
                200,
                {},
                requestId,
            );
        } catch {
            return errorResponse(
                "service_unavailable",
                "Segment lookup failed.",
                503,
                requestId,
            );
        }
    };
}
