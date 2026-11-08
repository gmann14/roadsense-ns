import type { NextConfig } from "next";

import { wwwToApexRedirects } from "./lib/redirects";
import { securityHeaders } from "./lib/security-headers";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  async redirects() {
    return wwwToApexRedirects();
  },
  // Applies to responses the Worker renders. Files served straight from
  // Workers Static Assets (/_next/static/*, public/*) get their headers from
  // public/_headers instead.
  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders({
          isDevelopment: process.env.NODE_ENV === "development",
          apiBaseUrl: process.env.NEXT_PUBLIC_API_BASE_URL ?? process.env.ROADSENSE_API_BASE_URL ?? null,
        }),
      },
    ];
  },
};

export default nextConfig;
