// Shared fixtures for handler tests. Not a test file itself (no `_test`
// suffix), so `deno test` only runs it through the files that import it.

/// A POST request whose body is an effectively endless chunked stream with no
/// Content-Length header, the shape a chunked transfer-encoded upload arrives
/// in. `pulls()` reports how many chunks the handler actually consumed, so a
/// test can prove the handler stopped early instead of buffering it all.
export function endlessChunkedPost(
    url: string,
    { chunkBytes = 16_384, maxChunks = 10_000 }: { chunkBytes?: number; maxChunks?: number } = {},
): { request: Request; pulls: () => number } {
    let pulled = 0;
    const chunk = new TextEncoder().encode("x".repeat(chunkBytes));
    const stream = new ReadableStream<Uint8Array>({
        pull(controller) {
            if (pulled >= maxChunks) {
                controller.close();
                return;
            }
            pulled += 1;
            controller.enqueue(chunk);
        },
    });
    const request = new Request(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: stream,
    });
    return { request, pulls: () => pulled };
}

export function unexpectedCall(name: string): () => never {
    return () => {
        throw new Error(`${name} must not be called`);
    };
}
