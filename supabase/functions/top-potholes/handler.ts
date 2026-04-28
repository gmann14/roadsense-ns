import { errorResponse, jsonResponse } from "../_shared/http.ts";
import type { PotholeRow } from "../potholes/handler.ts";

export type { PotholeRow };

export function parseTopPotholesLimit(url: URL): number | null {
    const rawLimit = url.searchParams.get("limit");
    if (rawLimit === null || rawLimit.trim() === "") {
        return 20;
    }

    const limit = Number(rawLimit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
        return null;
    }

    return limit;
}

export function createTopPotholesHandler(
    deps: { fetchTopPotholes: (limit: number) => Promise<PotholeRow[]> },
) {
    return async function handleTopPotholesRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const limit = parseTopPotholesLimit(new URL(req.url));
        if (limit === null) {
            return errorResponse(
                "validation_failed",
                "limit must be an integer between 1 and 100.",
                400,
                requestId,
            );
        }

        try {
            const potholes = await deps.fetchTopPotholes(limit);
            return jsonResponse({ potholes }, 200, {}, requestId);
        } catch {
            return errorResponse(
                "service_unavailable",
                "Top potholes lookup failed.",
                503,
                requestId,
            );
        }
    };
}
