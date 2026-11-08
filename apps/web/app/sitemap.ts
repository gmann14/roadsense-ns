import type { MetadataRoute } from "next";

import { municipalityManifest } from "@/lib/municipality-manifest";
import { STATIC_PUBLIC_PATHS } from "@/lib/seo";
import { absoluteUrl } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const pages: MetadataRoute.Sitemap = STATIC_PUBLIC_PATHS.map((path) => ({
    url: absoluteUrl(path),
    changeFrequency: path === "/" ? "daily" : "monthly",
    priority: path === "/" ? 1 : 0.5,
  }));

  const municipalities: MetadataRoute.Sitemap = municipalityManifest.map((municipality) => ({
    url: absoluteUrl(`/municipality/${municipality.slug}`),
    changeFrequency: "daily",
    priority: 0.7,
  }));

  return [...pages, ...municipalities];
}
