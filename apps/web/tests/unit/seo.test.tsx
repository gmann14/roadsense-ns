import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import { metadata as rootMetadata } from "@/app/layout";
import HomePage, { metadata as homeMetadata } from "@/app/page";
import MethodologyPage, { metadata as methodologyMetadata } from "@/app/methodology/page";
import { generateMetadata as municipalityMetadata } from "@/app/municipality/[slug]/page";
import { metadata as privacyMetadata } from "@/app/privacy/page";
import robots from "@/app/robots";
import sitemap from "@/app/sitemap";
import { metadata as supportMetadata } from "@/app/support/page";
import { metadata as termsMetadata } from "@/app/terms/page";
import { municipalityManifest } from "@/lib/municipality-manifest";
import { wwwToApexRedirects } from "@/lib/redirects";
import { datasetJsonLd, serializeJsonLd } from "@/lib/seo";
import { absoluteUrl } from "@/lib/site";

vi.mock("next/font/google", () => {
  const font = () => ({ variable: "font" });
  return { Fraunces: font, IBM_Plex_Mono: font, Manrope: font };
});

vi.mock("next/navigation", () => ({
  usePathname: () => "/",
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
}));

describe("site metadata", () => {
  it("sets metadataBase to the canonical origin without a site-wide canonical", () => {
    expect(rootMetadata.metadataBase?.toString()).toBe("https://nsroadsense.ca/");
    expect(rootMetadata.alternates).toBeUndefined();
    expect(rootMetadata.description).not.toMatch(/nightly/);
  });

  it.each([
    ["/", homeMetadata],
    ["/methodology", methodologyMetadata],
    ["/privacy", privacyMetadata],
    ["/terms", termsMetadata],
    ["/support", supportMetadata],
  ])("gives %s a canonical URL and matching social cards", (path, metadata) => {
    const url = absoluteUrl(path);
    expect(metadata.alternates?.canonical).toBe(url);
    expect(metadata.openGraph).toMatchObject({ url, siteName: "RoadSense NS", title: metadata.title });
    expect(metadata.twitter).toMatchObject({ card: "summary", title: metadata.title });
    expect(typeof metadata.description).toBe("string");
  });

  it("builds municipality titles, descriptions and canonicals from the slug", async () => {
    const metadata = await municipalityMetadata({ params: Promise.resolve({ slug: "halifax" }) });

    expect(metadata.title).toBe("Road conditions in Halifax | RoadSense NS");
    expect(metadata.description).toContain("Halifax");
    expect(metadata.alternates?.canonical).toBe("https://nsroadsense.ca/municipality/halifax");
    expect(metadata.openGraph).toMatchObject({
      url: "https://nsroadsense.ca/municipality/halifax",
      title: "Road conditions in Halifax | RoadSense NS",
    });
  });

  it("keeps unknown municipalities out of the index", async () => {
    const metadata = await municipalityMetadata({ params: Promise.resolve({ slug: "nowhere" }) });
    expect(metadata.robots).toEqual({ index: false });
    expect(metadata.alternates).toBeUndefined();
  });
});

describe("sitemap and robots", () => {
  it("lists every public page and every municipality", () => {
    const urls = sitemap().map((entry) => entry.url);

    for (const path of ["/", "/methodology", "/privacy", "/terms", "/support"]) {
      expect(urls).toContain(absoluteUrl(path));
    }
    for (const municipality of municipalityManifest) {
      expect(urls).toContain(`https://nsroadsense.ca/municipality/${municipality.slug}`);
    }
    expect(new Set(urls).size).toBe(urls.length);
    expect(urls.some((url) => url.includes("/reports") || url.includes("privacy-and-counts"))).toBe(false);
  });

  it("allows crawling and points at the sitemap", () => {
    const result = robots();
    expect(result.rules).toEqual([{ userAgent: "*", allow: "/" }]);
    expect(result.sitemap).toBe("https://nsroadsense.ca/sitemap.xml");
  });
});

describe("Dataset JSON-LD", () => {
  it("describes an ODbL dataset covering Nova Scotia", () => {
    const dataset = datasetJsonLd();
    expect(dataset["@type"]).toBe("Dataset");
    expect(dataset.license).toBe("https://opendatacommons.org/licenses/odbl/1-0/");
    expect(dataset.spatialCoverage).toMatchObject({ name: "Nova Scotia, Canada" });
  });

  it("escapes < so the JSON can't close its script tag", () => {
    expect(serializeJsonLd({ name: "</script><script>alert(1)</script>" })).not.toContain("</script>");
  });

  it("is rendered on the home and methodology pages", async () => {
    for (const page of [await HomePage(), await MethodologyPage()]) {
      const markup = renderToStaticMarkup(page);
      const match = markup.match(/<script type="application\/ld\+json">(.*?)<\/script>/);
      expect(match).not.toBeNull();
      expect(JSON.parse(match?.[1] ?? "{}")["@type"]).toBe("Dataset");
    }
  });
});

describe("www to apex redirect", () => {
  it("sends www traffic to the apex with a 301, keeping the path", () => {
    expect(wwwToApexRedirects()).toEqual([
      {
        source: "/:path*",
        has: [{ type: "host", value: "www.nsroadsense.ca" }],
        destination: "https://nsroadsense.ca/:path*",
        statusCode: 301,
      },
    ]);
  });
});
