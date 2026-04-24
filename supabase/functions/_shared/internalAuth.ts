export function isAuthorizedInternalRequest(headers: Headers, expectedSecret: string): boolean {
    if (!expectedSecret) {
        return false;
    }

    const authorization = headers.get("authorization") ?? "";
    const bearerToken = authorization.startsWith("Bearer ")
        ? authorization.slice("Bearer ".length).trim()
        : "";
    const apiKey = headers.get("apikey")?.trim() ?? "";

    return bearerToken === expectedSecret || apiKey === expectedSecret;
}
