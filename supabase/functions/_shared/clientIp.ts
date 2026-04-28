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

export function extractClientIp(headers: Headers): string {
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
