// Bounded request-body reader (review 2026-10-18, "Body cap applied after the
// read").
//
// `req.text()` buffers the entire body before any size check can run, and a
// chunked request carries no Content-Length to reject up front, so a few
// concurrent multi-megabyte POSTs sent straight to the Railway origin could
// exhaust the instance's memory. This reads the stream chunk by chunk,
// counting bytes (not UTF-16 code units), and cancels the stream as soon as
// the running total passes the cap.

export type ReadBodyResult =
    | { ok: true; text: string }
    | { ok: false; reason: "too_large" | "unreadable" };

export async function readBodyWithLimit(req: Request, maxBytes: number): Promise<ReadBodyResult> {
    // Cheap early exit when the client is honest about the size. A missing,
    // malformed or understated Content-Length is still caught by the streaming
    // count below.
    const declared = req.headers.get("content-length");
    if (declared !== null && /^\d+$/.test(declared.trim()) && Number(declared) > maxBytes) {
        return { ok: false, reason: "too_large" };
    }

    if (req.body === null) {
        return { ok: true, text: "" };
    }

    const reader = req.body.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;

    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            if (!value) continue;
            total += value.byteLength;
            if (total > maxBytes) {
                await reader.cancel().catch(() => undefined);
                return { ok: false, reason: "too_large" };
            }
            chunks.push(value);
        }
    } catch {
        return { ok: false, reason: "unreadable" };
    }

    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
    }

    try {
        return { ok: true, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
    } catch {
        return { ok: false, reason: "unreadable" };
    }
}
