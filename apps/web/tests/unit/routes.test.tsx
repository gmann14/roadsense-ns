import { vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { AppShell } from "@/components/chrome/app-shell";
import HomePage from "@/app/page";
import MethodologyPage from "@/app/methodology/page";
import MunicipalityPage, { generateMetadata } from "@/app/municipality/[slug]/page";
import PrivacyPage from "@/app/privacy/page";
import PrivacyAndCountsPage from "@/app/privacy-and-counts/page";
import SupportPage from "@/app/support/page";
import TermsPage from "@/app/terms/page";
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

  it("hides the freshness pill when the API gives no data_updated_at", async () => {
    // No live API in tests → stats unavailable → no freshness claim at all.
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).not.toContain('class="freshness-pill"');
    expect(markup).not.toContain("Updated today");
  });

  it("renders a plain-English freshness pill from data_updated_at", () => {
    const markup = renderToStaticMarkup(
      <AppShell dataUpdatedAt={new Date().toISOString()}>
        <p>content</p>
      </AppShell>,
    );
    expect(markup).toContain('class="freshness-pill"');
    expect(markup).toContain("Updated today");
  });

  it("tells visitors when live stats are unavailable instead of showing zeros", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain("Live stats are unavailable right now.");
  });

  it("groups primary nav links in the top navigation", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain('class="top-nav-links"');
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

  it("renders methodology and privacy pages", async () => {
    expect(renderToStaticMarkup(await MethodologyPage())).toContain("How RoadSense builds the public map");
    expect(renderToStaticMarkup(await PrivacyPage())).toContain("Public map, private contributors");
  });

  it("renders static terms and support pages with the site footer", () => {
    const terms = renderToStaticMarkup(TermsPage());
    const support = renderToStaticMarkup(SupportPage());

    expect(terms).toContain("Never handle your phone while driving");
    expect(support).toContain("Frequently asked questions");
    for (const markup of [terms, support]) {
      expect(markup).toContain('class="site-footer"');
      expect(markup).toContain('href="/terms"');
      expect(markup).toContain('href="/support"');
      expect(markup).toContain('href="/privacy"');
    }
  });

  it("links support from the primary navigation", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain('href="/support"');
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
