// Imported by next.config.ts, so keep this file free of "@/" path aliases.

export const APEX_HOST = "nsroadsense.ca";

export type HostRedirect = {
  source: string;
  has: Array<{ type: "host"; value: string }>;
  destination: string;
  statusCode: 301;
};

/**
 * www.nsroadsense.ca -> nsroadsense.ca with a 301 (Next's `permanent: true`
 * would send 308), keeping the path; Next carries the query string over.
 * Takes effect once the www hostname is routed to this Worker.
 */
export function wwwToApexRedirects(): HostRedirect[] {
  return [
    {
      source: "/:path*",
      has: [{ type: "host", value: `www.${APEX_HOST}` }],
      destination: `https://${APEX_HOST}/:path*`,
      statusCode: 301,
    },
  ];
}
