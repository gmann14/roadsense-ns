import { assertEquals } from "jsr:@std/assert";
import { logHandlerError, logRequest, summarizeError } from "./log.ts";

function capture(): { sink: (line: string) => void; lines: Array<Record<string, unknown>> } {
    const lines: Array<Record<string, unknown>> = [];
    return { sink: (line) => lines.push(JSON.parse(line)), lines };
}

Deno.test("summarizeError keeps name, SQLSTATE code and message", () => {
    const error = Object.assign(new Error("relation does not exist"), { code: "42P01" });
    assertEquals(summarizeError(error), {
        error_name: "Error",
        error_code: "42P01",
        error_message: "relation does not exist",
    });
});

Deno.test("summarizeError handles non-Error throwables and RPC error objects", () => {
    assertEquals(summarizeError({ message: "rpc failed" }), {
        error_name: "NonErrorObject",
        error_message: "rpc failed",
    });
    assertEquals(summarizeError(null), { error_name: "object", error_message: "null" });
    assertEquals(summarizeError("boom"), { error_name: "string", error_message: "boom" });
});

Deno.test("summarizeError truncates very long messages", () => {
    const summary = summarizeError(new Error("x".repeat(5000)));
    assertEquals(summary.error_message.length <= 301, true);
});

Deno.test("logHandlerError writes one JSON line with route and request id only", () => {
    const { sink, lines } = capture();
    logHandlerError("potholes", "req-7", new Error("db down"), sink);
    assertEquals(lines, [{
        level: "error",
        event: "handler_error",
        route: "potholes",
        request_id: "req-7",
        error_name: "Error",
        error_message: "db down",
    }]);
});

Deno.test("logRequest writes method, route template, status, rounded duration and request id", () => {
    const { sink, lines } = capture();
    logRequest({ method: "GET", route: "/functions/v1/segments/:id", status: 200, durationMs: 12.6, requestId: "r1" }, sink);
    logRequest({ method: "POST", route: "unmatched", status: 503, durationMs: 0.2, requestId: "r2" }, sink);
    assertEquals(lines, [
        {
            level: "info",
            event: "request",
            method: "GET",
            route: "/functions/v1/segments/:id",
            status: 200,
            duration_ms: 13,
            request_id: "r1",
        },
        {
            level: "error",
            event: "request",
            method: "POST",
            route: "unmatched",
            status: 503,
            duration_ms: 0,
            request_id: "r2",
        },
    ]);
});
