import { errorResponse, jsonResponse } from "../_shared/http.ts";

export function createHealthHandler(
    deps: { checkDb: () => Promise<string | null> },
) {
    return async function handleHealthRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        try {
            const dbTimestamp = await deps.checkDb();
            if (!dbTimestamp) {
                return errorResponse(
                    "service_unavailable",
                    "Database is unreachable.",
                    503,
                    requestId,
                    { status: "error", db: "unreachable" },
                    { "cache-control": "no-store" },
                );
            }

            return jsonResponse(
                {
                    status: "ok",
                    version: Deno.env.get("APP_VERSION") ?? "dev",
                    commit: Deno.env.get("GIT_SHA") ?? "local",
                    deployed_at: Deno.env.get("DEPLOYED_AT") ?? dbTimestamp,
                    db: "reachable",
                },
                200,
                { "cache-control": "no-store" },
                requestId,
            );
        } catch {
            return errorResponse(
                "service_unavailable",
                "Database is unreachable.",
                503,
                requestId,
                { status: "error", db: "unreachable" },
                { "cache-control": "no-store" },
            );
        }
    };
}
