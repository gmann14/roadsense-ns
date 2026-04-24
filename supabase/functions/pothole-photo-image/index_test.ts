import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import { createPotholePhotoImageHandler } from "./handler.ts";

Deno.test("pothole photo image handler requires internal auth", async () => {
    const handler = createPotholePhotoImageHandler({
        authorize: () => false,
        getPhoto: async () => null,
        createSignedReadURL: async () => "https://example.com/signed.jpg",
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-image?report_id=00000000-0000-4000-8000-000000002101"));

    assertEquals(response.status, 401);
});

Deno.test("pothole photo image handler validates report_id", async () => {
    const handler = createPotholePhotoImageHandler({
        authorize: () => true,
        getPhoto: async () => null,
        createSignedReadURL: async () => "https://example.com/signed.jpg",
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-image?report_id=bad-id"));

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("pothole photo image handler returns signed URLs for moderation-visible photos", async () => {
    const calls: Array<{ path: string; expiresInSeconds: number }> = [];
    const handler = createPotholePhotoImageHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002101",
            status: "pending_moderation",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002101.jpg",
        }),
        createSignedReadURL: async (path, expiresInSeconds) => {
            calls.push({ path, expiresInSeconds });
            return "https://example.com/signed.jpg";
        },
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-image?report_id=00000000-0000-4000-8000-000000002101"));

    assertEquals(response.status, 200);
    assertEquals(calls, [{
        path: "pending/00000000-0000-4000-8000-000000002101.jpg",
        expiresInSeconds: 60,
    }]);
    assertObjectMatch(await response.json(), {
        report_id: "00000000-0000-4000-8000-000000002101",
        status: "pending_moderation",
        signed_url: "https://example.com/signed.jpg",
        expires_in_s: 60,
    });
});

Deno.test("pothole photo image handler rejects non-visible moderation states", async () => {
    const handler = createPotholePhotoImageHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "rejected",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002103.jpg",
        }),
        createSignedReadURL: async () => "https://example.com/signed.jpg",
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-image?report_id=00000000-0000-4000-8000-000000002103"));

    assertEquals(response.status, 409);
    assertEquals((await response.json()).error, "invalid_photo_state");
});
