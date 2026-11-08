import { assertEquals, assertMatch } from "jsr:@std/assert";
import { DEFAULT_SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS, errorResponse, requestIdFrom } from "./http.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function reqWithId(id: string | null): Request {
    return new Request("http://localhost/x", id === null ? {} : { headers: { "x-request-id": id } });
}

Deno.test("requestIdFrom keeps a safe client-supplied x-request-id", () => {
    for (const id of ["req-test-1", "01H9ZABCDEF", "a.b_c:d-e", "x".repeat(64)]) {
        assertEquals(requestIdFrom(reqWithId(id)), id);
    }
});

Deno.test("requestIdFrom replaces a missing, oversized or unsafe x-request-id with a UUID", () => {
    for (const id of [null, "", "x".repeat(65), "has space", "semi;colon", "<script>", "ünicode"]) {
        assertMatch(requestIdFrom(reqWithId(id)), UUID_RE, String(id));
    }
});

Deno.test("errorResponse gives every 503 a default Retry-After", () => {
    const res = errorResponse("service_unavailable", "down", 503, "req-1");
    assertEquals(res.headers.get("Retry-After"), String(DEFAULT_SERVICE_UNAVAILABLE_RETRY_AFTER_SECONDS));
});

Deno.test("errorResponse keeps a caller-supplied Retry-After on a 503", () => {
    const res = errorResponse("photos_disabled", "off", 503, "req-1", {}, { "retry-after": "86400" });
    assertEquals(res.headers.get("Retry-After"), "86400");
});

Deno.test("errorResponse adds no Retry-After to non-503 errors", () => {
    for (const status of [400, 404, 500, 502]) {
        assertEquals(errorResponse("x", "y", status, "req-1").headers.get("Retry-After"), null);
    }
});
