import { configuredOriginSecret, hasValidOriginAuth } from "./originAuth.ts";

function normalizeCandidate(raw: string | null): string | null {
    if (!raw) return null;

    let value = raw.trim();
    if (value.length === 0) return null;

    if (value.startsWith("[") && value.includes("]")) {
        value = value.slice(1, value.indexOf("]"));
    } else if (value.includes(":") && value.split(":").length === 2 && isIpv4(value.split(":")[0])) {
        value = value.split(":")[0];
    }

    if (isIpv4(value) || isIpv6Like(value)) {
        return value;
    }

    return null;
}

function isIpv4(value: string): boolean {
    const parts = value.split(".");
    return parts.length === 4 && parts.every((part) => {
        if (!/^\d{1,3}$/.test(part)) return false;
        const octet = Number(part);
        return octet >= 0 && octet <= 255;
    });
}

function isIpv6Like(value: string): boolean {
    return value.includes(":") && /^[0-9a-f:.]+$/i.test(value);
}

function isPrivateOrLocalIp(value: string): boolean {
    if (isIpv4(value)) {
        const [a, b] = value.split(".").map(Number);
        return a === 10 ||
            a === 127 ||
            (a === 172 && b >= 16 && b <= 31) ||
            (a === 192 && b === 168) ||
            (a === 169 && b === 254) ||
            (a === 100 && b >= 64 && b <= 127);
    }

    const lower = value.toLowerCase();
    return lower === "::1" ||
        lower.startsWith("fc") ||
        lower.startsWith("fd") ||
        lower.startsWith("fe80:");
}

function publicForwardedIp(headers: Headers): string | null {
    const forwarded = headers.get("x-forwarded-for") ?? "";
    const candidates = forwarded
        .split(",")
        .map(normalizeCandidate)
        .filter((candidate): candidate is string => candidate !== null);

    return [...candidates].reverse().find((candidate) => !isPrivateOrLocalIp(candidate)) ?? null;
}

// Set by the Cloudflare worker (cloudflare/api-proxy/src/worker.js) from its
// own `cf-connecting-ip`, which Cloudflare rewrites on every hop and a client
// cannot spoof past Cloudflare's edge. The Railway origin URL is public, so the
// header alone proves nothing: a direct-to-origin caller can set it to any
// value. It is therefore trusted ONLY when the same request carries the
// worker's shared secret in `x-origin-auth` (see _shared/originAuth.ts, review
// 2026-10-18 P0-4). Without a configured secret, or without a matching header,
// x-client-ip is ignored and the x-forwarded-for logic below applies.
function trustedWorkerClientIp(headers: Headers, originSecret: string): string | null {
    if (!hasValidOriginAuth(headers, originSecret)) return null;
    const candidate = normalizeCandidate(headers.get("x-client-ip"));
    if (candidate && !isPrivateOrLocalIp(candidate)) {
        return candidate;
    }
    return null;
}

export function extractClientIp(
    headers: Headers,
    originSecret: string = configuredOriginSecret(),
): string {
    const fromWorker = trustedWorkerClientIp(headers, originSecret);
    if (fromWorker) return fromWorker;

    const forwarded = publicForwardedIp(headers);
    if (forwarded) return forwarded;

    for (const header of ["x-real-ip", "cf-connecting-ip"]) {
        const candidate = normalizeCandidate(headers.get(header));
        if (candidate && !isPrivateOrLocalIp(candidate)) {
            return candidate;
        }
    }

    for (const header of ["x-forwarded-for", "x-real-ip", "cf-connecting-ip"]) {
        const candidates = (headers.get(header) ?? "")
            .split(",")
            .map(normalizeCandidate)
            .filter((candidate): candidate is string => candidate !== null);
        const candidate = candidates.at(-1);
        if (candidate) return candidate;
    }

    return "unknown";
}
