import {
    assertEquals,
    assertInstanceOf,
} from "jsr:@std/assert";
import {
    createTileHandler,
    normalizeTilePayload,
    parseTilePath,
    TILE_CACHE_CONTROL,
    TILE_CONTENT_TYPE,
} from "./handler.ts";

Deno.test("parseTilePath extracts z/x/y from .mvt routes", () => {
    assertEquals(parseTilePath("/functions/v1/tiles/14/5299/5915.mvt"), {
        z: 14,
        x: 5299,
        y: 5915,
    });
    assertEquals(parseTilePath("/functions/v1/tiles/not-a-tile"), null);
});

Deno.test("normalizeTilePayload accepts hex and base64 strings", () => {
    assertEquals(Array.from(normalizeTilePayload("\\xdeadbeef") ?? []), [0xde, 0xad, 0xbe, 0xef]);
    assertEquals(Array.from(normalizeTilePayload("AQID") ?? []), [0x01, 0x02, 0x03]);
});

Deno.test("tile handler returns 404 for an invalid route", async () => {
    const handler = createTileHandler({
        rpcGetTile: async () => ({ data: null, error: null }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/tiles"));

    assertEquals(response.status, 404);
});

Deno.test("tile handler returns 405 for unsupported methods", async () => {
    const handler = createTileHandler({
        rpcGetTile: async () => ({ data: null, error: null }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/14/5299/5915.mvt", { method: "POST" }),
    );

    assertEquals(response.status, 405);
});

Deno.test("tile handler returns 204 with cache headers for an empty tile", async () => {
    const handler = createTileHandler({
        rpcGetTile: async () => ({ data: new Uint8Array(), error: null }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/14/5299/5915.mvt", {
            headers: { "x-request-id": "req-empty" },
        }),
    );

    assertEquals(response.status, 204);
    assertEquals(response.headers.get("cache-control"), TILE_CACHE_CONTROL);
    assertEquals(response.headers.get("x-request-id"), "req-empty");
});

Deno.test("tile handler returns 200 with MVT headers for a populated tile", async () => {
    const handler = createTileHandler({
        rpcGetTile: async () => ({ data: "\\xdeadbeef", error: null }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/14/5299/5915.mvt", {
            headers: { "x-request-id": "req-ok" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("content-type"), TILE_CONTENT_TYPE);
    assertEquals(response.headers.get("cache-control"), TILE_CACHE_CONTROL);
    assertEquals(response.headers.get("access-control-allow-origin"), "*");
    assertEquals(response.headers.get("x-request-id"), "req-ok");

    const body = await response.arrayBuffer();
    assertInstanceOf(body, ArrayBuffer);
    assertEquals(Array.from(new Uint8Array(body)), [0xde, 0xad, 0xbe, 0xef]);
});

Deno.test("tile handler returns 500 when the RPC fails", async () => {
    const handler = createTileHandler({
        rpcGetTile: async () => ({ data: null, error: { message: "boom" } }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/14/5299/5915.mvt", {
            headers: { "x-request-id": "req-fail" },
        }),
    );

    assertEquals(response.status, 500);
    assertEquals(response.headers.get("x-request-id"), "req-fail");
});
