import { assertEquals, assertMatch } from "jsr:@std/assert";
import { createPotholePhotoHandlers, type PhotoRepository, type StoredPhotoMetadata, testing } from "./photo.ts";
import type { PotholePhotoPayload } from "../../supabase/functions/pothole-photos/handler.ts";

function validPayload(overrides: Partial<PotholePhotoPayload> = {}): PotholePhotoPayload {
  return {
    report_id: "12345678-1234-4123-8123-123456789abc",
    segment_id: null,
    device_token: "12345678-1234-4123-8123-123456789abd",
    client_sent_at: "2026-05-13T12:00:00.000Z",
    client_app_version: "0.1.0 (5)",
    client_os_version: "iOS 26.4.2",
    lat: 44.6488,
    lng: -63.5752,
    accuracy_m: 5,
    captured_at: "2026-05-13T11:59:00.000Z",
    content_type: "image/jpeg",
    byte_size: 4,
    sha256: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a",
    ...overrides,
  };
}

function makeRepository() {
  const photos = new Map<string, StoredPhotoMetadata>();
  const uploads = new Map<string, Uint8Array>();
  const created: Array<{ payload: PotholePhotoPayload; tokenHashHex: string; objectPath: string }> = [];

  const repo: PhotoRepository = {
    findPhoto: (reportID) => Promise.resolve(photos.get(reportID) ?? null),
    createPendingPhoto: (payload, tokenHashHex, objectPath) => {
      created.push({ payload, tokenHashHex, objectPath });
      photos.set(payload.report_id, {
        report_id: payload.report_id,
        status: "pending_upload",
        storage_object_path: objectPath,
        content_sha256: payload.sha256,
        byte_size: payload.byte_size,
        content_type: payload.content_type,
      });
      return Promise.resolve();
    },
    objectExists: (objectPath) => Promise.resolve(uploads.has(objectPath)),
    storeUpload: ({ reportID, objectPath, bytes }) => {
      uploads.set(objectPath, bytes);
      const existing = photos.get(reportID);
      if (existing) {
        photos.set(reportID, { ...existing, status: "pending_moderation" });
      }
      return Promise.resolve();
    },
  };

  return { repo, photos, uploads, created };
}

Deno.test("Railway photo metadata route issues an API-local signed upload URL", async () => {
  const { repo, created } = makeRepository();
  const handlers = createPotholePhotoHandlers({
    publicApiBaseURL: "https://api.example.test",
    signingSecret: "secret",
    hashDeviceToken: async () => "hashhex",
    checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
    photoRepository: repo,
  });

  const response = await handlers.handleMetadata(
    new Request("https://api.example.test/functions/v1/pothole-photos", {
      method: "POST",
      body: JSON.stringify(validPayload()),
      headers: { "content-type": "application/json" },
    }),
  );

  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(created.length, 1);
  assertEquals(created[0].objectPath, "pending/12345678-1234-4123-8123-123456789abc.jpg");
  assertMatch(
    body.upload_url,
    /^https:\/\/api\.example\.test\/functions\/v1\/pothole-photo-upload\/12345678-1234-4123-8123-123456789abc\?token=/,
  );
});

Deno.test("Railway photo upload stores bytes and moves the photo to moderation", async () => {
  const { repo, photos, uploads } = makeRepository();
  const handlers = createPotholePhotoHandlers({
    publicApiBaseURL: "https://api.example.test",
    signingSecret: "secret",
    hashDeviceToken: async () => "hashhex",
    checkRateLimit: async () => ({ ok: true, retryAfterSeconds: 0 }),
    photoRepository: repo,
  });
  const payload = validPayload();
  await repo.createPendingPhoto(payload, "hashhex", "pending/12345678-1234-4123-8123-123456789abc.jpg");
  const token = await testing.signedUploadToken(
    payload.report_id,
    "pending/12345678-1234-4123-8123-123456789abc.jpg",
    "secret",
  );

  const response = await handlers.handleUpload(
    new Request(`https://api.example.test/functions/v1/pothole-photo-upload/${payload.report_id}?token=${token}`, {
      method: "PUT",
      body: new Uint8Array([1, 2, 3, 4]),
      headers: { "content-type": "image/jpeg" },
    }),
    payload.report_id,
  );

  assertEquals(response.status, 200);
  assertEquals(uploads.get("pending/12345678-1234-4123-8123-123456789abc.jpg")?.byteLength, 4);
  assertEquals(photos.get(payload.report_id)?.status, "pending_moderation");
});
