import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { submitFeedback } from "@/lib/api/client";

const ORIGINAL_API_BASE = process.env.NEXT_PUBLIC_API_BASE_URL;
const ORIGINAL_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

beforeEach(() => {
  process.env.NEXT_PUBLIC_API_BASE_URL = "https://test.local/functions/v1";
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon.test-key";
});

afterEach(() => {
  process.env.NEXT_PUBLIC_API_BASE_URL = ORIGINAL_API_BASE;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = ORIGINAL_ANON_KEY;
});

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

describe("submitFeedback", () => {
  it("sends a POST to /feedback with snake_case body and apikey headers", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () =>
      jsonResponse(201, { id: "abc", request_id: "req-1" }, { "x-request-id": "req-1" }),
    );

    const result = await submitFeedback(
      {
        category: "bug",
        message: "Drawer collapse trips on quick taps from the worst-roads page.",
        replyEmail: "  tester@example.com  ",
        contactConsent: true,
        route: "/reports/worst-roads",
        locale: "en-CA",
      },
      fetchMock,
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://test.local/functions/v1/feedback");
    expect(init?.method).toBe("POST");

    const headers = init?.headers as Record<string, string>;
    expect(headers["content-type"]).toBe("application/json");
    expect(headers.apikey).toBe("anon.test-key");
    expect(headers.Authorization).toBe("Bearer anon.test-key");

    const sentBody = JSON.parse((init?.body as string) ?? "{}");
    expect(sentBody.source).toBe("web");
    expect(sentBody.category).toBe("bug");
    expect(sentBody.message).toBe("Drawer collapse trips on quick taps from the worst-roads page.");
    expect(sentBody.reply_email).toBe("tester@example.com");
    expect(sentBody.contact_consent).toBe(true);
    expect(sentBody.route).toBe("/reports/worst-roads");
    expect(sentBody.locale).toBe("en-CA");
    expect(sentBody.platform).toBe("web");

    expect(result).toEqual({ kind: "accepted", id: "abc", requestId: "req-1" });
  });

  it("treats blank reply_email as null and contact_consent as false by default", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => jsonResponse(201, { id: "x", request_id: "r" }));

    await submitFeedback(
      {
        category: "feature",
        message: "Add dark mode for the public map.",
      },
      fetchMock,
    );

    const sentBody = JSON.parse((fetchMock.mock.calls[0][1]?.body as string) ?? "{}");
    expect(sentBody.reply_email).toBeNull();
    expect(sentBody.contact_consent).toBe(false);
    expect(sentBody.locale).toBeNull();
    expect(sentBody.route).toBeNull();
  });

  it("translates 400 with field_errors into validation_failed", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () =>
      jsonResponse(
        400,
        {
          error: "validation_failed",
          request_id: "req-400",
          field_errors: { message: "must be at least 8 characters" },
        },
        { "x-request-id": "req-400" },
      ),
    );

    const result = await submitFeedback(
      {
        category: "bug",
        message: "edge case",
      },
      fetchMock,
    );

    expect(result).toEqual({
      kind: "validation_failed",
      fieldErrors: { message: "must be at least 8 characters" },
      requestId: "req-400",
    });
  });

  it("translates 429 with Retry-After header into rate_limited", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () =>
      new Response(null, {
        status: 429,
        headers: { "Retry-After": "1800", "x-request-id": "req-429" },
      }),
    );

    const result = await submitFeedback(
      {
        category: "other",
        message: "Hit submit too many times in a row while testing rate-limit copy.",
      },
      fetchMock,
    );

    expect(result).toEqual({ kind: "rate_limited", retryAfterSeconds: 1800, requestId: "req-429" });
  });

  it("returns server_error for unexpected status codes", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () =>
      new Response(null, { status: 503, headers: { "x-request-id": "req-503" } }),
    );

    const result = await submitFeedback(
      {
        category: "privacy_safety",
        message: "Service was unavailable when I tried to send this feedback.",
      },
      fetchMock,
    );

    expect(result).toEqual({ kind: "server_error", statusCode: 503, requestId: "req-503" });
  });

  it("returns network_error when fetch throws", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => {
      throw new TypeError("Failed to fetch");
    });

    const result = await submitFeedback(
      {
        category: "bug",
        message: "Couldn't reach the function from this network — should propagate.",
      },
      fetchMock,
    );

    expect(result).toEqual({ kind: "network_error", message: "Failed to fetch" });
  });
});
