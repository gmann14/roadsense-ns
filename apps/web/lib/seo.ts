import type { Metadata } from "next";

import { absoluteUrl, ODBL_URL, SITE_DESCRIPTION, SITE_NAME, SITE_URL } from "@/lib/site";

type PageMetadataInput = {
  /** Site path, e.g. "/privacy". Becomes the canonical URL. */
  path: string;
  /** Page title without the site suffix; omit for the home page. */
  title?: string;
  description?: string;
};

/** Full `<title>` for a page: "Privacy policy | RoadSense NS". */
export function pageTitle(title?: string): string {
  return title ? `${title} | ${SITE_NAME}` : `${SITE_NAME} — community road quality for Nova Scotia`;
}

/**
 * Per-page metadata with a canonical URL and matching Open Graph / Twitter
 * cards. Query strings (map mode, segment, viewport) never reach the
 * canonical, so shared map links all consolidate on the page itself.
 */
export function pageMetadata({ path, title, description = SITE_DESCRIPTION }: PageMetadataInput): Metadata {
  const fullTitle = pageTitle(title);
  const url = absoluteUrl(path);

  return {
    title: fullTitle,
    description,
    alternates: { canonical: url },
    openGraph: {
      type: "website",
      siteName: SITE_NAME,
      locale: "en_CA",
      url,
      title: fullTitle,
      description,
    },
    twitter: {
      card: "summary",
      title: fullTitle,
      description,
    },
  };
}

/**
 * Layout-level defaults. Deliberately no canonical or og:url: every page sets
 * its own via pageMetadata, and a 404 must not claim to be the home page.
 */
export function siteDefaultMetadata(): Metadata {
  const title = pageTitle();
  return {
    title,
    description: SITE_DESCRIPTION,
    openGraph: { type: "website", siteName: SITE_NAME, locale: "en_CA", title, description: SITE_DESCRIPTION },
    twitter: { card: "summary", title, description: SITE_DESCRIPTION },
  };
}

/** Static, public routes listed in the sitemap (municipality pages are added separately). */
export const STATIC_PUBLIC_PATHS = ["/", "/methodology", "/privacy", "/terms", "/support"] as const;

/**
 * schema.org Dataset description of the public road-quality data, for
 * search engines' dataset results. Serialized into a JSON-LD script tag.
 */
export function datasetJsonLd(): Record<string, unknown> {
  return {
    "@context": "https://schema.org",
    "@type": "Dataset",
    name: "RoadSense NS road quality, potholes and coverage",
    description:
      "Community-measured road roughness, pothole reports and coverage for Nova Scotia, aggregated to OpenStreetMap road segments. A segment is published only once at least 3 different contributors have data on it, and public timestamps are rounded to the day.",
    url: absoluteUrl("/"),
    sameAs: absoluteUrl("/methodology"),
    license: ODBL_URL,
    isAccessibleForFree: true,
    inLanguage: "en-CA",
    keywords: ["road quality", "potholes", "road roughness", "Nova Scotia", "crowdsourced", "OpenStreetMap"],
    creator: { "@type": "Organization", name: SITE_NAME, url: SITE_URL },
    spatialCoverage: {
      "@type": "Place",
      name: "Nova Scotia, Canada",
      geo: { "@type": "GeoShape", box: "43.3 -66.5 47.1 -59.6" },
    },
    isBasedOn: "https://www.openstreetmap.org/",
    creditText: "RoadSense NS and © OpenStreetMap contributors",
  };
}

/** JSON for a `<script type="application/ld+json">`, with `<` escaped so it can't close the tag. */
export function serializeJsonLd(value: Record<string, unknown>): string {
  return JSON.stringify(value).replace(/</g, "\\u003c");
}
