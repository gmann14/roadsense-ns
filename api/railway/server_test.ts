import { assertEquals } from "jsr:@std/assert";
import { createRailwayApp } from "./server.ts";

function makeDb() {
  return {
    query: (sql: string) => {
      if (sql.includes("public_stats_mv")) {
        return Promise.resolve({
          rows: [{
            total_km_mapped: 1,
            total_readings: 2,
            segments_scored: 3,
            active_potholes: 4,
            municipalities_covered: 1,
            generated_at: "2026-05-13T00:00:00Z",
          }],
        });
      }
      return Promise.resolve({ rows: [] });
    },
    checkAndBumpRateLimit: () => Promise.resolve(true),
    ingestReadingBatch: () => Promise.resolve({ accepted: 1, rejected: 0, duplicate: false, rejected_reasons: {} }),
    applyPotholeAction: () =>
      Promise.resolve({
        action_id: "12345678-1234-4123-8123-123456789abc",
        pothole_report_id: "12345678-1234-4123-8123-123456789abd",
        status: "active",
      }),
    findPhoto: () => Promise.resolve(null),
    createPendingPhoto: () => Promise.resolve(),
    objectExists: () => Promise.resolve(false),
    storeUpload: () => Promise.resolve(),
    getPhotoBlob: (reportID: string) => {
      if (reportID !== "12345678-1234-4123-8123-123456789abc") return Promise.resolve(null);
      return Promise.resolve({
        status: "pending_moderation",
        contentType: "image/jpeg",
        imageBytes: new Uint8Array([1, 2, 3]),
      });
    },
  };
}

Deno.test("Railway app registers pothole photo metadata route instead of returning 404", async () => {
  Deno.env.set("TOKEN_PEPPER", "test-pepper");
  const app = createRailwayApp(makeDb() as never, {
    publicApiKey: "test-key",
    publicBaseURL: "https://api.example.test",
    uploadSigningSecret: "secret",
  });

  const response = await app(
    new Request("https://api.example.test/functions/v1/pothole-photos", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: "test-key",
      },
      body: JSON.stringify({
        report_id: "12345678-1234-4123-8123-123456789abc",
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
      }),
    }),
  );

  assertEquals(response.status, 200);
});

Deno.test("Railway app returns a signed photo blob URL usable without API headers", async () => {
  const app = createRailwayApp(makeDb() as never, {
    publicApiKey: "test-key",
    publicBaseURL: "https://api.example.test",
    uploadSigningSecret: "secret",
  });

  const metadataResponse = await app(
    new Request(
      "https://api.example.test/functions/v1/pothole-photo-image?report_id=12345678-1234-4123-8123-123456789abc",
      {
        method: "GET",
        headers: { apikey: "test-key" },
      },
    ),
  );

  assertEquals(metadataResponse.status, 200);
  const metadata = await metadataResponse.json();
  const signedURL = new URL(metadata.signed_url);
  assertEquals(signedURL.searchParams.has("token"), true);

  const forbiddenResponse = await app(
    new Request(
      "https://api.example.test/functions/v1/pothole-photo-blob/12345678-1234-4123-8123-123456789abc",
      { method: "GET" },
    ),
  );
  assertEquals(forbiddenResponse.status, 403);

  const blobResponse = await app(new Request(signedURL, { method: "GET" }));
  assertEquals(blobResponse.status, 200);
  assertEquals(blobResponse.headers.get("content-type"), "image/jpeg");
  assertEquals(new Uint8Array(await blobResponse.arrayBuffer()), new Uint8Array([1, 2, 3]));
});
