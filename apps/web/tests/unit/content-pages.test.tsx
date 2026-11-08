import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { MethodologyContent } from "@/components/content/methodology-content";
import { PrivacyContent } from "@/components/content/privacy-content";
import { SupportContent } from "@/components/content/support-content";
import { TermsContent } from "@/components/content/terms-content";

afterEach(() => {
  cleanup();
});

describe("content pages", () => {
  it("renders the methodology hero copy", () => {
    render(<MethodologyContent />);
    expect(screen.getByRole("heading", { name: /How RoadSense builds the public map/i })).toBeInTheDocument();
  });

  it("does not render table-of-contents pills", () => {
    render(<MethodologyContent />);
    expect(screen.queryByRole("navigation", { name: /methodology sections/i })).not.toBeInTheDocument();
  });

  it("renders a 4-step collection pipeline diagram", () => {
    const { container } = render(<MethodologyContent />);
    expect(container.querySelectorAll(".pipeline-step")).toHaveLength(4);
    expect(screen.getByText(/Phone records/i)).toBeInTheDocument();
    expect(screen.getByText(/Map publishes/i)).toBeInTheDocument();
  });

  it("renders a 3-tier confidence diagram", () => {
    const { container } = render(<MethodologyContent />);
    const tiers = container.querySelectorAll(".confidence-tier");
    expect(tiers).toHaveLength(3);
    const labels = Array.from(container.querySelectorAll(".confidence-tier-label")).map(
      (node) => node.textContent,
    );
    expect(labels).toEqual(["Low confidence", "Medium confidence", "High confidence"]);
  });

  it("states the confidence thresholds the backend actually uses", () => {
    const { container } = render(<MethodologyContent />);
    const counts = Array.from(container.querySelectorAll(".confidence-tier-count")).map((node) => node.textContent);
    expect(counts).toEqual(["1–2 drivers", "3–9 drivers", "10+ drivers"]);
    expect(container.textContent).not.toMatch(/\b(6|22|78) drives\b/);
  });

  it("states the on-device speed cutoff and the public contributor floor", () => {
    const { container } = render(<MethodologyContent />);
    expect(container.textContent).toContain("below 15 km/h");
    expect(container.textContent).not.toContain("25 km/h");
    expect(container.textContent).toMatch(/at least 3 different drivers/);
    expect(container.textContent).toMatch(/rounded to the\s+day/);
  });

  it("links the ODbL licence and OpenStreetMap attribution", () => {
    render(<MethodologyContent />);
    expect(screen.getByRole("link", { name: "ODbL" })).toHaveAttribute(
      "href",
      "https://opendatacommons.org/licenses/odbl/1-0/",
    );
    expect(screen.getByRole("link", { name: /© OpenStreetMap contributors/ })).toHaveAttribute(
      "href",
      "https://www.openstreetmap.org/copyright",
    );
  });

  it("renders the map limits list", () => {
    const { container } = render(<MethodologyContent />);
    const items = container.querySelectorAll(".method-not-list li");
    expect(items.length).toBe(4);
    expect(screen.getByText(/Not a maintenance queue/i)).toBeInTheDocument();
    expect(screen.getByText(/Not emergency reporting/i)).toBeInTheDocument();
    expect(screen.getByText(/Not surveillance/i)).toBeInTheDocument();
    expect(screen.getByText(/Not complete coverage/i)).toBeInTheDocument();
  });

  it("renders a privacy policy that covers both apps and is dated", () => {
    const { container } = render(<PrivacyContent />);
    const text = container.textContent ?? "";

    expect(text).toMatch(/iPhone and Android/);
    expect(text).toContain("Effective November 8, 2026");
    expect(screen.getByText(/Private places are removed before upload/i)).toBeInTheDocument();
    expect(text).toMatch(/about 6–7 months after collection/);
    expect(text).toMatch(/at least 3\s+different contributors/);
    expect(text).toMatch(/rounded to the day/);
    expect(screen.getAllByRole("link", { name: /graham\.mann14@gmail\.com/i })[0]).toHaveAttribute(
      "href",
      "mailto:graham.mann14@gmail.com",
    );
  });

  it("lists every service provider and cross-border processing", () => {
    const { container } = render(<PrivacyContent />);
    const providers = Array.from(container.querySelectorAll("#processors dt")).map(
      (node) => node.childNodes[0]?.textContent,
    );
    expect(providers).toEqual(["Railway", "Cloudflare", "Mapbox", "Sentry", "Apple and Google"]);
    expect(container.textContent).toMatch(/outside Canada, mainly\s+in the United States/);
  });

  it("is honest about disabled and not-yet-automatic features", () => {
    const { container } = render(<PrivacyContent />);
    const text = container.textContent ?? "";
    expect(text).toMatch(/Photo uploads are switched off/);
    expect(text).toMatch(/aren.t switched on yet/);
    expect(text).not.toMatch(/kept for up to 6 months/);
  });

  it("links the terms and support pages from the privacy policy", () => {
    render(<PrivacyContent />);
    expect(screen.getByRole("link", { name: /terms of use/i })).toHaveAttribute("href", "/terms");
    expect(screen.getByRole("link", { name: /support page/i })).toHaveAttribute("href", "/support");
  });
});

describe("terms of use", () => {
  it("covers safety, no warranty, endorsement, licences and governing law", () => {
    const { container } = render(<TermsContent />);
    const text = container.textContent ?? "";

    expect(text).toContain("Effective November 8, 2026");
    expect(text).toMatch(/Don.t use it for navigation/);
    expect(text).toMatch(/don.t touch the app while the vehicle is moving/);
    expect(text).toMatch(/without warranties of any\s+kind/);
    expect(text).toMatch(/isn.t run, funded or endorsed by the\s+Province of Nova Scotia, any municipality/);
    expect(text).toMatch(/royalty-free, non-exclusive, perpetual licence/);
    expect(text).toMatch(/licence plates/);
    expect(text).toMatch(/laws of Nova Scotia and the federal laws of Canada/);
    for (const id of ["safety", "informational", "endorsement", "contributions", "photos", "open-data", "warranty", "law", "contact"]) {
      expect(container.querySelector(`#${id}`)).not.toBeNull();
    }
  });

  it("publishes aggregated data under ODbL 1.0 with OSM attribution", () => {
    render(<TermsContent />);
    expect(screen.getByRole("link", { name: /Open Database License \(ODbL\) 1\.0/ })).toHaveAttribute(
      "href",
      "https://opendatacommons.org/licenses/odbl/1-0/",
    );
    expect(screen.getByRole("link", { name: /© OpenStreetMap contributors/ })).toHaveAttribute(
      "href",
      "https://www.openstreetmap.org/copyright",
    );
  });
});

describe("support page", () => {
  it("answers the App Store support questions", () => {
    const { container } = render(<SupportContent />);
    const ids = Array.from(container.querySelectorAll(".content-faq details")).map((node) => node.id);

    expect(ids).toEqual(
      expect.arrayContaining(["battery", "privacy-zones", "my-roads", "delete-local", "delete-server", "platforms"]),
    );
    expect(container.querySelector("#my-roads")?.textContent).toMatch(/at least 3 different drivers/);
    expect(container.querySelector("#delete-local")?.textContent).toContain("Delete local contribution data");
    expect(container.querySelector("#delete-local")?.textContent).toContain("Delete local data");
    expect(container.querySelector("#platforms")?.textContent).toMatch(/iPhone/);
    expect(container.querySelector("#platforms")?.textContent).toMatch(/Android/);
  });

  it("gives a contact email and links the policies", () => {
    render(<SupportContent />);
    expect(screen.getAllByRole("link", { name: "graham.mann14@gmail.com" })[0]).toHaveAttribute(
      "href",
      "mailto:graham.mann14@gmail.com",
    );
    const hrefs = (name: string) =>
      screen.getAllByRole("link", { name }).map((link) => link.getAttribute("href"));
    expect(hrefs("privacy policy")).toContain("/privacy");
    expect(hrefs("terms of use")).toContain("/terms");
  });
});
