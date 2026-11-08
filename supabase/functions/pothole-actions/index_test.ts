import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import {
    createPotholeActionsHandler,
    extractClientIp,
    MAX_PAYLOAD_BYTES,
    validatePotholeActionPayload,
} from "./handler.ts";
import { createPotholeActionRateLimitChecker } from "./runtime.ts";
import type { RpcResponse } from "../upload-readings/runtime.ts";
import { endlessChunkedPost, unexpectedCall } from "../_shared/test_helpers.ts";

// Relative to the real clock: validation now bounds recorded_at to
// [now - 30 days, now + 5 minutes] (review N1).
const RECORDED_AT = new Date(Date.now() - 60_000).toISOString();
const SENSOR_BACKED_AT = new Date(Date.now() - 63_000).toISOString();

const validPayload = {
    action_id: "d89fe2a5-6b3f-4207-a592-5fe67bb4b6ff",
    device_token: "a78f9e2b-4c6d-41ec-81d3-0242ac130003",
    client_sent_at: "2026-04-21T18:22:05Z",
    client_app_version: "0.2.0 (78)",
    client_os_version: "iOS 17.4.1",
    action_type: "manual_report",
    pothole_report_id: null,
    lat: 44.6488,
    lng: -63.5752,
    accuracy_m: 6.8,
    recorded_at: RECORDED_AT,
} as const;

Deno.test("extractClientIp uses the last public forwarded hop before fallback headers", () => {
    const forwardedHeaders = new Headers({
        "x-forwarded-for": "203.0.113.7, 10.0.0.1",
        "x-real-ip": "198.51.100.10",
    });
    assertEquals(extractClientIp(forwardedHeaders), "203.0.113.7");

    const spoofedForwardedHeaders = new Headers({
        "x-forwarded-for": "8.8.8.8, 203.0.113.8",
    });
    assertEquals(extractClientIp(spoofedForwardedHeaders), "203.0.113.8");

    const realIpHeaders = new Headers({
        "x-real-ip": "198.51.100.10",
    });
    assertEquals(extractClientIp(realIpHeaders), "198.51.100.10");
});

Deno.test("extractClientIp prefers x-client-ip over x-forwarded-for only with valid origin auth", () => {
    const headers = new Headers({
        "x-client-ip": "1.2.3.4",
        "x-origin-auth": "worker-secret",
        "x-forwarded-for": "203.0.113.7, 198.51.100.99",
    });
    assertEquals(extractClientIp(headers, "worker-secret"), "1.2.3.4");
    // Same headers, no secret configured on the gateway: x-client-ip is spoofable, so ignored.
    assertEquals(extractClientIp(headers, ""), "198.51.100.99");
});

Deno.test("validatePotholeActionPayload rejects malformed payloads", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        action_type: "nope",
        lat: "bad",
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            action_type: "must be one of manual_report, confirm_present, confirm_fixed",
            lat: "must be numeric",
        });
    }
});

Deno.test("validatePotholeActionPayload requires pothole_report_id for follow-up actions", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        action_type: "confirm_fixed",
        pothole_report_id: null,
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.pothole_report_id, "must be a UUID string");
    }
});

Deno.test("validatePotholeActionPayload accepts sensor-backed manual severity", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        sensor_backed_magnitude_g: 2.6,
        sensor_backed_at: SENSOR_BACKED_AT,
    });

    assertEquals(result.ok, true);
    if (result.ok) {
        assertEquals(result.payload.sensor_backed_magnitude_g, 2.6);
        assertEquals(result.payload.sensor_backed_at, SENSOR_BACKED_AT);
    }
});

Deno.test("validatePotholeActionPayload rejects partial sensor-backed severity", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        sensor_backed_magnitude_g: 2.6,
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.sensor_backed, "magnitude and timestamp must be provided together");
    }
});

Deno.test("validatePotholeActionPayload rejects sensor-backed severity for follow-up actions", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        action_type: "confirm_present",
        pothole_report_id: "123e4567-e89b-12d3-a456-426614174000",
        sensor_backed_magnitude_g: 2.6,
        sensor_backed_at: SENSOR_BACKED_AT,
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.sensor_backed, "must be omitted for follow-up actions");
    }
});

Deno.test("pothole action handler returns 400 for invalid JSON", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "ignored",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => ({
            action_id: validPayload.action_id,
            pothole_report_id: "00000000-0000-0000-0000-000000001234",
            status: "active",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            body: "{",
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("pothole action handler returns 429 with Retry-After for rate limits", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: false, retryAfterSeconds: 1800 }),
        applyAction: async () => ({
            action_id: validPayload.action_id,
            pothole_report_id: "00000000-0000-0000-0000-000000001234",
            status: "active",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-request-id": "req-pothole-limit",
            },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "1800");
    assertEquals(response.headers.get("x-request-id"), "req-pothole-limit");
});

Deno.test("createPotholeActionRateLimitChecker uses pothole-action prefixes and limits, checking IP before device", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createPotholeActionRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: true as T, error: null };
        },
        () => new Date("2026-04-21T18:22:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(result, { ok: true, retryAfterSeconds: 0 });
    // P1-4: IP check must run (and be bumped) first.
    assertEquals(calls[0].p_key, "pothole-action-ip:203.0.113.10");
    assertEquals(calls[0].p_limit, 120);
    assertEquals(calls[1].p_key, "pothole-action-device:deadbeef");
    assertEquals(calls[1].p_limit, 60);
});

Deno.test("createPotholeActionRateLimitChecker short-circuits on IP limit without bumping device bucket", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createPotholeActionRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-21T18:22:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(calls.length, 1, "device bucket must not be bumped when the IP check already failed");
    assertEquals(calls[0].p_key, "pothole-action-ip:203.0.113.10");
    assertEquals(result.ok, false);
});

Deno.test("pothole action handler returns 200 on success", async () => {
    let seenHash = "";
    let seenIp = "";
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async (tokenHashHex, ip) => {
            seenHash = tokenHashHex;
            seenIp = ip;
            return { ok: true, retryAfterSeconds: 0 };
        },
        applyAction: async ({ payload, tokenHashHex }) => {
            assertEquals(tokenHashHex, "deadbeef");
            assertEquals(payload.action_type, "manual_report");
            assertEquals(payload.sensor_backed_magnitude_g, null);
            return {
                action_id: payload.action_id,
                pothole_report_id: "00000000-0000-0000-0000-000000001234",
                status: "active",
            };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-forwarded-for": "203.0.113.10, 10.0.0.1",
            },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(seenHash, "deadbeef");
    assertEquals(seenIp, "203.0.113.10");
    assertEquals(response.status, 200);
    assertObjectMatch(await response.json(), {
        action_id: validPayload.action_id,
        pothole_report_id: "00000000-0000-0000-0000-000000001234",
        status: "active",
    });
});

Deno.test("pothole action handler passes sensor-backed severity to applyAction", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async ({ payload }) => {
            assertEquals(payload.sensor_backed_magnitude_g, 2.6);
            assertEquals(payload.sensor_backed_at, SENSOR_BACKED_AT);
            return {
                action_id: payload.action_id,
                pothole_report_id: "00000000-0000-0000-0000-000000001234",
                status: "active",
            };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                sensor_backed_magnitude_g: 2.6,
                sensor_backed_at: SENSOR_BACKED_AT,
            }),
        }),
    );

    assertEquals(response.status, 200);
});

Deno.test("pothole action handler preserves duplicate action responses", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => ({
            action_id: validPayload.action_id,
            pothole_report_id: "00000000-0000-0000-0000-000000001234",
            status: "resolved",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 200);
    assertEquals((await response.json()).status, "resolved");
});

Deno.test("pothole action handler maps stale_target to 409", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => {
            throw new Error("stale_target");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                action_type: "confirm_present",
                pothole_report_id: "123e4567-e89b-12d3-a456-426614174000",
            }),
        }),
    );

    assertEquals(response.status, 409);
    assertEquals((await response.json()).error, "stale_target");
});

Deno.test("pothole action handler maps SQL recorded_at_out_of_window to 400", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => {
            throw new Error("recorded_at_out_of_window");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                action_type: "confirm_present",
                pothole_report_id: "123e4567-e89b-12d3-a456-426614174000",
            }),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

// ── P0-2: body-size cap + field whitelisting ──

Deno.test("pothole action handler rejects a payload with declared content-length over the limit before reading body", async () => {
    let applyCalled = false;
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => {
            applyCalled = true;
            return {
                action_id: validPayload.action_id,
                pothole_report_id: "00000000-0000-0000-0000-000000001234",
                status: "active",
            };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "content-length": String(MAX_PAYLOAD_BYTES + 1),
            },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
    assertEquals(applyCalled, false);
});

Deno.test("pothole action handler rejects an actual body larger than the cap even without a content-length header", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async () => ({
            action_id: validPayload.action_id,
            pothole_report_id: "00000000-0000-0000-0000-000000001234",
            status: "active",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                junk_padding: "x".repeat(MAX_PAYLOAD_BYTES + 1000),
            }),
        }),
    );

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
});

Deno.test("pothole action handler strips unexpected extra fields before they reach applyAction", async () => {
    let seenPayload: unknown;
    const handler = createPotholeActionsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        applyAction: async ({ payload }) => {
            seenPayload = payload;
            return {
                action_id: payload.action_id,
                pothole_report_id: "00000000-0000-0000-0000-000000001234",
                status: "active",
            };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-actions", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                malicious_field: "should be stripped",
                nested_junk: { a: 1, b: [1, 2, 3] },
            }),
        }),
    );

    assertEquals(response.status, 200);
    assertEquals("malicious_field" in (seenPayload as Record<string, unknown>), false);
    assertEquals("nested_junk" in (seenPayload as Record<string, unknown>), false);
});

Deno.test("validatePotholeActionPayload rejects overlong client_app_version/client_os_version", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        client_app_version: "x".repeat(101),
        client_os_version: "y".repeat(200),
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            client_app_version: "must be at most 100 characters",
            client_os_version: "must be at most 100 characters",
        });
    }
});

// ── P1-7: world-bounds validation ──

Deno.test("validatePotholeActionPayload rejects out-of-range lat/lng", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        lat: 91,
        lng: 181,
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            lat: "must be between -90 and 90",
            lng: "must be between -180 and 180",
        });
    }
});

Deno.test("validatePotholeActionPayload accepts boundary lat/lng values", () => {
    const result = validatePotholeActionPayload({
        ...validPayload,
        lat: -90,
        lng: -180,
    });

    assertEquals(result.ok, true);
});

Deno.test("pothole-actions handler aborts a chunked body with no Content-Length once it passes the byte cap", async () => {
    const handler = createPotholeActionsHandler({
        hashDeviceToken: unexpectedCall("hashDeviceToken"),
        checkRateLimit: unexpectedCall("checkRateLimit"),
        applyAction: unexpectedCall("applyAction"),
    });
    const { request, pulls } = endlessChunkedPost("http://localhost/functions/v1/pothole-actions");

    const response = await handler(request);

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
    // 16 KiB chunks against a <= 256 KiB cap: the stream is cancelled after a
    // handful of chunks instead of being drained (10,000 chunks = ~160 MB).
    assertEquals(pulls() < 40, true);
});

// ── Review N1: recorded_at window and accuracy bounds ──

Deno.test("validatePotholeActionPayload rejects recorded_at more than 5 minutes in the future", () => {
    const now = new Date("2026-11-08T12:00:00Z");
    const tooFar = validatePotholeActionPayload(
        { ...validPayload, recorded_at: "2099-01-01T00:00:00Z" },
        now,
    );
    assertEquals(tooFar.ok, false);
    if (!tooFar.ok) {
        assertEquals(tooFar.fieldErrors.recorded_at, "must not be more than 5 minutes in the future");
    }

    const justInside = validatePotholeActionPayload(
        { ...validPayload, recorded_at: "2026-11-08T12:04:59Z" },
        now,
    );
    assertEquals(justInside.ok, true);
});

Deno.test("validatePotholeActionPayload rejects recorded_at older than 30 days", () => {
    const now = new Date("2026-11-08T12:00:00Z");
    const stale = validatePotholeActionPayload(
        { ...validPayload, recorded_at: "2026-10-09T11:59:59Z" },
        now,
    );
    assertEquals(stale.ok, false);
    if (!stale.ok) {
        assertEquals(stale.fieldErrors.recorded_at, "must not be more than 30 days old");
    }

    const inside = validatePotholeActionPayload(
        { ...validPayload, recorded_at: "2026-10-10T12:00:00Z" },
        now,
    );
    assertEquals(inside.ok, true);
});

Deno.test("validatePotholeActionPayload applies the same window to sensor_backed_at", () => {
    const now = new Date("2026-11-08T12:00:00Z");
    const result = validatePotholeActionPayload(
        {
            ...validPayload,
            recorded_at: "2026-11-08T11:59:00Z",
            sensor_backed_magnitude_g: 2.1,
            sensor_backed_at: "2099-01-01T00:00:00Z",
        },
        now,
    );
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.sensor_backed_at, "must not be more than 5 minutes in the future");
    }
});

Deno.test("validatePotholeActionPayload rejects lenient timestamps Date.parse would accept", () => {
    for (const recorded_at of ["0", "2026-11-08", "Nov 8 2026"]) {
        const result = validatePotholeActionPayload({ ...validPayload, recorded_at });
        assertEquals(result.ok, false, recorded_at);
        if (!result.ok) assertEquals(result.fieldErrors.recorded_at, "must be an RFC3339 timestamp");
    }
});

Deno.test("validatePotholeActionPayload bounds accuracy_m to [0, 500]", () => {
    for (const accuracy_m of [-1, 500.01, 5000]) {
        const result = validatePotholeActionPayload({ ...validPayload, accuracy_m });
        assertEquals(result.ok, false, String(accuracy_m));
        if (!result.ok) assertEquals(result.fieldErrors.accuracy_m, "must be between 0 and 500");
    }
    for (const accuracy_m of [0, 500, null]) {
        assertEquals(validatePotholeActionPayload({ ...validPayload, accuracy_m }).ok, true, String(accuracy_m));
    }
});

Deno.test("createPotholeActionRateLimitChecker keys IPv6 clients on their /64", async () => {
    const keys: unknown[] = [];
    const checker = createPotholeActionRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            keys.push(params.p_key);
            return { data: true as T, error: null };
        },
        () => new Date("2026-11-08T15:30:00Z"),
    );

    await checker("deadbeef", "2001:db8:abcd:12:1111:2222:3333:4444");
    await checker("deadbeef", "2001:db8:abcd:12::9");

    assertEquals(keys.filter((key) => key === "pothole-action-ip:2001:db8:abcd:12::/64").length, 2);
});
