import { errorResponse, jsonResponse } from "../_shared/http.ts";

const FEEDBACK_SOURCES = new Set(["ios", "web"]);
const FEEDBACK_CATEGORIES = new Set([
    "bug",
    "feature",
    "map_issue",
    "pothole_issue",
    "privacy_safety",
    "other",
]);

const MIN_MESSAGE_LENGTH = 8;
const MAX_MESSAGE_LENGTH = 4000;
const MAX_REPLY_EMAIL_LENGTH = 254;
const MAX_FREEFORM_FIELD_LENGTH = 200;
const MAX_USER_AGENT_LENGTH = 400;
const MAX_PAYLOAD_BYTES = 16_384;

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

export type FeedbackSource = "ios" | "web";

export type FeedbackCategory =
    | "bug"
    | "feature"
    | "map_issue"
    | "pothole_issue"
    | "privacy_safety"
    | "other";

export type FeedbackPayload = {
    source: FeedbackSource;
    category: FeedbackCategory;
    message: string;
    reply_email: string | null;
    contact_consent: boolean;
    app_version: string | null;
    platform: string | null;
    locale: string | null;
    route: string | null;
};

export type FeedbackInsertResult = {
    id: string;
};

export type ValidationResult =
    | { ok: true; payload: FeedbackPayload }
    | { ok: false; fieldErrors: Record<string, string> };

export type RateLimitResult =
    | { ok: true; retryAfterSeconds: 0 }
    | { ok: false; retryAfterSeconds: number };

export type FeedbackHandlerDeps = {
    checkRateLimit: (ip: string) => Promise<RateLimitResult>;
    insertFeedback: (params: {
        payload: FeedbackPayload;
        clientIp: string;
        userAgent: string | null;
        requestId: string;
    }) => Promise<FeedbackInsertResult>;
};

function trimToLimit(value: unknown, limit: number): string | null {
    if (typeof value !== "string") {
        return null;
    }

    const trimmed = value.trim();
    if (trimmed.length === 0) {
        return null;
    }

    return trimmed.slice(0, limit);
}

export function extractClientIp(headers: Headers): string {
    const forwarded = headers.get("x-forwarded-for") ?? "";
    const firstForwarded = forwarded.split(",")[0]?.trim();

    return firstForwarded
        || headers.get("x-real-ip")
        || headers.get("cf-connecting-ip")
        || "unknown";
}

export function validateFeedbackPayload(payload: unknown): ValidationResult {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return {
            ok: false,
            fieldErrors: { payload: "must be a JSON object" },
        };
    }

    const input = payload as Record<string, unknown>;
    const fieldErrors: Record<string, string> = {};

    const source = String(input.source ?? "");
    if (!FEEDBACK_SOURCES.has(source)) {
        fieldErrors.source = "must be one of ios, web";
    }

    const category = String(input.category ?? "");
    if (!FEEDBACK_CATEGORIES.has(category)) {
        fieldErrors.category = "must be a known feedback category";
    }

    const messageRaw = typeof input.message === "string" ? input.message : "";
    const message = messageRaw.trim();
    if (message.length < MIN_MESSAGE_LENGTH) {
        fieldErrors.message = `must be at least ${MIN_MESSAGE_LENGTH} characters`;
    } else if (message.length > MAX_MESSAGE_LENGTH) {
        fieldErrors.message = `must be at most ${MAX_MESSAGE_LENGTH} characters`;
    }

    const replyEmailRaw = typeof input.reply_email === "string" ? input.reply_email.trim() : "";
    let replyEmail: string | null = null;
    if (replyEmailRaw.length > 0) {
        if (replyEmailRaw.length > MAX_REPLY_EMAIL_LENGTH) {
            fieldErrors.reply_email = "is too long";
        } else if (!EMAIL_REGEX.test(replyEmailRaw)) {
            fieldErrors.reply_email = "must be a valid email address";
        } else {
            replyEmail = replyEmailRaw;
        }
    }

    const contactConsentRaw = input.contact_consent;
    const contactConsent = contactConsentRaw === true;
    if (contactConsentRaw !== undefined && typeof contactConsentRaw !== "boolean") {
        fieldErrors.contact_consent = "must be a boolean if provided";
    }
    if (contactConsent && !replyEmail) {
        fieldErrors.contact_consent = "requires a reply email";
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { ok: false, fieldErrors };
    }

    return {
        ok: true,
        payload: {
            source: source as FeedbackSource,
            category: category as FeedbackCategory,
            message,
            reply_email: replyEmail,
            contact_consent: contactConsent,
            app_version: trimToLimit(input.app_version, MAX_FREEFORM_FIELD_LENGTH),
            platform: trimToLimit(input.platform, MAX_FREEFORM_FIELD_LENGTH),
            locale: trimToLimit(input.locale, MAX_FREEFORM_FIELD_LENGTH),
            route: trimToLimit(input.route, MAX_FREEFORM_FIELD_LENGTH),
        },
    };
}

export function createFeedbackHandler(deps: FeedbackHandlerDeps) {
    return async function handleFeedback(req: Request): Promise<Response> {
        const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

        if (req.method !== "POST") {
            return new Response(null, {
                status: 405,
                headers: { "x-request-id": requestId },
            });
        }

        const contentLengthHeader = req.headers.get("content-length");
        if (contentLengthHeader) {
            const declaredLength = Number(contentLengthHeader);
            if (Number.isFinite(declaredLength) && declaredLength > MAX_PAYLOAD_BYTES) {
                return errorResponse(
                    "payload_too_large",
                    "Feedback payload is too large.",
                    413,
                    requestId,
                );
            }
        }

        let rawText: string;
        try {
            rawText = await req.text();
        } catch {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be readable" } },
            );
        }

        if (rawText.length > MAX_PAYLOAD_BYTES) {
            return errorResponse(
                "payload_too_large",
                "Feedback payload is too large.",
                413,
                requestId,
            );
        }

        let rawPayload: unknown;
        try {
            rawPayload = JSON.parse(rawText);
        } catch {
            return errorResponse(
                "validation_failed",
                "Payload is malformed.",
                400,
                requestId,
                { field_errors: { payload: "must be valid JSON" } },
            );
        }

        const validation = validateFeedbackPayload(rawPayload);
        if (!validation.ok) {
            return errorResponse(
                "validation_failed",
                "Feedback payload failed validation.",
                400,
                requestId,
                { field_errors: validation.fieldErrors },
            );
        }

        const payload = validation.payload;
        const clientIp = extractClientIp(req.headers);
        const userAgentHeader = req.headers.get("user-agent");
        const userAgent = userAgentHeader
            ? userAgentHeader.slice(0, MAX_USER_AGENT_LENGTH)
            : null;

        try {
            const rateLimit = await deps.checkRateLimit(clientIp);
            if (!rateLimit.ok) {
                return errorResponse(
                    "rate_limited",
                    "Feedback submissions from this network are temporarily limited.",
                    429,
                    requestId,
                    { retry_after_s: rateLimit.retryAfterSeconds },
                    { "Retry-After": String(rateLimit.retryAfterSeconds) },
                );
            }

            const result = await deps.insertFeedback({
                payload,
                clientIp,
                userAgent,
                requestId,
            });

            return jsonResponse(
                { id: result.id, request_id: requestId },
                201,
                {},
                requestId,
            );
        } catch (error) {
            console.error("feedback submission failed", {
                request_id: requestId,
                category: payload.category,
                source: payload.source,
                error,
            });

            return errorResponse(
                "service_unavailable",
                "Feedback service unavailable.",
                503,
                requestId,
            );
        }
    };
}
