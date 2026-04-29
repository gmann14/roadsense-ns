import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getPublicStats, getTopPotholes } from "@/lib/api/client";

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
      pothole_bounds: null,
      generated_at: "2026-04-28T15:00:00Z",
    };
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(200, stats));
    vi.stubGlobal("fetch", fetchMock);

    await expect(getPublicStats()).resolves.toEqual(stats);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://test.local/functions/v1/stats");
    const headers = init?.headers as Record<string, string>;
    expect(headers.apikey).toBe("anon.test-key");
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

    await expect(getTopPotholes(50)).resolves.toEqual(body);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe("https://test.local/functions/v1/top-potholes?limit=50");
  });
});
