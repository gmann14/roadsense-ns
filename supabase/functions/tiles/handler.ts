export const TILE_CONTENT_TYPE = "application/vnd.mapbox-vector-tile";
export const TILE_CACHE_CONTROL = "public, max-age=3600, s-maxage=3600";

export type TileRpcResult = {
    data: unknown;
    error: { message?: string } | null;
};

export type TileRpc = (params: { z: number; x: number; y: number }) => Promise<TileRpcResult>;

export function parseTilePath(pathname: string): { z: number; x: number; y: number } | null {
    const match = pathname.match(/\/(\d+)\/(\d+)\/(\d+)\.mvt$/);
    if (!match) {
        return null;
    }

    return {
        z: Number.parseInt(match[1], 10),
        x: Number.parseInt(match[2], 10),
        y: Number.parseInt(match[3], 10),
    };
}

function hexToBytes(hex: string): Uint8Array | null {
    const normalized = hex.replace(/^\\x/i, "").replace(/^0x/i, "");
    if (normalized.length === 0) {
        return null;
    }
    if (normalized.length % 2 !== 0 || /[^0-9a-f]/i.test(normalized)) {
        return null;
    }

    const bytes = new Uint8Array(normalized.length / 2);
    for (let i = 0; i < normalized.length; i += 2) {
        bytes[i / 2] = Number.parseInt(normalized.slice(i, i + 2), 16);
    }
    return bytes.length > 0 ? bytes : null;
}

function base64ToBytes(input: string): Uint8Array | null {
    if (input.length === 0) {
        return null;
    }

    try {
        const decoded = atob(input);
        const bytes = new Uint8Array(decoded.length);
        for (let i = 0; i < decoded.length; i += 1) {
            bytes[i] = decoded.charCodeAt(i);
        }
        return bytes.length > 0 ? bytes : null;
    } catch {
        return null;
    }
}

export function normalizeTilePayload(data: unknown): Uint8Array | null {
    if (data == null) {
        return null;
    }

    if (data instanceof Uint8Array) {
        return data.length > 0 ? data : null;
    }

    if (data instanceof ArrayBuffer) {
        return data.byteLength > 0 ? new Uint8Array(data) : null;
    }

    if (Array.isArray(data) && data.every((value) => Number.isInteger(value))) {
        return data.length > 0 ? new Uint8Array(data) : null;
    }

    if (
        typeof data === "object" &&
        data !== null &&
        "type" in data &&
        "data" in data &&
        (data as { type?: unknown }).type === "Buffer" &&
        Array.isArray((data as { data?: unknown }).data)
    ) {
        const bufferData = (data as { data: number[] }).data;
        return bufferData.length > 0 ? new Uint8Array(bufferData) : null;
    }

    if (typeof data === "string") {
        const trimmed = data.trim();
        if (trimmed.length === 0) {
            return null;
        }

        const hexBytes = hexToBytes(trimmed);
        if (hexBytes) {
            return hexBytes;
        }

        return base64ToBytes(trimmed);
    }

    return null;
}

export function createTileHandler(deps: { rpcGetTile: TileRpc }) {
    return async function handleTileRequest(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "GET" && req.method !== "HEAD") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const tileParams = parseTilePath(new URL(req.url).pathname);
        if (!tileParams) {
            return new Response(null, {
                status: 404,
                headers: { "x-request-id": requestId },
            });
        }

        const { data, error } = await deps.rpcGetTile(tileParams);
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
                    "cache-control": TILE_CACHE_CONTROL,
                    "x-request-id": requestId,
                },
            });
        }

        const bodyBytes = Uint8Array.from(tileBytes);

        return new Response(req.method === "HEAD" ? null : new Blob([bodyBytes]), {
            status: 200,
            headers: {
                "content-type": TILE_CONTENT_TYPE,
                "cache-control": TILE_CACHE_CONTROL,
                "access-control-allow-origin": "*",
                "x-request-id": requestId,
            },
        });
    };
}
