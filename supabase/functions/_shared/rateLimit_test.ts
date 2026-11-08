import { assertEquals } from "jsr:@std/assert";
import { createHourlyIpRateLimitChecker, rateLimitIpKey } from "./rateLimit.ts";
import type { RpcResponse } from "./pgRpc.ts";

Deno.test("rateLimitIpKey leaves IPv4 addresses and unknown untouched", () => {
    assertEquals(rateLimitIpKey("203.0.113.7"), "203.0.113.7");
    assertEquals(rateLimitIpKey("unknown"), "unknown");
});

Deno.test("rateLimitIpKey keys IPv6 on its /64 so rotating the interface id doesn't mint new buckets", () => {
    const a = rateLimitIpKey("2001:db8:abcd:12:1111:2222:3333:4444");
    const b = rateLimitIpKey("2001:0db8:abcd:0012:ffff:ffff:ffff:fffe");
    const c = rateLimitIpKey("2001:db8:abcd:12::1");
    assertEquals(a, "2001:db8:abcd:12::/64");
    assertEquals(b, a);
    assertEquals(c, a);
    assertEquals(rateLimitIpKey("2001:db8:abcd:13::1") === a, false);
});

Deno.test("rateLimitIpKey expands :: compression in the network half", () => {
    assertEquals(rateLimitIpKey("2001:db8::1"), "2001:db8:0:0::/64");
    assertEquals(rateLimitIpKey("::1"), "0:0:0:0::/64");
    assertEquals(rateLimitIpKey("FE80::ABCD%en0"), "fe80:0:0:0::/64");
});

Deno.test("rateLimitIpKey keys IPv4-mapped IPv6 as the IPv4 address", () => {
    assertEquals(rateLimitIpKey("::ffff:203.0.113.7"), "203.0.113.7");
    assertEquals(rateLimitIpKey("::ffff:cb00:7107"), "203.0.113.7");
});

Deno.test("rateLimitIpKey passes malformed IPv6-looking values through unchanged", () => {
    assertEquals(rateLimitIpKey("1:2:3"), "1:2:3");
    assertEquals(rateLimitIpKey("1::2::3"), "1::2::3");
});

Deno.test("createHourlyIpRateLimitChecker uses the prefix, the /64 key and the hourly bucket", async () => {
    const calls: Array<Record<string, unknown>> = [];
    const check = createHourlyIpRateLimitChecker(
        <T>(_fn: string, params: Record<string, unknown>): Promise<RpcResponse<T>> => {
            calls.push(params);
            return Promise.resolve({ data: true as T, error: null });
        },
        { keyPrefix: "test-ip", limitPerHour: 7, nowFactory: () => new Date("2026-11-08T12:34:56Z") },
    );

    assertEquals(await check("2001:db8:abcd:12::99"), { ok: true, retryAfterSeconds: 0 });
    assertEquals(calls, [{
        p_key: "test-ip:2001:db8:abcd:12::/64",
        p_bucket_start: "2026-11-08T12:00:00.000Z",
        p_limit: 7,
    }]);
});

Deno.test("createHourlyIpRateLimitChecker returns retry-after to the next hour when over the limit", async () => {
    const check = createHourlyIpRateLimitChecker(
        <T>(): Promise<RpcResponse<T>> => Promise.resolve({ data: false as T, error: null }),
        { keyPrefix: "test-ip", limitPerHour: 1, nowFactory: () => new Date("2026-11-08T12:59:00Z") },
    );
    assertEquals(await check("203.0.113.7"), { ok: false, retryAfterSeconds: 60 });
});
