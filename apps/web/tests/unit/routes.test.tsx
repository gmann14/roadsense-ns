import { vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import HomePage from "@/app/page";
import MethodologyPage from "@/app/methodology/page";
import MunicipalityPage, { generateMetadata } from "@/app/municipality/[slug]/page";
import PrivacyPage from "@/app/privacy/page";
import PrivacyAndCountsPage from "@/app/privacy-and-counts/page";
import MostReportedPotholesPage from "@/app/reports/potholes/page";
import WorstRoadsPage from "@/app/reports/worst-roads/page";
import {
  getMunicipalityBackendName,
  getMunicipalityBySlug,
  municipalityManifest,
} from "@/lib/municipality-manifest";
import { parseViewportState, withUpdatedRouteState } from "@/lib/url-state";

vi.mock("next/navigation", () => ({
  redirect: (href: string) => {
    throw new Error(`NEXT_REDIRECT ${href}`);
  },
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
    expect(markup).toContain("RoadSense NS");
    expect(markup).toContain('aria-current="page"');
  });

  it("renders a plain-English freshness pill in the topbar", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain('class="freshness-pill"');
    expect(markup).toContain('role="status"');
    // No live API in tests → null generated_at → pending state.
    expect(markup).toContain("Awaiting first publish");
    expect(markup).toContain('data-state="pending"');
  });

  it("groups primary nav links into the design's pill group", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain('class="top-nav-pill-group"');
    expect(markup).toContain("top-nav-brand-mark");
    expect(markup).not.toContain('href="/reports/worst-roads"');
    expect(markup).not.toContain('href="/reports/potholes"');
    expect(markup).not.toContain('href="/privacy-and-counts"');
  });

  it("renders a municipality-focused shell for a valid slug", async () => {
    const markup = renderToStaticMarkup(
      await MunicipalityPage({ params: Promise.resolve({ slug: "halifax" }) }),
    );
    expect(markup).toContain("Halifax");
    expect(markup).toContain("Road quality in Halifax");
    expect(markup).toContain("Halifax");
  });

  it("redirects the unfinished worst-roads report back to the map", () => {
    expect(() => WorstRoadsPage()).toThrow(/NEXT_REDIRECT \//);
  });

  it("redirects the unfinished most-reported potholes report to pothole map mode", () => {
    expect(() => MostReportedPotholesPage()).toThrow(/NEXT_REDIRECT \/\?mode=potholes/);
  });

  it("renders methodology and privacy pages", () => {
    expect(renderToStaticMarkup(<MethodologyPage />)).toContain("How RoadSense builds the public map");
    expect(renderToStaticMarkup(<PrivacyPage />)).toContain("Public map, private contributors");
  });

  it("redirects the legacy privacy & counts route to privacy", () => {
    expect(() => PrivacyAndCountsPage()).toThrow(/NEXT_REDIRECT \/privacy/);
  });
});

describe("web route helpers", () => {
  it("returns municipality metadata for a known slug", () => {
    expect(getMunicipalityBySlug("halifax")?.name).toBe("Halifax");
    expect(getMunicipalityBySlug("municipality-of-the-district-of-lunenburg")?.name).toBe(
      "Municipality of the District of Lunenburg",
    );
    expect(getMunicipalityBySlug("missing")).toBeNull();
  });

  it("maps public municipality labels to backend import names", () => {
    const lunenburg = getMunicipalityBySlug("municipality-of-the-district-of-lunenburg");

    expect(lunenburg ? getMunicipalityBackendName(lunenburg) : null).toBe("Lunenburg");
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
