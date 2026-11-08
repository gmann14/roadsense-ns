// Structured, PII-free logging for the gateway.
//
// One JSON object per line so Railway's log search can filter on fields.
// Callers pass only operational context: a route name, the bounded request
// id, a status, a duration. Never pass tokens, IPs, coordinates, bboxes or
// request bodies here -- the helpers below have no field for them on purpose.

const MAX_ERROR_MESSAGE_LENGTH = 300;

export type LogSink = (line: string) => void;

export type ErrorSummary = {
    error_name: string;
    error_code?: string;
    error_message: string;
};

/// Reduces an unknown thrown value to name / code / truncated message. The
/// Postgres driver puts the SQLSTATE in `code`; that is the most useful field
/// for triage and carries no user data.
export function summarizeError(error: unknown): ErrorSummary {
    if (error instanceof Error) {
        const code = (error as { code?: unknown }).code;
        return {
            error_name: error.name,
            ...(typeof code === "string" && code.length > 0 ? { error_code: code } : {}),
            error_message: truncate(error.message),
        };
    }
    if (typeof error === "object" && error !== null) {
        const message = (error as { message?: unknown }).message;
        return {
            error_name: "NonErrorObject",
            error_message: truncate(typeof message === "string" ? message : "unknown error"),
        };
    }
    return { error_name: typeof error, error_message: truncate(String(error)) };
}

function truncate(value: string): string {
    return value.length > MAX_ERROR_MESSAGE_LENGTH ? `${value.slice(0, MAX_ERROR_MESSAGE_LENGTH)}…` : value;
}

/// Logs a handler-level failure (the request still gets a 5xx response).
export function logHandlerError(
    route: string,
    requestId: string,
    error: unknown,
    sink: LogSink = (line) => console.error(line),
): void {
    sink(JSON.stringify({
        level: "error",
        event: "handler_error",
        route,
        request_id: requestId,
        ...summarizeError(error),
    }));
}

export type RequestLogFields = {
    method: string;
    route: string;
    status: number;
    durationMs: number;
    requestId: string;
};

/// One access-log line per request, written by server.ts.
export function logRequest(
    fields: RequestLogFields,
    sink: LogSink = (line) => console.log(line),
): void {
    sink(JSON.stringify({
        level: fields.status >= 500 ? "error" : "info",
        event: "request",
        method: fields.method,
        route: fields.route,
        status: fields.status,
        duration_ms: Math.round(fields.durationMs),
        request_id: fields.requestId,
    }));
}
