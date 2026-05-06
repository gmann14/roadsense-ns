import { vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import HomePage from "@/app/page";

vi.mock("next/navigation", () => ({
  usePathname: () => "/",
  useRouter: () => ({
    push: vi.fn(),
    replace: vi.fn(),
  }),
  useSearchParams: () => new URLSearchParams(),
}));

describe("home map shell — floating chrome", () => {
  it("renders the editorial hero copy from the design", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain("Nova Scotia&#x27;s roads, scored by the people who drive them");
    expect(markup).toContain('class="sr-only"');
  });

  it("renders three stat cards with truthful labels (no fabricated 'Contributing drivers')", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain("Roads mapped");
    expect(markup).toContain("Municipalities covered");
    expect(markup).toContain("Pothole reports");
    // Don't claim a metric we can't back with PublicStats today.
    expect(markup).not.toContain("Contributing drivers");
  });

  it("hides the trust strip on the home map page", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).not.toContain("trust-strip");
  });

  it("uses the full-bleed page-shell variant", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).toContain("page-shell--map");
  });

  it("renders the map controls without a visible headline card", async () => {
    const markup = renderToStaticMarkup(await HomePage());
    expect(markup).not.toContain("map-overlay map-headline");
    expect(markup).toContain("map-overlay stat-strip");
    expect(markup).toContain("map-overlay mode-switcher");
  });
});
