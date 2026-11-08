import { assertEquals } from "jsr:@std/assert";
import { extractClientIp } from "./clientIp.ts";
import { configuredOriginSecret, hasValidOriginAuth, originAuthRequired } from "./originAuth.ts";
import { handleRequest } from "../server.ts";

function withEnv(
    overrides: Record<string, string | undefined>,
    body: () => Promise<void> | void,
): Promise<void> {
    const previous = new Map<string, string | undefined>();
    for (const [key, value] of Object.entries(overrides)) {
        previous.set(key, Deno.env.get(key));
        if (value === undefined) Deno.env.delete(key);
        else Deno.env.set(key, value);
    }
    return Promise.resolve()
        .then(body)
        .finally(() => {
            for (const [key, value] of previous) {
                if (value === undefined) Deno.env.delete(key);
                else Deno.env.set(key, value);
            }
        });
}

const SECRET = "origin-secret-0123456789abcdef";

// ── x-client-ip spoofing (review 2026-10-18 P0-4) ──

Deno.test("extractClientIp ignores x-client-ip when no origin secret is configured", () => {
    const headers = new Headers({
        "x-client-ip": "1.2.3.4",
        "x-origin-auth": SECRET,
        "x-forwarded-for": "203.0.113.7",
    });
    assertEquals(extractClientIp(headers, ""), "203.0.113.7");
});

Deno.test("extractClientIp ignores a spoofed x-client-ip sent directly to the origin without x-origin-auth", () => {
    const headers = new Headers({
        "x-client-ip": "1.2.3.4",
        "x-forwarded-for": "203.0.113.7",
    });
    assertEquals(extractClientIp(headers, SECRET), "203.0.113.7");
});

Deno.test("extractClientIp ignores x-client-ip when x-origin-auth is wrong, a prefix, or empty", () => {
    for (const presented of ["wrong-secret", SECRET.slice(0, -1), `${SECRET}x`, ""]) {
        const headers = new Headers({
            "x-client-ip": "1.2.3.4",
            "x-origin-auth": presented,
            "x-forwarded-for": "203.0.113.7",
        });
        assertEquals(extractClientIp(headers, SECRET), "203.0.113.7", `presented=${presented}`);
    }
});

Deno.test("rotating a spoofed x-client-ip cannot mint distinct rate-limit identities", () => {
    const seen = new Set<string>();
    for (let i = 1; i <= 20; i++) {
        seen.add(extractClientIp(
            new Headers({ "x-client-ip": `198.51.100.${i}`, "x-forwarded-for": "203.0.113.7" }),
            SECRET,
        ));
    }
    assertEquals([...seen], ["203.0.113.7"]);
});

Deno.test("extractClientIp trusts x-client-ip with a matching x-origin-auth", () => {
    const headers = new Headers({
        "x-client-ip": "1.2.3.4",
        "x-origin-auth": SECRET,
        "x-forwarded-for": "203.0.113.7",
    });
    assertEquals(extractClientIp(headers, SECRET), "1.2.3.4");
});

Deno.test("extractClientIp reads ORIGIN_SHARED_SECRET from the env by default", () =>
    withEnv({ ORIGIN_SHARED_SECRET: SECRET }, () => {
        const headers = new Headers({
            "x-client-ip": "1.2.3.4",
            "x-origin-auth": SECRET,
            "x-forwarded-for": "203.0.113.7",
        });
        assertEquals(extractClientIp(headers), "1.2.3.4");
    }));

Deno.test("hasValidOriginAuth never matches when the secret is empty", () => {
    assertEquals(hasValidOriginAuth(new Headers({ "x-origin-auth": "" }), ""), false);
    assertEquals(hasValidOriginAuth(new Headers(), ""), false);
});

Deno.test("configuredOriginSecret trims whitespace", () =>
    withEnv({ ORIGIN_SHARED_SECRET: `  ${SECRET}\n` }, () => {
        assertEquals(configuredOriginSecret(), SECRET);
    }));

Deno.test("originAuthRequired needs both a secret and REQUIRE_ORIGIN_AUTH=true", async () => {
    await withEnv({ ORIGIN_SHARED_SECRET: undefined, REQUIRE_ORIGIN_AUTH: "true" }, () => {
        assertEquals(originAuthRequired(), false);
    });
    await withEnv({ ORIGIN_SHARED_SECRET: SECRET, REQUIRE_ORIGIN_AUTH: undefined }, () => {
        assertEquals(originAuthRequired(), false);
    });
    await withEnv({ ORIGIN_SHARED_SECRET: SECRET, REQUIRE_ORIGIN_AUTH: "false" }, () => {
        assertEquals(originAuthRequired(), false);
    });
    await withEnv({ ORIGIN_SHARED_SECRET: SECRET, REQUIRE_ORIGIN_AUTH: "TRUE" }, () => {
        assertEquals(originAuthRequired(), true);
    });
});

// ── Gateway enforcement mode ──

const ENFORCED = { ORIGIN_SHARED_SECRET: SECRET, REQUIRE_ORIGIN_AUTH: "true", PUBLIC_API_KEY: undefined };

Deno.test("handleRequest rejects direct-to-origin requests with 403 when origin auth is required", () =>
    withEnv(ENFORCED, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/does-not-matter"));
        assertEquals(res.status, 403);
        assertEquals((await res.json()).error, "forbidden");
        assertEquals(res.headers.get("access-control-allow-origin"), "*");
    }));

Deno.test("handleRequest rejects a wrong x-origin-auth with 403 when origin auth is required", () =>
    withEnv(ENFORCED, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/stats", {
            headers: { "x-origin-auth": "guess", "x-client-ip": "1.2.3.4" },
        }));
        assertEquals(res.status, 403);
    }));

Deno.test("handleRequest keeps /health reachable without origin auth so Railway healthchecks work", () =>
    withEnv(ENFORCED, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/health"));
        assertEquals(res.status, 200);
    }));

Deno.test("handleRequest still gates /health/deep behind origin auth", () =>
    withEnv(ENFORCED, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/health/deep"));
        assertEquals(res.status, 403);
    }));

Deno.test("handleRequest lets requests with a valid x-origin-auth through to routing", () =>
    withEnv(ENFORCED, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/no-such-route", {
            headers: { "x-origin-auth": SECRET },
        }));
        assertEquals(res.status, 404);
    }));

Deno.test("handleRequest does not enforce origin auth by default (deploy-order safe)", () =>
    withEnv({ ORIGIN_SHARED_SECRET: SECRET, REQUIRE_ORIGIN_AUTH: undefined, PUBLIC_API_KEY: undefined }, async () => {
        const res = await handleRequest(new Request("http://localhost/functions/v1/no-such-route"));
        assertEquals(res.status, 404);
    }));
