import { assertEquals, assertMatch, assertObjectMatch } from "jsr:@std/assert";
import { createUploadReadingsHandler, extractClientIp, validateUploadPayload } from "./handler.ts";
import { createRateLimitChecker, type RpcResponse } from "./runtime.ts";

const validPayload = {
    batch_id: "b5f6a3c2-8e10-4d1f-9a7b-0e2c6d4f8a31",
    device_token: "a78f9e2b-4c6d-41ec-81d3-0242ac130003",
    client_sent_at: "2026-04-17T14:30:00Z",
    client_app_version: "0.1.3 (42)",
    client_os_version: "iOS 17.4.1",
    readings: [
        {
            lat: 44.6488,
            lng: -63.5752,
            roughness_rms: 0.47,
            speed_kmh: 62.3,
            heading: 184.5,
            gps_accuracy_m: 6.5,
            recorded_at: "2026-04-17T14:28:14.321Z",
            is_pothole: false,
            pothole_magnitude: null,
        },
    ],
};

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

Deno.test("validateUploadPayload rejects malformed payloads", () => {
    const result = validateUploadPayload({
        ...validPayload,
        device_token: "not-a-uuid",
        readings: [
            {
                ...validPayload.readings[0],
                roughness_rms: "bad",
            },
        ],
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            device_token: "must be a UUIDv4 string",
            "readings[0].roughness_rms": "must be numeric",
        });
    }
});

Deno.test("validateUploadPayload returns batch_too_large for >1000 readings", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: Array.from({ length: 1001 }, () => validPayload.readings[0]),
    });

    assertEquals(result, { ok: false, error: "batch_too_large" });
});

Deno.test("upload handler returns 400 for invalid JSON", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "ignored",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            body: "{",
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("upload handler returns batch_too_large when readings exceed 1000", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "ignored",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                readings: Array.from({ length: 1001 }, () => validPayload.readings[0]),
            }),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "batch_too_large");
});

Deno.test("upload handler returns 429 with Retry-After for device rate limits", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "abc123",
        checkRateLimit: async () => ({ ok: false, retryAfterSeconds: 3600 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-request-id": "req-device-limit",
            },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "3600");
    assertEquals(response.headers.get("x-request-id"), "req-device-limit");
    assertEquals((await response.json()).retry_after_s, 3600);
});

Deno.test("createRateLimitChecker returns day-boundary retry for device caps", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-18T15:30:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(calls.length, 1);
    assertEquals(calls[0].p_key, "dev:deadbeef");
    assertEquals(result, { ok: false, retryAfterSeconds: 30600 });
});

Deno.test("createRateLimitChecker returns hour-boundary retry for IP caps", async () => {
    let call = 0;
    const checker = createRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            call += 1;
            if (call === 1) {
                assertEquals(params.p_key, "dev:deadbeef");
                return { data: true as T, error: null };
            }

            assertEquals(params.p_key, "ip:203.0.113.10");
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-18T15:30:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(result, { ok: false, retryAfterSeconds: 1800 });
});

Deno.test("upload handler passes x-forwarded-for into the limiter and returns 200", async () => {
    let seenIp = "";
    let seenHash = "";

    const handler = createUploadReadingsHandler({
        hashDeviceToken: async (deviceToken) => {
            assertEquals(deviceToken, validPayload.device_token);
            return "deadbeef";
        },
        checkRateLimit: async (tokenHashHex, ip) => {
            seenHash = tokenHashHex;
            seenIp = ip;
            return { ok: true, retryAfterSeconds: 0 };
        },
        ingestBatch: async ({ payload, tokenHashHex }) => {
            assertEquals(payload.batch_id, validPayload.batch_id);
            assertEquals(tokenHashHex, "deadbeef");
            return {
                accepted: 48,
                rejected: 2,
                duplicate: false,
                rejected_reasons: { out_of_bounds: 1, no_segment_match: 1 },
            };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
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

    const body = await response.json();
    assertObjectMatch(body, {
        batch_id: validPayload.batch_id,
        accepted: 48,
        rejected: 2,
        duplicate: false,
        rejected_reasons: {
            out_of_bounds: 1,
            no_segment_match: 1,
        },
    });
});

Deno.test("upload handler preserves duplicate responses from ingest", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({
            accepted: 10,
            rejected: 0,
            duplicate: true,
            rejected_reasons: {},
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 200);
    assertEquals((await response.json()).duplicate, true);
});

Deno.test("upload handler returns 502 when ingest fails", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => {
            throw new Error("boom");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 502);
    assertEquals((await response.json()).error, "processing_failed");
});

Deno.test("upload handler returns 503 when hashing or rate limiting fails", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => {
            throw new Error("missing pepper");
        },
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});

Deno.test("upload handler returns 405 for unsupported methods", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/upload-readings"));
    assertEquals(response.status, 405);
});

Deno.test("validation_failed includes field errors and request id", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-request-id": "req-invalid",
            },
            body: JSON.stringify({
                ...validPayload,
                device_token: "bad-token",
            }),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals(response.headers.get("x-request-id"), "req-invalid");

    const body = await response.json();
    assertEquals(body.error, "validation_failed");
    assertMatch(body.field_errors.device_token, /UUIDv4/);
});
