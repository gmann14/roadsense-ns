import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import nextConfig from "@/next.config";
import { buildContentSecurityPolicy, ENFORCED_CSP, securityHeaders } from "@/lib/security-headers";

function directive(policy: string, name: string): string[] {
  const entry = policy
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${name} `));
  return entry ? entry.split(/\s+/).slice(1) : [];
}

describe("content security policy", () => {
  const production = buildContentSecurityPolicy({
    isDevelopment: false,
    apiBaseUrl: "https://api.nsroadsense.ca/functions/v1",
  });

  it("lets Mapbox GL run its blob: workers", () => {
    expect(directive(production, "worker-src")).toContain("blob:");
    expect(directive(production, "child-src")).toContain("blob:");
  });

  it("allows Mapbox and RoadSense hosts for tiles, images and API calls", () => {
    for (const host of [
      "https://api.mapbox.com",
      "https://events.mapbox.com",
      "https://*.tiles.mapbox.com",
      "https://api.nsroadsense.ca",
      "https://tiles.nsroadsense.ca",
    ]) {
      expect(directive(production, "connect-src")).toContain(host);
      expect(directive(production, "img-src")).toContain(host);
    }
    expect(directive(production, "connect-src").filter((value) => value === "https://api.nsroadsense.ca")).toHaveLength(1);
  });

  it("adds a custom API origin and ignores an invalid one", () => {
    const custom = buildContentSecurityPolicy({ isDevelopment: false, apiBaseUrl: "https://staging-api.example.test/v1" });
    expect(directive(custom, "connect-src")).toContain("https://staging-api.example.test");
    expect(() => buildContentSecurityPolicy({ isDevelopment: false, apiBaseUrl: "not a url" })).not.toThrow();
  });

  it("only allows eval and local websockets in development", () => {
    expect(directive(production, "script-src")).not.toContain("'unsafe-eval'");
    expect(directive(production, "connect-src")).not.toContain("ws:");

    const development = buildContentSecurityPolicy({ isDevelopment: true, apiBaseUrl: null });
    expect(directive(development, "script-src")).toContain("'unsafe-eval'");
    expect(directive(development, "connect-src")).toContain("ws:");
  });

  it("locks down framing, base, plugins and form targets", () => {
    for (const policy of [production, ENFORCED_CSP]) {
      expect(directive(policy, "frame-ancestors")).toEqual(["'none'"]);
      expect(directive(policy, "base-uri")).toEqual(["'self'"]);
      expect(directive(policy, "object-src")).toEqual(["'none'"]);
      expect(directive(policy, "form-action")).toEqual(["'self'"]);
    }
  });
});

describe("response headers", () => {
  it("sends HSTS, the enforced CSP and the full policy as Report-Only", () => {
    const headers = Object.fromEntries(
      securityHeaders({ isDevelopment: false, apiBaseUrl: null }).map(({ key, value }) => [key, value]),
    );

    expect(headers["Strict-Transport-Security"]).toBe("max-age=31536000");
    expect(headers["Content-Security-Policy"]).toBe(ENFORCED_CSP);
    expect(headers["Content-Security-Policy-Report-Only"]).toContain("worker-src 'self' blob:");
    expect(headers["X-Content-Type-Options"]).toBe("nosniff");
  });

  it("applies them to every route via next.config", async () => {
    const rules = (await nextConfig.headers?.()) ?? [];
    const all = rules.find((rule) => rule.source === "/:path*");
    expect(all?.headers.map((header) => header.key)).toEqual(
      expect.arrayContaining(["Strict-Transport-Security", "Content-Security-Policy", "Content-Security-Policy-Report-Only"]),
    );
  });

  it("serves hashed Next assets as immutable from public/_headers", () => {
    const rules = readFileSync(path.join(__dirname, "../../public/_headers"), "utf8");
    expect(rules).toMatch(/^\/_next\/static\/\*\n\s+Cache-Control: public, max-age=31536000, immutable$/m);
    expect(rules).toMatch(/Strict-Transport-Security: max-age=31536000/);
  });
});
