import { errorResponse, jsonResponse } from "../_shared/http.ts";

export type Bbox = {
    minLng: number;
    minLat: number;
    maxLng: number;
    maxLat: number;
};

export type PotholeRow = {
    id: string;
    lat: number;
    lng: number;
    magnitude: number;
    confirmation_count: number;
    first_reported_at: string;
    last_confirmed_at: string;
    status: string;
    segment_id: string | null;
};

export function parseBbox(raw: string | null): Bbox | null {
    if (!raw) {
        return null;
    }

    const parts = raw.split(",").map((value) => Number.parseFloat(value.trim()));
    if (parts.length !== 4 || parts.some((value) => !Number.isFinite(value))) {
        return null;
    }

    const [minLng, minLat, maxLng, maxLat] = parts;
    if (minLng >= maxLng || minLat >= maxLat) {
        return null;
    }

    if (maxLng - minLng > 0.12 || maxLat - minLat > 0.09) {
        return null;
    }

    return { minLng, minLat, maxLng, maxLat };
}

export function createPotholesHandler(
    deps: { fetchPotholes: (bbox: Bbox) => Promise<PotholeRow[]> },
) {
    return async function handlePotholesRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const bbox = parseBbox(new URL(req.url).searchParams.get("bbox"));
        if (!bbox) {
            return errorResponse(
                "validation_failed",
                "bbox must be four comma-separated floats within the 10km cap.",
                400,
                requestId,
            );
        }

        try {
            const potholes = await deps.fetchPotholes(bbox);
            return jsonResponse({ potholes }, 200, {}, requestId);
        } catch {
            return errorResponse(
                "service_unavailable",
                "Pothole lookup failed.",
                503,
                requestId,
            );
        }
    };
}
