import { assertEquals, assertMatch, assertObjectMatch } from "jsr:@std/assert";
import { createPotholePhotosHandler, validatePotholePhotoPayload } from "./handler.ts";
import { createPotholePhotoRateLimitChecker } from "./runtime.ts";
import type { RpcResponse } from "../upload-readings/runtime.ts";

const validPayload = {
    report_id: "c2f1a4b3-1234-4c5d-8e9f-112233445566",
    device_token: "a78f9e2b-4c6d-41ec-81d3-0242ac130003",
    client_sent_at: "2026-04-21T18:22:05Z",
    client_app_version: "0.2.0 (78)",
    client_os_version: "iOS 17.4.1",
    lat: 44.6488,
    lng: -63.5752,
    accuracy_m: 6.8,
    captured_at: "2026-04-21T18:22:00Z",
    content_type: "image/jpeg",
    byte_size: 312840,
    sha256: "9b74c9897bac770ffc029102a200c5de21f6b0cbde9b7d1d7c7a8c04f8e0f7d5",
} as const;

Deno.test("validatePotholePhotoPayload rejects malformed payloads", () => {
    const result = validatePotholePhotoPayload({
        ...validPayload,
        content_type: "image/png",
        sha256: "nope",
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            content_type: "must be image/jpeg",
            sha256: "must be a lowercase SHA-256 hex string",
        });
    }
});

Deno.test("createPotholePhotoRateLimitChecker uses pothole-photo prefixes and limits", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createPotholePhotoRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: true as T, error: null };
        },
        () => new Date("2026-04-21T18:22:00Z"),
    );

    const result = await checker("deadbeef", "203.0.113.10");

    assertEquals(result, { ok: true, retryAfterSeconds: 0 });
    assertEquals(calls[0].p_key, "pothole-photo-device:deadbeef");
    assertEquals(calls[0].p_limit, 20);
    assertEquals(calls[1].p_key, "pothole-photo-ip:203.0.113.10");
    assertEquals(calls[1].p_limit, 40);
});

Deno.test("pothole photo handler returns 200 with signed upload payload", async () => {
    const handler = createPotholePhotosHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        prepareUpload: async () => ({
            kind: "ready",
            report_id: validPayload.report_id,
            upload_url: "https://example.supabase.co/storage/v1/object/upload/sign/pothole-photos/pending/test.jpg?token=abc",
            upload_expires_at: "2026-04-21T20:22:05Z",
            expected_object_path: "pending/test.jpg",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-photos", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.report_id, validPayload.report_id);
    assertMatch(body.upload_url, /^https:\/\/example\.supabase\.co\//);
    assertEquals(body.expected_object_path, "pending/test.jpg");
});

Deno.test("pothole photo handler returns 409 after already uploaded", async () => {
    const handler = createPotholePhotosHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        prepareUpload: async () => ({ kind: "already_uploaded" }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-photos", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 409);
    assertEquals((await response.json()).error, "already_uploaded");
});

Deno.test("pothole photo handler returns 400 for content sha mismatch", async () => {
    const handler = createPotholePhotosHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
        prepareUpload: async () => {
            throw new Error("content_sha_mismatch");
        },
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-photos", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "content_sha_mismatch");
});

Deno.test("pothole photo handler returns 429 with Retry-After", async () => {
    const handler = createPotholePhotosHandler({
        hashDeviceToken: async () => "deadbeef",
        checkRateLimit: async () => ({ ok: false, retryAfterSeconds: 1800 }),
        prepareUpload: async () => ({
            kind: "ready",
            report_id: validPayload.report_id,
            upload_url: "https://example.invalid",
            upload_expires_at: "2026-04-21T20:22:05Z",
            expected_object_path: "pending/test.jpg",
        }),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/pothole-photos", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "1800");
});
