import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  getPotholes,
  getPublicStats,
  getSegmentDetail,
  getTopPotholes,
  normalizeBbox,
} from "@/lib/api/client";

const ORIGINAL_API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL;
const ORIGINAL_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const ORIGINAL_ALLOW_API_FETCHES = process.env.ROADSENSE_ALLOW_API_FETCHES_IN_TEST;

function restoreEnv(name: string, value: string | undefined) {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

beforeEach(() => {
  process.env.NEXT_PUBLIC_API_BASE_URL = "https://test.local/functions/v1";
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon.test-key";
  process.env.ROADSENSE_ALLOW_API_FETCHES_IN_TEST = "true";
});

afterEach(() => {
  restoreEnv("NEXT_PUBLIC_API_BASE_URL", ORIGINAL_API_BASE);
  restoreEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", ORIGINAL_ANON_KEY);
  restoreEnv("ROADSENSE_ALLOW_API_FETCHES_IN_TEST", ORIGINAL_ALLOW_API_FETCHES);
  vi.unstubAllGlobals();
});

function jsonResponse(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("read API client", () => {
  it("loads public stats from the Deno stats endpoint", async () => {
    const stats = {
      total_km_mapped: 12.4,
      total_readings: 31,
      segments_scored: 9,
      active_potholes: 4,
      municipalities_covered: 2,
      map_bounds: null,
      focus_bounds: null,
      pothole_bounds: null,
      generated_at: "2026-04-28T15:00:00Z",
    };
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(200, stats));
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPublicStats()).resolves.toEqual({ ...stats, data_updated_at: null });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://test.local/functions/v1/stats");
    const headers = init?.headers as Record<string, string>;
    expect(headers.apikey).toBe("anon.test-key");
  });

  it("normalizes alternate stats bounds key casing before map initialization", async () => {
    const stats = {
      total_km_mapped: "12.4",
      total_readings: "31",
      segments_scored: "9",
      active_potholes: "4",
      municipalities_covered: "2",
      map_bounds: {
        min_lng: "-64.34",
        min_lat: "44.37",
        max_lng: "-64.31",
        max_lat: "44.41",
      },
      focus_bounds: {
        min_lng: "-64.33",
        min_lat: "44.38",
        max_lng: "-64.32",
        max_lat: "44.40",
      },
      pothole_bounds: null,
      generated_at: "2026-04-28T15:00:00Z",
    };
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(200, stats));
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPublicStats()).resolves.toMatchObject({
      total_km_mapped: 12.4,
      total_readings: 31,
      segments_scored: 9,
      active_potholes: 4,
      municipalities_covered: 2,
      map_bounds: {
        minLng: -64.34,
        minLat: 44.37,
        maxLng: -64.31,
        maxLat: 44.41,
      },
      focus_bounds: {
        minLng: -64.33,
        minLat: 44.38,
        maxLng: -64.32,
        maxLat: 44.4,
      },
    });
  });

  it("rejects invalid bounds instead of passing them to Mapbox", () => {
    expect(normalizeBbox({ minLng: -63, minLat: 45, maxLng: -64, maxLat: 44 })).toBeNull();
    expect(normalizeBbox({ minLng: -64, minLat: 44, maxLng: -63, maxLat: 45 })).toEqual({
      minLng: -64,
      minLat: 44,
      maxLng: -63,
      maxLat: 45,
    });
  });

  it("loads top potholes from the Deno top-potholes endpoint", async () => {
    const body = {
      potholes: [
        {
          id: "p1",
          lat: 44.6488,
          lng: -63.5752,
          magnitude: 2.7,
          confirmation_count: 5,
          first_reported_at: "2026-04-01T00:00:00Z",
          last_confirmed_at: "2026-04-21T21:45:00Z",
          status: "active",
          segment_id: null,
        },
      ],
    };
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(200, body));
    vi.stubGlobal("fetch", fetchMock);

    await expect(getTopPotholes(50)).resolves.toEqual({ ok: true, data: body });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("https://test.local/functions/v1/top-potholes?limit=50");
  });

  it("passes data_updated_at through when the API provides it", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () =>
      jsonResponse(200, { total_km_mapped: 1, generated_at: "2026-11-08T12:00:00Z", data_updated_at: "2026-11-06" }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPublicStats()).resolves.toMatchObject({ data_updated_at: "2026-11-06" });
  });
});

describe("read API client failure states", () => {
  const bbox = { minLng: -63.6, minLat: 44.6, maxLng: -63.55, maxLat: 44.65 };

  it("reports an HTTP error instead of an empty pothole list", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => jsonResponse(503, { error: "down" })));

    await expect(getPotholes(bbox)).resolves.toEqual({ ok: false, reason: "http", status: 503 });
  });

  it("reports a network failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn<typeof fetch>(async () => {
        throw new TypeError("fetch failed");
      }),
    );

    await expect(getTopPotholes(10)).resolves.toEqual({ ok: false, reason: "network", status: null });
    await expect(getPublicStats()).resolves.toBeNull();
  });

  it("rejects malformed pothole payloads", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => jsonResponse(200, { potholes: "nope" })));

    await expect(getPotholes(bbox)).resolves.toMatchObject({ ok: false, reason: "invalid_response" });
  });

  it("keeps a real empty list as success", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => jsonResponse(200, { potholes: [] })));

    await expect(getPotholes(bbox)).resolves.toEqual({ ok: true, data: { potholes: [] } });
  });

  it("refuses bounding boxes wider than the lookup cap without calling the API", async () => {
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPotholes({ minLng: -66, minLat: 43, maxLng: -60, maxLat: 47 })).resolves.toMatchObject({
      ok: false,
      reason: "invalid_request",
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("surfaces 404 for segment details so the UI can say the road isn't published", async () => {
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => jsonResponse(404, { error: "not_found" })));

    await expect(getSegmentDetail("seg-1")).resolves.toEqual({ ok: false, reason: "http", status: 404 });
  });

  it("forwards the caller's abort signal and reports aborted", async () => {
    const controller = new AbortController();
    const fetchMock = vi.fn<typeof fetch>(
      (_input, init) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
        }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const pending = getSegmentDetail("seg-1", { signal: controller.signal });
    controller.abort();

    await expect(pending).resolves.toEqual({ ok: false, reason: "aborted", status: null });
  });

  it("times out even when the caller passes its own signal", async () => {
    vi.useFakeTimers();
    try {
      const fetchMock = vi.fn<typeof fetch>(
        (_input, init) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
          }),
      );
      vi.stubGlobal("fetch", fetchMock);

      const pending = getPotholes(bbox, { signal: new AbortController().signal, timeoutMs: 50 });
      await vi.advanceTimersByTimeAsync(60);

      await expect(pending).resolves.toEqual({ ok: false, reason: "timeout", status: null });
    } finally {
      vi.useRealTimers();
    }
  });

  it("encodes segment ids into the path", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(404, {}));
    vi.stubGlobal("fetch", fetchMock);

    await getSegmentDetail("a/b?c");

    expect(fetchMock.mock.calls[0][0]).toBe("https://test.local/functions/v1/segments/a%2Fb%3Fc");
  });
});
