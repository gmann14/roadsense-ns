import { vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import HomePage from "@/app/page";
import MethodologyPage from "@/app/methodology/page";
import MunicipalityPage, { generateMetadata } from "@/app/municipality/[slug]/page";
import PrivacyPage from "@/app/privacy/page";
import WorstRoadsPage from "@/app/reports/worst-roads/page";
import { getMunicipalityBySlug, municipalityManifest } from "@/lib/municipality-manifest";
import { parseViewportState, withUpdatedRouteState } from "@/lib/url-state";

vi.mock("next/navigation", () => ({
  usePathname: () => "/",
  useRouter: () => ({
    push: vi.fn(),
    replace: vi.fn(),
  }),
  useSearchParams: () => new URLSearchParams(),
}));

describe("web route shells", () => {
  it("renders the home map shell", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain("Community road quality");
    expect(markup).toContain("RoadSense NS");
    expect(markup).toContain('aria-current="page"');
  });

  it("renders a municipality-focused shell for a valid slug", async () => {
    const markup = renderToStaticMarkup(
      await MunicipalityPage({ params: Promise.resolve({ slug: "halifax" }) }),
    );
    expect(markup).toContain("Halifax");
    expect(markup).toContain("Published community road-quality segments render live here");
    expect(markup).toContain("Halifax");
  });

  it("renders the worst-roads route shell", async () => {
    const markup = renderToStaticMarkup(await WorstRoadsPage());
    expect(markup).toContain("Worst Roads");
    expect(markup).toContain("Ranked public report");
  });

  it("renders methodology and privacy pages", () => {
    expect(renderToStaticMarkup(<MethodologyPage />)).toContain("How RoadSense turns passive driving");
    expect(renderToStaticMarkup(<PrivacyPage />)).toContain("Public map, private contributors");
  });
});

describe("web route helpers", () => {
  it("returns municipality metadata for a known slug", () => {
    expect(getMunicipalityBySlug("halifax")?.name).toBe("Halifax");
    expect(getMunicipalityBySlug("missing")).toBeNull();
  });

  it("keeps municipality names and slugs unique", () => {
    expect(new Set(municipalityManifest.map((entry) => entry.slug)).size).toBe(
      municipalityManifest.length,
    );
    expect(new Set(municipalityManifest.map((entry) => entry.name)).size).toBe(
      municipalityManifest.length,
    );
  });

  it("parses only documented query parameters", () => {
    const state = parseViewportState(
      new URLSearchParams("mode=coverage&segment=abc&lat=44.64&lng=-63.57&z=11.5&q=Halifax"),
    );

    expect(state).toEqual({
      mode: "coverage",
      segment: "abc",
      lat: 44.64,
      lng: -63.57,
      z: 11.5,
      q: "Halifax",
    });
  });

  it("updates route state without leaving stale params behind", () => {
    const nextParams = withUpdatedRouteState(
      new URLSearchParams("mode=quality&segment=abc&lat=44.64&lng=-63.57&z=11.5"),
      {
        mode: "coverage",
        segment: null,
      },
    );

    expect(nextParams.get("mode")).toBe("coverage");
    expect(nextParams.get("segment")).toBeNull();
  });

  it("generates municipality metadata copy", async () => {
    const metadata = await generateMetadata({
      params: Promise.resolve({ slug: "halifax" }),
    });

    expect(metadata.title).toBe("Road conditions in Halifax | RoadSense NS");
  });
});
