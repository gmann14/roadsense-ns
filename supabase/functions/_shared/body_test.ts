import { assertEquals } from "jsr:@std/assert";
import { readBodyWithLimit } from "./body.ts";

function chunkedRequest(chunks: Uint8Array[], onPull?: () => void): Request {
    let index = 0;
    const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
            onPull?.();
            if (index < chunks.length) {
                controller.enqueue(chunks[index++]);
            } else {
                controller.close();
            }
        },
    });
    // No Content-Length: the shape a chunked transfer-encoded upload arrives in.
    return new Request("http://localhost/x", { method: "POST", body: stream });
}

Deno.test("readBodyWithLimit returns the decoded text for a body under the cap", async () => {
    const result = await readBodyWithLimit(
        new Request("http://localhost/x", { method: "POST", body: '{"a":1}' }),
        100,
    );
    assertEquals(result, { ok: true, text: '{"a":1}' });
});

Deno.test("readBodyWithLimit rejects an over-cap declared Content-Length without reading", async () => {
    let pulled = 0;
    const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
            pulled += 1;
            controller.enqueue(new Uint8Array(10));
            controller.close();
        },
    });
    const req = new Request("http://localhost/x", {
        method: "POST",
        body: stream,
        headers: { "content-length": "1000" },
    });
    assertEquals(await readBodyWithLimit(req, 100), { ok: false, reason: "too_large" });
    // ReadableStream may pull once eagerly on construction; it must not be drained.
    assertEquals(pulled <= 1, true);
});

Deno.test("readBodyWithLimit aborts a chunked body without Content-Length as soon as it passes the cap", async () => {
    let pulls = 0;
    const chunk = new Uint8Array(64);
    const chunks = Array.from({ length: 1000 }, () => chunk);
    const result = await readBodyWithLimit(chunkedRequest(chunks, () => pulls++), 256);
    assertEquals(result, { ok: false, reason: "too_large" });
    // 256 bytes / 64 per chunk -> fails on the 5th chunk; never reads all 1000.
    assertEquals(pulls < 10, true);
});

Deno.test("readBodyWithLimit counts UTF-8 bytes, not UTF-16 code units", async () => {
    // "é" is 1 UTF-16 unit but 2 UTF-8 bytes; 60 of them = 120 bytes.
    const text = "é".repeat(60);
    assertEquals(text.length, 60);
    const over = await readBodyWithLimit(
        new Request("http://localhost/x", { method: "POST", body: text }),
        100,
    );
    assertEquals(over, { ok: false, reason: "too_large" });

    const exact = await readBodyWithLimit(
        new Request("http://localhost/x", { method: "POST", body: text }),
        120,
    );
    assertEquals(exact, { ok: true, text });
});

Deno.test("readBodyWithLimit accepts a body exactly at the cap", async () => {
    const result = await readBodyWithLimit(chunkedRequest([new Uint8Array(50).fill(97), new Uint8Array(50).fill(98)]), 100);
    assertEquals(result.ok, true);
});

Deno.test("readBodyWithLimit treats a missing body as empty text", async () => {
    assertEquals(await readBodyWithLimit(new Request("http://localhost/x", { method: "POST" }), 10), {
        ok: true,
        text: "",
    });
});

Deno.test("readBodyWithLimit reports invalid UTF-8 as unreadable", async () => {
    const result = await readBodyWithLimit(chunkedRequest([new Uint8Array([0xff, 0xfe, 0xfd])]), 100);
    assertEquals(result, { ok: false, reason: "unreadable" });
});

Deno.test("readBodyWithLimit reports a stream error as unreadable", async () => {
    const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
            controller.error(new Error("connection reset"));
        },
    });
    const result = await readBodyWithLimit(new Request("http://localhost/x", { method: "POST", body: stream }), 100);
    assertEquals(result, { ok: false, reason: "unreadable" });
});
