import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import {
    createFeedbackHandler,
    extractClientIp,
    type FeedbackInsertResult,
    type FeedbackPayload,
    validateFeedbackPayload,
} from "./handler.ts";
import { createFeedbackRateLimitChecker } from "./runtime.ts";
import type { RpcResponse } from "../upload-readings/runtime.ts";

const validPayload = {
    source: "ios",
    category: "bug",
    message: "The map froze after marking a pothole on Quinpool Rd.",
    reply_email: "tester@example.com",
    contact_consent: true,
    app_version: "0.3.0 (101)",
    platform: "iOS 17.4.1",
    locale: "en-CA",
    route: "MapScreen",
} as const;

function defaultDeps(overrides: Partial<{
    insertResult: FeedbackInsertResult;
    insertCalls: Array<{ payload: FeedbackPayload; clientIp: string; userAgent: string | null; requestId: string }>;
    rateLimit: () => Promise<{ ok: true; retryAfterSeconds: 0 } | { ok: false; retryAfterSeconds: number }>;
    failInsertWith?: Error;
}> = {}) {
    const calls = overrides.insertCalls ?? [];
    return {
        calls,
        deps: {
            checkRateLimit: overrides.rateLimit ?? (async () => ({ ok: true as const, retryAfterSeconds: 0 as const })),
            insertFeedback: async (params: {
                payload: FeedbackPayload;
                clientIp: string;
                userAgent: string | null;
                requestId: string;
            }) => {
                if (overrides.failInsertWith) {
                    throw overrides.failInsertWith;
                }
                calls.push(params);
                return overrides.insertResult ?? { id: "00000000-0000-0000-0000-000000000abc" };
            },
        },
    };
}

Deno.test("extractClientIp prefers x-forwarded-for then x-real-ip then cf-connecting-ip", () => {
    assertEquals(
        extractClientIp(new Headers({
            "x-forwarded-for": "203.0.113.7, 10.0.0.1",
            "x-real-ip": "198.51.100.10",
        })),
        "203.0.113.7",
    );

    assertEquals(
        extractClientIp(new Headers({ "x-real-ip": "198.51.100.10" })),
        "198.51.100.10",
    );

    assertEquals(
        extractClientIp(new Headers({ "cf-connecting-ip": "192.0.2.5" })),
        "192.0.2.5",
    );

    assertEquals(extractClientIp(new Headers()), "unknown");
});

Deno.test("validateFeedbackPayload rejects unknown source/category and short message", () => {
    const result = validateFeedbackPayload({
        ...validPayload,
        source: "android",
        category: "unknown",
        message: "no",
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            source: "must be one of ios, web",
            category: "must be a known feedback category",
            message: "must be at least 8 characters",
        });
    }
});

Deno.test("validateFeedbackPayload rejects oversized messages", () => {
    const result = validateFeedbackPayload({
        ...validPayload,
        message: "x".repeat(4001),
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.fieldErrors.message, "must be at most 4000 characters");
    }
});

Deno.test("validateFeedbackPayload rejects malformed reply email and consent without email", () => {
    const noAtResult = validateFeedbackPayload({
        ...validPayload,
        reply_email: "not-an-email",
    });
    assertEquals(noAtResult.ok, false);
    if (!noAtResult.ok) {
        assertEquals(noAtResult.fieldErrors.reply_email, "must be a valid email address");
    }

    const consentWithoutEmail = validateFeedbackPayload({
        ...validPayload,
        reply_email: "",
        contact_consent: true,
    });
    assertEquals(consentWithoutEmail.ok, false);
    if (!consentWithoutEmail.ok) {
        assertEquals(consentWithoutEmail.fieldErrors.contact_consent, "requires a reply email");
    }
});

Deno.test("validateFeedbackPayload trims optional metadata and ignores empty strings", () => {
    const result = validateFeedbackPayload({
        ...validPayload,
        reply_email: "",
        contact_consent: false,
        app_version: "  0.3.0 (101)  ",
        platform: "",
        locale: "en-CA",
        route: " MapScreen ",
    });

    assertEquals(result.ok, true);
    if (result.ok) {
        assertEquals(result.payload.reply_email, null);
        assertEquals(result.payload.contact_consent, false);
        assertEquals(result.payload.app_version, "0.3.0 (101)");
        assertEquals(result.payload.platform, null);
        assertEquals(result.payload.locale, "en-CA");
        assertEquals(result.payload.route, "MapScreen");
    }
});

Deno.test("feedback handler returns 405 for non-POST", async () => {
    const { deps } = defaultDeps();
    const handler = createFeedbackHandler(deps);

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", { method: "GET" }),
    );

    assertEquals(response.status, 405);
});

Deno.test("feedback handler returns 400 for invalid JSON", async () => {
    const { deps } = defaultDeps();
    const handler = createFeedbackHandler(deps);

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: "{",
        }),
    );

    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "validation_failed");
});

Deno.test("feedback handler rejects payloads larger than 16KB", async () => {
    const { deps } = defaultDeps();
    const handler = createFeedbackHandler(deps);

    const oversized = JSON.stringify({
        ...validPayload,
        message: "spam ".repeat(5000),
    });

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: oversized,
        }),
    );

    assertEquals(response.status, 413);
    assertEquals((await response.json()).error, "payload_too_large");
});

Deno.test("feedback handler returns 429 with Retry-After when rate limited", async () => {
    const { deps } = defaultDeps({
        rateLimit: async () => ({ ok: false as const, retryAfterSeconds: 1234 }),
    });
    const handler = createFeedbackHandler(deps);

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", {
            method: "POST",
            headers: { "content-type": "application/json", "x-request-id": "req-feedback-limit" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 429);
    assertEquals(response.headers.get("Retry-After"), "1234");
    assertEquals(response.headers.get("x-request-id"), "req-feedback-limit");
    const body = await response.json();
    assertEquals(body.retry_after_s, 1234);
});

Deno.test("feedback handler stores submission with request id and client metadata", async () => {
    const calls: Array<{ payload: FeedbackPayload; clientIp: string; userAgent: string | null; requestId: string }> = [];
    const { deps } = defaultDeps({ insertCalls: calls });
    const handler = createFeedbackHandler(deps);

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-forwarded-for": "203.0.113.10, 10.0.0.1",
                "user-agent": "RoadSenseTester/0.3 (iOS 17.4)",
                "x-request-id": "req-feedback-ok",
            },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 201);
    const body = await response.json();
    assertEquals(body.request_id, "req-feedback-ok");
    assertEquals(typeof body.id, "string");

    assertEquals(calls.length, 1);
    assertEquals(calls[0].clientIp, "203.0.113.10");
    assertEquals(calls[0].userAgent, "RoadSenseTester/0.3 (iOS 17.4)");
    assertEquals(calls[0].requestId, "req-feedback-ok");
    assertEquals(calls[0].payload.message, validPayload.message);
    assertEquals(calls[0].payload.reply_email, validPayload.reply_email);
    assertEquals(calls[0].payload.contact_consent, true);
});

Deno.test("feedback handler maps insert failure to 503", async () => {
    const { deps } = defaultDeps({ failInsertWith: new Error("connection lost") });
    const handler = createFeedbackHandler(deps);

    const response = await handler(
        new Request("http://localhost/functions/v1/feedback", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(validPayload),
        }),
    );

    assertEquals(response.status, 503);
    assertEquals((await response.json()).error, "service_unavailable");
});

Deno.test("createFeedbackRateLimitChecker hits IP bucket and returns retry seconds when limited", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const checker = createFeedbackRateLimitChecker(
        async <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return { data: false as T, error: null };
        },
        () => new Date("2026-04-27T15:30:00Z"),
    );

    const result = await checker("203.0.113.10");
    assertEquals(result.ok, false);
    if (!result.ok) {
        assertEquals(result.retryAfterSeconds, 30 * 60);
    }
    assertEquals(calls[0].p_key, "feedback-ip:203.0.113.10");
    assertEquals(calls[0].p_limit, 10);
});
