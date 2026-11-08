import { assertEquals, assertMatch, assertObjectMatch } from "jsr:@std/assert";
import {
    createUploadReadingsHandler,
    extractClientIp,
    MAX_PAYLOAD_BYTES,
    maxPotholeReadingsForBatch,
    validateUploadPayload,
} from "./handler.ts";
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

Deno.test("extractClientIp prefers the worker-trusted x-client-ip over x-forwarded-for", () => {
    // Regression for the shared-egress-IP bug: through the Cloudflare worker,
    // the rightmost public entry in x-forwarded-for is Cloudflare's own egress
    // IP, not the real client. x-client-ip is set by our worker from its own
    // cf-connecting-ip and must win -- but only when the request also proves
    // it came through the worker (x-origin-auth, review P0-4).
    const headers = new Headers({
        "x-client-ip": "1.2.3.4",
        "x-origin-auth": "worker-secret",
        "x-forwarded-for": "203.0.113.7, 198.51.100.99",
    });
    assertEquals(extractClientIp(headers, "worker-secret"), "1.2.3.4");
});

Deno.test("extractClientIp ignores a private/malformed x-client-ip and falls back", () => {
    const privateIp = new Headers({
        "x-client-ip": "10.0.0.5",
        "x-origin-auth": "worker-secret",
        "x-forwarded-for": "203.0.113.7, 10.0.0.1",
    });
    assertEquals(extractClientIp(privateIp, "worker-secret"), "203.0.113.7");

    const malformed = new Headers({
        "x-client-ip": "not-an-ip",
        "x-origin-auth": "worker-secret",
        "x-real-ip": "198.51.100.10",
    });
    assertEquals(extractClientIp(malformed, "worker-secret"), "198.51.100.10");
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

Deno.test("validateUploadPayload rejects forged out-of-range pothole_magnitude", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], is_pothole: true, pothole_magnitude: 50 },
            { ...validPayload.readings[0], is_pothole: false, pothole_magnitude: -0.5 },
        ],
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            "readings[0].pothole_magnitude": "must be between 0 and 8",
            "readings[1].pothole_magnitude": "must be between 0 and 8",
        });
    }
});

Deno.test("validateUploadPayload rejects physically impossible speeds", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], speed_kmh: 300 },
            { ...validPayload.readings[0], speed_kmh: -5 },
        ],
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            "readings[0].speed_kmh": "must be between 0 and 220",
            "readings[1].speed_kmh": "must be between 0 and 220",
        });
    }
});

Deno.test("validateUploadPayload rejects is_pothole=true below the detector spike threshold", () => {
    const belowThreshold = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], is_pothole: true, pothole_magnitude: 0.4 },
        ],
    });

    assertEquals(belowThreshold.ok, false);
    if (!belowThreshold.ok && belowThreshold.error === "validation_failed") {
        assertObjectMatch(belowThreshold.fieldErrors ?? {}, {
            "readings[0].pothole_magnitude": "must be at least 1 when is_pothole is true",
        });
    }

    const missingMagnitude = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], is_pothole: true, pothole_magnitude: null },
        ],
    });

    assertEquals(missingMagnitude.ok, false);
    if (!missingMagnitude.ok && missingMagnitude.error === "validation_failed") {
        assertObjectMatch(missingMagnitude.fieldErrors ?? {}, {
            "readings[0].pothole_magnitude": "must be numeric when is_pothole is true",
        });
    }
});

Deno.test("validateUploadPayload rejects an all-pothole batch", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: Array.from({ length: 40 }, () => ({
            ...validPayload.readings[0],
            is_pothole: true,
            pothole_magnitude: 2.4,
        })),
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            readings: "too many pothole-flagged readings (40 of 40; max 10)",
        });
    }
});

Deno.test("validateUploadPayload accepts realistic pothole readings and boundary values", () => {
    const flagged = {
        ...validPayload.readings[0],
        is_pothole: true,
        pothole_magnitude: 1.0,
    };
    const result = validateUploadPayload({
        ...validPayload,
        readings: [
            ...Array.from({ length: 17 }, () => validPayload.readings[0]),
            { ...flagged, pothole_magnitude: 8 },
            { ...flagged, speed_kmh: 220 },
            { ...flagged, speed_kmh: 0, is_pothole: false, pothole_magnitude: null },
        ],
    });

    assertEquals(result.ok, true);
});

Deno.test("maxPotholeReadingsForBatch keeps a flat floor for small batches", () => {
    assertEquals(maxPotholeReadingsForBatch(4), 5);
    assertEquals(maxPotholeReadingsForBatch(20), 5);
    assertEquals(maxPotholeReadingsForBatch(40), 10);
    assertEquals(maxPotholeReadingsForBatch(1000), 250);
});

Deno.test("upload handler rejects a forged max-severity batch end to end", async () => {
    let ingestCalled = false;
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => {
            ingestCalled = true;
            return { accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                readings: Array.from({ length: 100 }, () => ({
                    ...validPayload.readings[0],
                    speed_kmh: 50,
                    is_pothole: true,
                    pothole_magnitude: 99.99,
                })),
            }),
        }),
    );

    assertEquals(response.status, 400);
    const body = await response.json();
    assertEquals(body.error, "validation_failed");
    assertMatch(body.field_errors["readings[0].pothole_magnitude"], /between 0 and 8/);
    assertMatch(body.field_errors.readings, /too many pothole-flagged readings/);
    assertEquals(ingestCalled, false);
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

// P1-4: IP check runs first and short-circuits before the device check/bump,
// so a client already over the IP limit can't keep inserting rate_limits
// rows by rotating device tokens.

Deno.test("createRateLimitChecker checks IP before device and short-circuits on IP limit", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-18T15:30:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(calls.length, 1, "device bucket must not be bumped when the IP check already failed");
    assertEquals(calls[0].p_key, "ip:203.0.113.10");
    assertEquals(result, { ok: false, retryAfterSeconds: 1800 });
});

Deno.test("createRateLimitChecker returns day-boundary retry for device caps once IP passes", async () => {
    let call = 0;
    const checker = createRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            call += 1;
            if (call === 1) {
                assertEquals(params.p_key, "ip:203.0.113.10");
                return { data: true as T, error: null };
            }

            assertEquals(params.p_key, "dev:deadbeef");
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-18T15:30:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(call, 2);
    assertEquals(result, { ok: false, retryAfterSeconds: 30600 });
});

Deno.test("createRateLimitChecker allows the request through once both IP and device checks pass", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: true as T, error: null };
        },
        () => new Date("2026-04-18T15:30:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(calls.map((c) => c.p_key), ["ip:203.0.113.10", "dev:deadbeef"]);
    assertEquals(result, { ok: true, retryAfterSeconds: 0 });
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

// ── P0-2: body-size cap + field whitelisting ──

Deno.test("upload handler rejects a payload with declared content-length over the limit before reading body", async () => {
    let ingestCalled = false;
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => {
            ingestCalled = true;
            return { accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
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
    assertEquals(ingestCalled, false);
});

Deno.test("upload handler rejects an actual body larger than the cap even without a content-length header", async () => {
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async () => ({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    });

    const oversizedReadings = Array.from({ length: 900 }, () => ({
        ...validPayload.readings[0],
        junk_padding: "x".repeat(400),
    }));

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ ...validPayload, readings: oversizedReadings }),
        }),
    );

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
});

Deno.test("upload handler strips unexpected extra fields from readings before they reach ingestBatch", async () => {
    let seenPayload: unknown;
    const handler = createUploadReadingsHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        ingestBatch: async ({ payload }) => {
            seenPayload = payload;
            return { accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} };
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/upload-readings", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                ...validPayload,
                unexpected_top_level: "should be stripped",
                readings: [
                    {
                        ...validPayload.readings[0],
                        malicious_field: "x".repeat(1000),
                        nested_junk: { a: 1, b: [1, 2, 3] },
                    },
                ],
            }),
        }),
    );

    assertEquals(response.status, 200);
    const readings = (seenPayload as { readings: Array<Record<string, unknown>> }).readings;
    assertEquals(readings.length, 1);
    assertEquals("malicious_field" in readings[0], false);
    assertEquals("nested_junk" in readings[0], false);
    assertEquals("unexpected_top_level" in (seenPayload as Record<string, unknown>), false);
    assertObjectMatch(readings[0], {
        lat: validPayload.readings[0].lat,
        lng: validPayload.readings[0].lng,
        roughness_rms: validPayload.readings[0].roughness_rms,
        speed_kmh: validPayload.readings[0].speed_kmh,
    });
});

Deno.test("validateUploadPayload rejects overlong client_app_version/client_os_version", () => {
    const result = validateUploadPayload({
        ...validPayload,
        client_app_version: "x".repeat(101),
        client_os_version: "y".repeat(200),
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            client_app_version: "must be at most 100 characters",
            client_os_version: "must be at most 100 characters",
        });
    }
});

// ── P1-7: world-bounds validation ──

Deno.test("validateUploadPayload rejects out-of-range lat/lng", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], lat: 91, lng: -63.5752 },
            { ...validPayload.readings[0], lat: 44.6488, lng: 181 },
            { ...validPayload.readings[0], lat: -91, lng: -181 },
        ],
    });

    assertEquals(result.ok, false);
    if (!result.ok && result.error === "validation_failed") {
        assertObjectMatch(result.fieldErrors ?? {}, {
            "readings[0].lat": "must be between -90 and 90",
            "readings[1].lng": "must be between -180 and 180",
            "readings[2].lat": "must be between -90 and 90",
            "readings[2].lng": "must be between -180 and 180",
        });
    }
});

Deno.test("validateUploadPayload accepts boundary lat/lng values", () => {
    const result = validateUploadPayload({
        ...validPayload,
        readings: [
            { ...validPayload.readings[0], lat: 90, lng: 180 },
            { ...validPayload.readings[0], lat: -90, lng: -180 },
        ],
    });

    assertEquals(result.ok, true);
});
