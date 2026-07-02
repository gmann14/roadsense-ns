import { assertEquals } from "jsr:@std/assert";
import { isAuthorizedInternalRequest } from "./internalAuth.ts";

Deno.test("isAuthorizedInternalRequest denies everything when no secret is configured", () => {
    const headers = new Headers({ authorization: "Bearer anything" });
    assertEquals(isAuthorizedInternalRequest(headers, ""), false);
});

Deno.test("isAuthorizedInternalRequest accepts a matching Bearer token", () => {
    const headers = new Headers({ authorization: "Bearer service-role-secret" });
    assertEquals(isAuthorizedInternalRequest(headers, "service-role-secret"), true);
});

Deno.test("isAuthorizedInternalRequest accepts a matching apikey header", () => {
    const headers = new Headers({ apikey: "service-role-secret" });
    assertEquals(isAuthorizedInternalRequest(headers, "service-role-secret"), true);
});

Deno.test("isAuthorizedInternalRequest rejects a wrong secret on either header", () => {
    assertEquals(
        isAuthorizedInternalRequest(new Headers({ authorization: "Bearer wrong" }), "service-role-secret"),
        false,
    );
    assertEquals(
        isAuthorizedInternalRequest(new Headers({ apikey: "wrong" }), "service-role-secret"),
        false,
    );
});

Deno.test("isAuthorizedInternalRequest rejects missing headers", () => {
    assertEquals(isAuthorizedInternalRequest(new Headers(), "service-role-secret"), false);
});

Deno.test("isAuthorizedInternalRequest trims whitespace on the apikey header but not the secret itself", () => {
    const headers = new Headers({ apikey: "  service-role-secret  " });
    assertEquals(isAuthorizedInternalRequest(headers, "service-role-secret"), true);
});

// P1-6: comparison must be constant-time (reuses apikey.ts's helper), not a
// plain `===`. We can't directly observe timing in a unit test, but we can
// prove correctness holds across a range of length/content mismatches that a
// naive `===` would also handle correctly — this guards against a future
// regression back to `===` being silently equivalent in behavior even though
// it changes the (untestable-here) timing characteristics.
Deno.test("isAuthorizedInternalRequest is correct across varying-length mismatches", () => {
    const expected = "a-fairly-long-service-role-secret-value";
    const nearMisses = [
        expected.slice(0, -1),
        expected + "x",
        "",
        "a",
        expected.toUpperCase(),
    ];
    for (const candidate of nearMisses) {
        assertEquals(
            isAuthorizedInternalRequest(new Headers({ apikey: candidate }), expected),
            false,
            `expected rejection for candidate: ${JSON.stringify(candidate)}`,
        );
    }
});
