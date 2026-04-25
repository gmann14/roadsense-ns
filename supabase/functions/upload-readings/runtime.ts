export type RpcResponse<T> = { data: T | null; error: { message?: string } | null };

let localEnvCache: Map<string, string> | null = null;

function parseDotEnv(contents: string): Map<string, string> {
    const values = new Map<string, string>();

    for (const rawLine of contents.split(/\r?\n/u)) {
        const line = rawLine.trim();
        if (line.length === 0 || line.startsWith("#")) {
            continue;
        }

        const separatorIndex = line.indexOf("=");
        if (separatorIndex <= 0) {
            continue;
        }

        const key = line.slice(0, separatorIndex).trim();
        const value = line.slice(separatorIndex + 1).trim();
        if (key.length > 0 && value.length > 0) {
            values.set(key, value);
        }
    }

    return values;
}

function readLocalFunctionEnv(): Map<string, string> {
    if (localEnvCache) {
        return localEnvCache;
    }

    const candidates = [
        "supabase/functions/.env",
        "functions/.env",
    ];

    for (const path of candidates) {
        try {
            localEnvCache = parseDotEnv(Deno.readTextFileSync(path));
            return localEnvCache;
        } catch {
            continue;
        }
    }

    localEnvCache = new Map();
    return localEnvCache;
}

export function requireEnv(name: string): string {
    const value = Deno.env.get(name) ?? readLocalFunctionEnv().get(name);
    if (!value) {
        throw new Error(`Missing required env var: ${name}`);
    }
    return value;
}

export async function sha256Hex(input: string): Promise<string> {
    const bytes = new TextEncoder().encode(input);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function hashDeviceToken(deviceToken: string): Promise<string> {
    return sha256Hex(`${deviceToken}${requireEnv("TOKEN_PEPPER")}`);
}

export function secondsUntilNextUtcDay(now: Date): number {
    const nextDay = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
    return Math.ceil((nextDay - now.getTime()) / 1000);
}

export function secondsUntilNextUtcHour(now: Date): number {
    const nextHour = Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate(),
        now.getUTCHours() + 1,
    );
    return Math.ceil((nextHour - now.getTime()) / 1000);
}

export function createRateLimitChecker(
    rpc: <T>(fn: string, params: Record<string, unknown>) => Promise<RpcResponse<T>>,
    nowFactory: () => Date = () => new Date(),
) {
    return async (tokenHashHex: string, ip: string) => {
        const now = nowFactory();
        const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
        const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));

        const deviceResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `dev:${tokenHashHex}`,
            p_bucket_start: dayBucket.toISOString(),
            p_limit: 50,
        });
        if (deviceResult.error) {
            throw new Error(deviceResult.error.message ?? "device rate limit RPC failed");
        }
        if (!deviceResult.data) {
            return {
                ok: false as const,
                retryAfterSeconds: secondsUntilNextUtcDay(now),
            };
        }

        const ipResult = await rpc<boolean>("check_and_bump_rate_limit", {
            p_key: `ip:${ip}`,
            p_bucket_start: hourBucket.toISOString(),
            p_limit: 10,
        });
        if (ipResult.error) {
            throw new Error(ipResult.error.message ?? "ip rate limit RPC failed");
        }
        if (!ipResult.data) {
            return {
                ok: false as const,
                retryAfterSeconds: secondsUntilNextUtcHour(now),
            };
        }

        return {
            ok: true as const,
            retryAfterSeconds: 0,
        };
    };
}
