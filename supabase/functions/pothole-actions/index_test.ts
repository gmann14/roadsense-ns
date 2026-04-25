import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import { createPotholeActionsHandler, extractClientIp, validatePotholeActionPayload } from "./handler.ts";
import { createPotholeActionRateLimitChecker } from "./runtime.ts";
import type { RpcResponse } from "../upload-readings/runtime.ts";

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
    recorded_at: "2026-04-21T18:22:00Z",
} as const;

Deno.test("extractClientIp prefers x-forwarded-for then x-real-ip", () => {
    const forwardedHeaders = new Headers({
        "x-forwarded-for": "203.0.113.7, 10.0.0.1",
        "x-real-ip": "198.51.100.10",
    });
    assertEquals(extractClientIp(forwardedHeaders), "203.0.113.7");

    const realIpHeaders = new Headers({
        "x-real-ip": "198.51.100.10",
    });
    assertEquals(extractClientIp(realIpHeaders), "198.51.100.10");
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
        sensor_backed_at: "2026-04-21T18:21:57Z",
    });

    assertEquals(result.ok, true);
    if (result.ok) {
        assertEquals(result.payload.sensor_backed_magnitude_g, 2.6);
        assertEquals(result.payload.sensor_backed_at, "2026-04-21T18:21:57Z");
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
        sensor_backed_at: "2026-04-21T18:21:57Z",
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

Deno.test("createPotholeActionRateLimitChecker uses pothole-action prefixes and limits", async () => {
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
    assertEquals(calls[0].p_key, "pothole-action-device:deadbeef");
    assertEquals(calls[0].p_limit, 60);
    assertEquals(calls[1].p_key, "pothole-action-ip:203.0.113.10");
    assertEquals(calls[1].p_limit, 120);
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
            assertEquals(payload.sensor_backed_at, "2026-04-21T18:21:57Z");
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
                sensor_backed_at: "2026-04-21T18:21:57Z",
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
