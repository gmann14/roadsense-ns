// Imported by next.config.ts, so keep this file free of "@/" path aliases.

export type HeaderEntry = { key: string; value: string };

type CspOptions = {
  /** next dev needs eval for React Refresh; production never gets it. */
  isDevelopment: boolean;
  /** NEXT_PUBLIC_API_BASE_URL; its origin is allowed for reads, tiles and feedback. */
  apiBaseUrl?: string | null;
};

/** Hosts Mapbox GL JS v3 talks to: styles, sprites, glyphs, vector/raster tiles, telemetry, search. */
const MAPBOX_HOSTS = ["https://api.mapbox.com", "https://*.tiles.mapbox.com", "https://events.mapbox.com"];
/** RoadSense API and tile hosts. */
const ROADSENSE_HOSTS = ["https://api.nsroadsense.ca", "https://tiles.nsroadsense.ca"];

function originOf(url: string | null | undefined): string | null {
  if (!url) {
    return null;
  }
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

function unique(values: Array<string | null>): string[] {
  return Array.from(new Set(values.filter((value): value is string => Boolean(value))));
}

/**
 * Directives that can't break the app: no framing, no <base> hijack, no
 * plugins, forms only post here. Shipped enforced.
 */
export const ENFORCED_CSP = "frame-ancestors 'none'; base-uri 'self'; object-src 'none'; form-action 'self'";

/**
 * Full policy for Mapbox GL JS + Next.js. Shipped as Report-Only until it has
 * been watched against the live map (see doc 07 "Security headers"): a wrong
 * directive here would blank the map, so violations are only logged in the
 * browser console for now.
 *
 * - script-src needs 'unsafe-inline' for Next's inline bootstrap/flight
 *   scripts (no nonce middleware on this static-friendly deploy).
 * - Mapbox GL v3 runs its workers from blob: URLs (worker-src / child-src).
 * - style-src 'unsafe-inline' covers Mapbox GL's and React's inline styles.
 */
export function buildContentSecurityPolicy({ isDevelopment, apiBaseUrl }: CspOptions): string {
  const apiOrigin = originOf(apiBaseUrl);
  const remote = unique([...MAPBOX_HOSTS, ...ROADSENSE_HOSTS, apiOrigin]);
  const scriptSrc = ["'self'", "'unsafe-inline'", ...(isDevelopment ? ["'unsafe-eval'"] : [])];
  const connectSrc = ["'self'", ...remote, ...(isDevelopment ? ["ws:", "http://127.0.0.1:*", "http://localhost:*"] : [])];

  const directives: Array<[string, string[]]> = [
    ["default-src", ["'self'"]],
    ["script-src", scriptSrc],
    ["style-src", ["'self'", "'unsafe-inline'"]],
    ["img-src", ["'self'", "data:", "blob:", ...remote]],
    ["font-src", ["'self'", "data:"]],
    ["connect-src", unique(connectSrc)],
    ["worker-src", ["'self'", "blob:"]],
    ["child-src", ["'self'", "blob:"]],
    ["manifest-src", ["'self'"]],
    ["frame-ancestors", ["'none'"]],
    ["base-uri", ["'self'"]],
    ["object-src", ["'none'"]],
    ["form-action", ["'self'"]],
  ];

  return directives.map(([name, values]) => `${name} ${values.join(" ")}`).join("; ");
}

/** Headers for every worker-rendered response (static assets get theirs from public/_headers). */
export function securityHeaders(options: CspOptions): HeaderEntry[] {
  return [
    { key: "Strict-Transport-Security", value: "max-age=31536000" },
    { key: "Content-Security-Policy", value: ENFORCED_CSP },
    { key: "Content-Security-Policy-Report-Only", value: buildContentSecurityPolicy(options) },
    { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
    { key: "X-Content-Type-Options", value: "nosniff" },
    { key: "X-Frame-Options", value: "DENY" },
    { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
  ];
}
