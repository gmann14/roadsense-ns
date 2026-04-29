import {
    isValidTileCoord,
    normalizeTilePayload,
    TILE_CONTENT_TYPE,
} from "../tiles/handler.ts";

export const COVERAGE_TILE_CACHE_CONTROL = "public, max-age=3600, s-maxage=3600";

export type CoverageTileRpcResult = {
    data: unknown;
    error: { message?: string } | null;
};

export type CoverageTileRpc = (
    params: { z: number; x: number; y: number },
) => Promise<CoverageTileRpcResult>;

export function parseCoverageTilePath(pathname: string): { z: number; x: number; y: number } | null {
    const match = pathname.match(/\/coverage\/(\d+)\/(\d+)\/(\d+)\.mvt$/);
    if (!match) {
        return null;
    }

    const z = Number.parseInt(match[1], 10);
    const x = Number.parseInt(match[2], 10);
    const y = Number.parseInt(match[3], 10);
    if (!isValidTileCoord(z, x, y)) {
        return null;
    }
    return { z, x, y };
}

export function createCoverageTileHandler(deps: { rpcGetCoverageTile: CoverageTileRpc }) {
    return async function handleCoverageTileRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const tileParams = parseCoverageTilePath(new URL(req.url).pathname);
        if (!tileParams) {
            return new Response(null, {
                status: 404,
                headers: { "x-request-id": requestId },
            });
        }

        const { data, error } = await deps.rpcGetCoverageTile(tileParams);
        if (error) {
            return new Response("error", {
                status: 500,
                headers: { "x-request-id": requestId },
            });
        }

        const tileBytes = normalizeTilePayload(data);
        if (!tileBytes) {
            return new Response(null, {
                status: 204,
                headers: {
                    "cache-control": COVERAGE_TILE_CACHE_CONTROL,
                    "x-request-id": requestId,
                },
            });
        }

        return new Response(req.method === "HEAD" ? null : new Blob([Uint8Array.from(tileBytes)]), {
            status: 200,
            headers: {
                "content-type": TILE_CONTENT_TYPE,
                "cache-control": COVERAGE_TILE_CACHE_CONTROL,
                "access-control-allow-origin": "*",
                "x-request-id": requestId,
            },
        });
    };
}
