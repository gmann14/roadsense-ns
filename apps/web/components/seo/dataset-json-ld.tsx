import { datasetJsonLd, serializeJsonLd } from "@/lib/seo";

/** schema.org Dataset markup for the public road data (home and methodology). */
export function DatasetJsonLd() {
  return (
    <script
      type="application/ld+json"
      // Static, escaped JSON built in lib/seo.ts; no user input reaches it.
      dangerouslySetInnerHTML={{ __html: serializeJsonLd(datasetJsonLd()) }}
    />
  );
}
