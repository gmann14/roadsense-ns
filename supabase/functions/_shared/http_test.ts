import { assertEquals, assertMatch } from "jsr:@std/assert";
import { requestIdFrom } from "./http.ts";

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
