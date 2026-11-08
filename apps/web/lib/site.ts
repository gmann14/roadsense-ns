/**
 * Site-wide facts shared by page copy, metadata, and tests. Keep numbers here
 * in sync with the code that enforces them (noted per constant) so public
 * copy can't drift from behaviour again.
 */

const DEFAULT_SITE_URL = "https://nsroadsense.ca";

/** Canonical origin, no trailing slash. Override with NEXT_PUBLIC_SITE_URL for previews. */
export const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL?.trim() || DEFAULT_SITE_URL).replace(/\/+$/, "");
export const SITE_HOST = new URL(SITE_URL).host;
export const SITE_NAME = "RoadSense NS";
export const SITE_DESCRIPTION =
  "A public, crowdsourced map of Nova Scotia road roughness, potholes, and coverage, built from drivers' phones and published only as road-level averages.";

/** Privacy, support and data-request contact. Same address as the App Store listing contact. */
export const CONTACT_EMAIL = "graham.mann14@gmail.com";

/** Effective date of the current privacy policy and terms of use. */
export const POLICY_EFFECTIVE_DATE = "November 8, 2026";

/**
 * Public k-anonymity floor: a road segment is published only once this many
 * different contributors have data on it (server-side tile/segment gating).
 * Also the "medium" confidence threshold in the aggregate recompute.
 */
export const MIN_CONTRIBUTORS_PUBLIC = 3;
/** "high" confidence threshold (supabase/migrations, aggregate recompute). */
export const MIN_CONTRIBUTORS_HIGH_CONFIDENCE = 10;
/** On-device speed floor (ios/.../Pipeline/QualityFilter.swift). */
export const MIN_SPEED_KMH = 15;

export const OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright";
export const ODBL_URL = "https://opendatacommons.org/licenses/odbl/1-0/";

/** Absolute URL for a site path ("/privacy" -> "https://nsroadsense.ca/privacy"). */
export function absoluteUrl(path: string): string {
  if (path === "" || path === "/") {
    return `${SITE_URL}/`;
  }
  return `${SITE_URL}${path.startsWith("/") ? path : `/${path}`}`;
}
