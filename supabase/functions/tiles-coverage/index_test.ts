import { assertEquals } from "jsr:@std/assert";
import {
    COVERAGE_TILE_CACHE_CONTROL,
    createCoverageTileHandler,
    parseCoverageTilePath,
} from "./handler.ts";

Deno.test("parseCoverageTilePath extracts z/x/y from coverage .mvt routes", () => {
    assertEquals(parseCoverageTilePath("/functions/v1/tiles/coverage/14/5299/5915.mvt"), {
        z: 14,
        x: 5299,
        y: 5915,
    });
    assertEquals(parseCoverageTilePath("/functions/v1/tiles/coverage/not-a-tile"), null);
});

Deno.test("coverage tile handler returns 404 for invalid route", async () => {
    const handler = createCoverageTileHandler({
        rpcGetCoverageTile: async () => ({ data: null, error: null }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/tiles/coverage"));
    assertEquals(response.status, 404);
});

Deno.test("coverage tile handler returns 204 for empty tile", async () => {
    const handler = createCoverageTileHandler({
        rpcGetCoverageTile: async () => ({ data: new Uint8Array(), error: null }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/coverage/14/5299/5915.mvt", {
            headers: { "x-request-id": "req-coverage-empty" },
        }),
    );

    assertEquals(response.status, 204);
    assertEquals(response.headers.get("cache-control"), COVERAGE_TILE_CACHE_CONTROL);
    assertEquals(response.headers.get("x-request-id"), "req-coverage-empty");
});

Deno.test("coverage tile handler returns 200 with MVT bytes", async () => {
    const handler = createCoverageTileHandler({
        rpcGetCoverageTile: async () => ({ data: "\\xdeadbeef", error: null }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/coverage/14/5299/5915.mvt", {
            headers: { "x-request-id": "req-coverage-ok" },
        }),
    );

    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), COVERAGE_TILE_CACHE_CONTROL);
    assertEquals(response.headers.get("content-type"), "application/vnd.mapbox-vector-tile");
    assertEquals(response.headers.get("x-request-id"), "req-coverage-ok");
});

Deno.test("coverage tile handler returns 500 when RPC fails", async () => {
    const handler = createCoverageTileHandler({
        rpcGetCoverageTile: async () => ({ data: null, error: { message: "boom" } }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/tiles/coverage/14/5299/5915.mvt"),
    );

    assertEquals(response.status, 500);
});
