import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import {
    ATTESTATION_DISABLED_RETRY_AFTER_SECONDS,
    attestationGate,
    createDeviceTokenChallengeHandler,
    createDeviceTokenRedeemHandler,
    MAX_PAYLOAD_BYTES,
    validateDeviceTokenRedeemPayload,
    type AttestationVerification,
    type RedeemChallengeResult,
} from "./handler.ts";
import { createChallengeRateLimitChecker, createRedeemRateLimitChecker } from "./runtime.ts";
import { createFakeVerifyAttestation } from "./fakeVerifier.ts";
import type { RateLimitResult } from "../_shared/rateLimit.ts";
import type { RpcResponse } from "../upload-readings/runtime.ts";
import { endlessChunkedPost, unexpectedCall } from "../_shared/test_helpers.ts";

const validRedeemPayload = {
    platform: "ios",
    key_id: "dGVzdC1rZXktaWQ",
    attestation_object: "dGVzdC1hdHRlc3RhdGlvbi1vYmplY3Q",
    challenge: "dGVzdC1jaGFsbGVuZ2U",
    client_app_version: "0.3.0 (12)",
    client_os_version: "iOS 17.4.1",
} as const;

// ── validateDeviceTokenRedeemPayload ────────────────────────────────────

Deno.test("validateDeviceTokenRedeemPayload accepts a well-formed payload", () => {
    const result = validateDeviceTokenRedeemPayload(validRedeemPayload);
    assertEquals(result.ok, true);
});

Deno.test("validateDeviceTokenRedeemPayload rejects an unknown platform value", () => {
    const result = validateDeviceTokenRedeemPayload({
        ...validRedeemPayload,
        platform: "windows_phone",
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.platform, "must be one of ios, android");
    }
});

Deno.test("validateDeviceTokenRedeemPayload rejects missing required fields", () => {
    const result = validateDeviceTokenRedeemPayload({
        platform: "ios",
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            key_id: "must be a non-empty string",
            attestation_object: "must be a non-empty string",
            challenge: "must be a non-empty string",
        });
    }
});

Deno.test("validateDeviceTokenRedeemPayload rejects a non-object payload", () => {
    const result = validateDeviceTokenRedeemPayload("nope");
    assertEquals(result.ok, false);
});

Deno.test("validateDeviceTokenRedeemPayload rejects overlong version strings", () => {
    const result = validateDeviceTokenRedeemPayload({
        ...validRedeemPayload,
        client_app_version: "x".repeat(101),
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.client_app_version, "must be at most 100 characters");
    }
});

// ── POST /functions/v1/device-tokens/challenge ──────────────────────────

Deno.test("challenge handler returns a 32-byte challenge on success", async () => {
    const handler = createDeviceTokenChallengeHandler({
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        issueChallenge: async () => ({
            challenge: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            expires_at: "2026-07-02T00:05:00Z",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens/challenge", { method: "POST" }),
    );

    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(typeof body.challenge, "string");
    assertEquals(typeof body.expires_at, "string");
});

Deno.test("challenge handler issues a genuinely 32-byte (256-bit) challenge end to end", async () => {
    // Exercises the real generator (not a mock) to prove the contract: a
    // base64url string that decodes to exactly 32 bytes.
    const { generateChallengeBase64Url } = await import("./runtime.ts");
    const challenge = generateChallengeBase64Url();
    const padded = challenge + "=".repeat((4 - (challenge.length % 4)) % 4);
    const decoded = atob(padded.replaceAll("-", "+").replaceAll("_", "/"));
    assertEquals(decoded.length, 32);
});

Deno.test("challenge handler returns 429 with Retry-After when rate limited", async () => {
    const handler = createDeviceTokenChallengeHandler({
        checkRateLimit: async () => ({ ok: false, retryAfterSeconds: 1800 }),
        issueChallenge: async () => {
            throw new Error("must not be called when rate limited");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens/challenge", {
            method: "POST",
            headers: { "x-request-id": "req-challenge-limit" },
        }),
    );

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "1800");
    assertEquals((await response.json()).error, "rate_limited");
});

Deno.test("challenge handler is rate-limited per IP", async () => {
    const seenIps: string[] = [];
    const handler = createDeviceTokenChallengeHandler({
        checkRateLimit: async (ip) => {
            seenIps.push(ip);
            return { ok: true, retryAfterSeconds: 0 };
        },
        issueChallenge: async () => ({ challenge: "x", expires_at: "2026-07-02T00:05:00Z" }),
    });

    await handler(
        new Request("http://localhost/functions/v1/device-tokens/challenge", {
            method: "POST",
            headers: { "x-forwarded-for": "203.0.113.20, 10.0.0.1" },
        }),
    );

    assertEquals(seenIps, ["203.0.113.20"]);
});

Deno.test("challenge handler returns 405 for non-POST methods", async () => {
    const handler = createDeviceTokenChallengeHandler({
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        issueChallenge: async () => ({ challenge: "x", expires_at: "2026-07-02T00:05:00Z" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens/challenge", { method: "GET" }),
    );

    assertEquals(response.status, 405);
});

Deno.test("challenge handler returns 503 service_unavailable when issuance throws", async () => {
    const handler = createDeviceTokenChallengeHandler({
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        issueChallenge: async () => {
            throw new Error("db unreachable");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens/challenge", { method: "POST" }),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});

Deno.test("createChallengeRateLimitChecker uses the device-token-challenge-ip prefix and 30/hr limit", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createChallengeRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: true as T, error: null };
        },
        () => new Date("2026-07-02T18:00:00Z"),
    );

    const result = await checker("203.0.113.30");

    assertEquals(result, { ok: true, retryAfterSeconds: 0 });
    assertEquals(calls[0].p_key, "device-token-challenge-ip:203.0.113.30");
    assertEquals(calls[0].p_limit, 30);
});

// ── POST /functions/v1/device-tokens (redeem) ───────────────────────────

function makeRedeemHandler(overrides: {
    checkRateLimit?: (ip: string) => Promise<RateLimitResult>;
    verifyAttestation?: (
        platform: string,
        params: { keyId: string; attestationObject: string; challenge: string },
    ) => Promise<AttestationVerification>;
    redeemChallenge?: (challenge: string) => Promise<RedeemChallengeResult>;
    issueDeviceToken?: (params: {
        platform: string;
        keyId: string;
        publicKey: string;
        signCount: number;
        trustTier: "unverified" | "attested" | "established";
    }) => Promise<{ device_token: string; expires_at: string }>;
} = {}) {
    return createDeviceTokenRedeemHandler({
        checkRateLimit: overrides.checkRateLimit ?? (async () => ({ ok: true, retryAfterSeconds: 0 })),
        verifyAttestation: overrides.verifyAttestation ?? (async () => ({
            ok: true,
            publicKey: "dGVzdC1wdWJsaWMta2V5",
            signCount: 0,
            trustTier: "attested",
        })),
        redeemChallenge: overrides.redeemChallenge ?? (async () => ({ ok: true })),
        issueDeviceToken: overrides.issueDeviceToken ?? (async () => ({
            device_token: "11111111-1111-4111-8111-111111111111",
            expires_at: "2026-08-01T00:00:00Z",
        })),
    });
}

Deno.test("redeem handler returns 200 with a device token on success", async () => {
    const handler = makeRedeemHandler();

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.device_token, "11111111-1111-4111-8111-111111111111");
    assertEquals(typeof body.expires_at, "string");
});

Deno.test("redeem handler returns 400 validation_failed for malformed JSON", async () => {
    const handler = makeRedeemHandler();

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            body: "{",
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("redeem handler rejects an unknown platform value with validation_failed", async () => {
    const handler = makeRedeemHandler();

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ ...validRedeemPayload, platform: "blackberry" }),
        }),
    );

    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error, "validation_failed");
    assertEquals(body.field_errors.platform, "must be one of ios, android");
});

Deno.test("redeem handler rejects a missing challenge with challenge_invalid (distinct from expired)", async () => {
    const handler = makeRedeemHandler({
        redeemChallenge: async () => ({ ok: false, reason: "missing" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "challenge_invalid");
});

Deno.test("redeem handler rejects an expired challenge with challenge_expired (distinct from missing/reused)", async () => {
    const handler = makeRedeemHandler({
        redeemChallenge: async () => ({ ok: false, reason: "expired" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "challenge_expired");
});

Deno.test("redeem handler rejects a reused challenge the same way as a missing one (challenge_invalid)", async () => {
    // Reuse and "never existed" are indistinguishable at the SQL layer by
    // design (both are "the row is gone"); both map to challenge_invalid,
    // which is still a DISTINCT code from challenge_expired.
    const handler = makeRedeemHandler({
        redeemChallenge: async () => ({ ok: false, reason: "missing" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "challenge_invalid");
});

Deno.test("redeem handler does not call verifyAttestation when the challenge is invalid", async () => {
    let verifyCalled = false;
    const handler = makeRedeemHandler({
        redeemChallenge: async () => ({ ok: false, reason: "missing" }),
        verifyAttestation: async () => {
            verifyCalled = true;
            return { ok: true, publicKey: "x", signCount: 0, trustTier: "attested" };
        },
    });

    await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(verifyCalled, false, "spending a challenge check before attestation avoids wasted verification work on dead challenges");
});

Deno.test("redeem handler returns 400 attestation_failed when the verifier rejects", async () => {
    const handler = makeRedeemHandler({
        verifyAttestation: async () => ({ ok: false, reason: "bad_nonce" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error, "attestation_failed");
    assertEquals(body.reason, "bad_nonce");
});

Deno.test("redeem handler passes the exact platform/keyId/attestationObject/challenge to verifyAttestation", async () => {
    let seenPlatform = "";
    let seenParams: { keyId: string; attestationObject: string; challenge: string } | null = null;
    const handler = makeRedeemHandler({
        verifyAttestation: async (platform, params) => {
            seenPlatform = platform;
            seenParams = params;
            return { ok: true, publicKey: "x", signCount: 0, trustTier: "attested" };
        },
    });

    await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(seenPlatform, "ios");
    assertObjectMatch(seenParams!, {
        keyId: validRedeemPayload.key_id,
        attestationObject: validRedeemPayload.attestation_object,
        challenge: validRedeemPayload.challenge,
    });
});

Deno.test("redeem handler returns 405 for non-POST methods", async () => {
    const handler = makeRedeemHandler();
    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", { method: "GET" }),
    );
    assertEquals(response.status, 405);
});

Deno.test("redeem handler returns 413 for an oversized declared content-length", async () => {
    const handler = makeRedeemHandler();
    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "content-length": String(MAX_PAYLOAD_BYTES + 1),
            },
            body: JSON.stringify(validRedeemPayload),
        }),
    );
    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
});

Deno.test("redeem handler returns 503 service_unavailable when issueDeviceToken throws", async () => {
    const handler = makeRedeemHandler({
        issueDeviceToken: async () => {
            throw new Error("db unreachable");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/device-tokens", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validRedeemPayload),
        }),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});

// ── Guard: no raw key_id, challenge, or attestation payload is ever logged
// or persisted outside a hashed column. This is the automated form of the
// B160 RED requirement ("a grep-style/pgTAP guard asserting no table or log
// line stores a raw key_id or more than one token hash per device"). The
// pgTAP half (schema/constraint shape) lives in
// supabase/tests/020_device_attestation_tokens.sql; this half proves the
// Deno source never logs the raw secret material it receives.

Deno.test("guard: handler.ts never logs raw key_id, challenge, or attestation_object values", async () => {
    const source = await Deno.readTextFile(new URL("./handler.ts", import.meta.url));
    const logCallPattern = /console\.(log|error|warn|info|debug)\(([^;]*?)\);/gs;
    let match: RegExpExecArray | null;
    let sawAnyLogCall = false;

    while ((match = logCallPattern.exec(source)) !== null) {
        sawAnyLogCall = true;
        const logCallBody = match[2];
        // The log call must not reference the raw payload fields by name --
        // only request_id/error/generic metadata are allowed.
        for (const forbidden of ["payload.key_id", "payload.attestation_object", "payload.challenge", "verification.publicKey"]) {
            assertEquals(
                logCallBody.includes(forbidden),
                false,
                `console log call must not reference ${forbidden}: ${logCallBody}`,
            );
        }
    }

    assertEquals(sawAnyLogCall, true, "expected at least one console.* call to scan (guard would be vacuous otherwise)");
});

Deno.test("guard: pgRuntime.ts never passes a raw key_id/challenge string into a query without hashing first", async () => {
    const source = await Deno.readTextFile(new URL("./pgRuntime.ts", import.meta.url));
    // Every raw secret (challenge, keyId) must be routed through
    // hashWithPepper before it reaches a `sql\`...\`` template. We assert the
    // absence of the dangerous pattern: interpolating `challenge` or `keyId`
    // directly inside a tagged-template SQL call.
    const dangerousInterpolation = /sql`[^`]*\$\{\s*(challenge|keyId|params\.keyId|params\.challenge)\s*\}/s;
    assertEquals(
        dangerousInterpolation.test(source),
        false,
        "found a raw key_id/challenge interpolated directly into a SQL template -- must be hashed via hashWithPepper first",
    );
    assertEquals(source.includes("hashWithPepper"), true, "expected hashWithPepper to be used before persisting any secret");
});

Deno.test("guard: attested_devices upsert always supplies a hashed key_id_hash, never a raw key_id column", async () => {
    const source = await Deno.readTextFile(new URL("./pgRuntime.ts", import.meta.url));
    assertEquals(source.includes("keyIdHashHex"), true);
    assertEquals(source.includes("upsert_attested_device"), true);
    // The SQL call site must decode the *hash*, not the raw keyId, into the
    // key_id_hash column.
    const upsertCallMatch = source.match(/upsert_attested_device\(([\s\S]*?)\)\s*`/);
    assertEquals(upsertCallMatch !== null, true, "expected to find the upsert_attested_device call site");
    assertEquals(upsertCallMatch![1].includes("keyIdHashHex"), true);
    assertEquals(upsertCallMatch![1].includes("params.keyId"), false);
});

Deno.test("device-tokens redeem handler aborts a chunked body with no Content-Length once it passes the byte cap", async () => {
    const handler = createDeviceTokenRedeemHandler({
        checkRateLimit: unexpectedCall("checkRateLimit"),
        verifyAttestation: unexpectedCall("verifyAttestation"),
        redeemChallenge: unexpectedCall("redeemChallenge"),
        issueDeviceToken: unexpectedCall("issueDeviceToken"),
    });
    const { request, pulls } = endlessChunkedPost("http://localhost/functions/v1/device-tokens");

    const response = await handler(request);

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
    // 16 KiB chunks against a <= 256 KiB cap: the stream is cancelled after a
    // handful of chunks instead of being drained (10,000 chunks = ~160 MB).
    assertEquals(pulls() < 40, true);
});

// ── Review 2026-10-18: attestation gate, redeem rate limit, key_id charset ──

function redeemRequest(payload: Record<string, unknown>, headers: Record<string, string> = {}): Request {
    return new Request("http://localhost/functions/v1/device-tokens", {
        method: "POST",
        headers: { "content-type": "application/json", ...headers },
        body: JSON.stringify(payload),
    });
}

Deno.test("redeem handler rejects a non-Latin-1 key_id with 400 before consuming the challenge", async () => {
    let challengeConsumed = false;
    const handler = createDeviceTokenRedeemHandler({
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        verifyAttestation: createFakeVerifyAttestation(),
        redeemChallenge: async () => {
            challengeConsumed = true;
            return { ok: true };
        },
        issueDeviceToken: unexpectedCall("issueDeviceToken"),
    });

    const response = await handler(redeemRequest({ ...validRedeemPayload, key_id: "ключ-🔑" }));

    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error, "validation_failed");
    assertEquals(typeof body.field_errors.key_id, "string");
    assertEquals(challengeConsumed, false);
});

Deno.test("validateDeviceTokenRedeemPayload bounds key_id and challenge to base64-style strings", () => {
    for (
        const [field, value] of [
            ["key_id", "not base64!"],
            ["key_id", "a".repeat(513)],
            ["challenge", "has+plus"],
            ["challenge", "a".repeat(129)],
        ] as const
    ) {
        const result = validateDeviceTokenRedeemPayload({ ...validRedeemPayload, [field]: value });
        assertEquals(result.ok, false, `${field}=${value.slice(0, 20)}`);
    }
    assertEquals(validateDeviceTokenRedeemPayload({ ...validRedeemPayload, key_id: "ab+/cd==" }).ok, true);
});

Deno.test("fake verifier reports an unencodable key id as a failure instead of throwing", async () => {
    const verify = createFakeVerifyAttestation();
    const result = await verify("ios", { keyId: "ключ", attestationObject: "YQ", challenge: "Yw" });
    assertEquals(result, { ok: false, reason: "malformed_key_id" });
});

Deno.test("redeem handler returns 429 with Retry-After and never touches the challenge when IP-limited", async () => {
    let seenIp = "";
    const handler = makeRedeemHandler({
        checkRateLimit: async (ip) => {
            seenIp = ip;
            return { ok: false, retryAfterSeconds: 1200 };
        },
        redeemChallenge: unexpectedCall("redeemChallenge"),
        verifyAttestation: unexpectedCall("verifyAttestation"),
    });

    const response = await handler(redeemRequest(validRedeemPayload, { "x-forwarded-for": "203.0.113.44" }));

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "1200");
    assertEquals((await response.json()).error, "rate_limited");
    assertEquals(seenIp, "203.0.113.44");
});

Deno.test("createRedeemRateLimitChecker uses the device-token-redeem-ip prefix and 30/hr limit", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createRedeemRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: true as T, error: null };
        },
        () => new Date("2026-07-02T18:00:00Z"),
    );

    assertEquals(await checker("203.0.113.30"), { ok: true, retryAfterSeconds: 0 });
    assertEquals(calls[0].p_key, "device-token-redeem-ip:203.0.113.30");
    assertEquals(calls[0].p_limit, 30);
});

function withAttestationEnv(value: string | undefined, body: () => Promise<void>): Promise<void> {
    const previous = Deno.env.get("ATTESTATION_ENABLED");
    if (value === undefined) Deno.env.delete("ATTESTATION_ENABLED");
    else Deno.env.set("ATTESTATION_ENABLED", value);
    return body().finally(() => {
        if (previous === undefined) Deno.env.delete("ATTESTATION_ENABLED");
        else Deno.env.set("ATTESTATION_ENABLED", previous);
    });
}

Deno.test("attestationGate answers 503 attestation_disabled with Retry-After by default", () =>
    withAttestationEnv(undefined, async () => {
        const gated = attestationGate(unexpectedCall("enabled handler"));
        const response = await gated(
            new Request("http://localhost/functions/v1/device-tokens/challenge", {
                method: "POST",
                headers: { "x-request-id": "req-gate" },
            }),
            {},
        );
        assertEquals(response.status, 503);
        assertEquals(response.headers.get("Retry-After"), String(ATTESTATION_DISABLED_RETRY_AFTER_SECONDS));
        assertEquals(response.headers.get("x-request-id"), "req-gate");
        const body = await response.json();
        assertEquals(body.error, "attestation_disabled");
        assertEquals(body.retry_after_s, ATTESTATION_DISABLED_RETRY_AFTER_SECONDS);
    }));

Deno.test("attestationGate dispatches to the real handler when ATTESTATION_ENABLED=true", () =>
    withAttestationEnv("true", async () => {
        const gated = attestationGate(() => Promise.resolve(new Response("enabled", { status: 200 })));
        const response = await gated(new Request("http://localhost/x", { method: "POST" }), {});
        assertEquals(response.status, 200);
        assertEquals(await response.text(), "enabled");
    }));

Deno.test("attestationGate stays closed for values other than true", () =>
    withAttestationEnv("1", async () => {
        const gated = attestationGate(unexpectedCall("enabled handler"));
        const response = await gated(new Request("http://localhost/x", { method: "POST" }), {});
        assertEquals(response.status, 503);
    }));
