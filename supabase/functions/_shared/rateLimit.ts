// Shared rate-limit types and helpers for the check_and_bump_rate_limit
// pattern (one row per key per time bucket, see migration
// 20260418093007_rate_limits.sql and upload-readings/runtime.ts).

import type { RpcResponse } from "./pgRpc.ts";

export type RateLimitResult =
    | { ok: true; retryAfterSeconds: 0 }
    | { ok: false; retryAfterSeconds: number };

export type RateLimitRpc = <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>;

export const RATE_LIMIT_OK: RateLimitResult = { ok: true, retryAfterSeconds: 0 };

export function secondsUntilNextUtcHour(now: Date): number {
    const nextHour = Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate(),
        now.getUTCHours() + 1,
    );
    return Math.ceil((nextHour - now.getTime()) / 1000);
}

export function utcHourBucket(now: Date): Date {
    return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));
}

// Expands an IPv6 address into its 8 hextets (lowercase, no leading zeros).
// Handles `::` compression and a trailing dotted IPv4 tail. Returns null when
// the value is not a well-formed IPv6 address.
function ipv6Hextets(value: string): string[] | null {
    let address = value.toLowerCase();
    const zoneIndex = address.indexOf("%");
    if (zoneIndex >= 0) address = address.slice(0, zoneIndex);

    const lastColon = address.lastIndexOf(":");
    const tail = address.slice(lastColon + 1);
    if (tail.includes(".")) {
        const octets = tail.split(".").map(Number);
        if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) return null;
        address = `${address.slice(0, lastColon + 1)}${((octets[0] << 8) | octets[1]).toString(16)}:${
            ((octets[2] << 8) | octets[3]).toString(16)
        }`;
    }

    const halves = address.split("::");
    if (halves.length > 2) return null;
    const head = halves[0] === "" ? [] : halves[0].split(":");
    const rest = halves.length === 2 ? (halves[1] === "" ? [] : halves[1].split(":")) : [];
    const missing = 8 - head.length - rest.length;
    if (halves.length === 1 ? missing !== 0 : missing < 1) return null;

    const groups = [...head, ...Array.from({ length: halves.length === 2 ? missing : 0 }, () => "0"), ...rest];
    if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
    return groups.map((g) => Number.parseInt(g, 16).toString(16));
}

/// Rate-limit key for a client IP. IPv4 stays as-is. IPv6 is keyed on its
/// /64: a single subscriber is normally handed a whole /64, so keying on the
/// full /128 let one client rotate through 2^64 addresses to get a fresh
/// bucket each time (review 2026-10-18 P2). IPv4-mapped IPv6
/// (`::ffff:a.b.c.d`) is keyed as the IPv4 address.
export function rateLimitIpKey(ip: string): string {
    if (!ip.includes(":")) return ip;
    const hextets = ipv6Hextets(ip);
    if (!hextets) return ip;
    if (hextets.slice(0, 5).every((g) => g === "0") && hextets[5] === "ffff") {
        const high = Number.parseInt(hextets[6], 16);
        const low = Number.parseInt(hextets[7], 16);
        return `${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`;
    }
    return `${hextets.slice(0, 4).join(":")}::/64`;
}

/// Hourly per-IP limiter on the shared check_and_bump_rate_limit RPC. Used by
/// the endpoints that have no device identity to key on (feedback, device
/// token challenge/redeem).
export function createHourlyIpRateLimitChecker(
    rpc: RateLimitRpc,
    options: { keyPrefix: string; limitPerHour: number; nowFactory?: () => Date },
): (ip: string) => Promise<RateLimitResult> {
    const nowFactory = options.nowFactory ?? (() => new Date());
    return async (ip: string): Promise<RateLimitResult> => {
        const now = nowFactory();
        const result = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `${options.keyPrefix}:${rateLimitIpKey(ip)}`,
            p_bucket_start: utcHourBucket(now).toISOString(),
            p_limit: options.limitPerHour,
        });
        if (result.error) {
            throw new Error(result.error.message ?? `${options.keyPrefix} rate limit RPC failed`);
        }
        if (!result.data) {
            return { ok: false, retryAfterSeconds: secondsUntilNextUtcHour(now) };
        }
        return RATE_LIMIT_OK;
    };
}
