import { vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { PotholesExplorer } from "@/components/reports/potholes-explorer";
import { PotholesShell } from "@/components/reports/potholes-shell";
import type { PotholeRow } from "@/lib/api/client";

afterEach(() => {
  cleanup();
});

vi.mock("next/navigation", () => ({
  usePathname: () => "/reports/potholes",
  useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
}));

const sampleRows: PotholeRow[] = [
  {
    id: "p-1",
    lat: 44.6488,
    lng: -63.5752,
    magnitude: 3.4,
    confirmation_count: 12,
    first_reported_at: "2026-04-01T12:00:00Z",
    last_confirmed_at: "2026-05-01T12:00:00Z",
    status: "active",
    segment_id: "seg-1",
  },
  {
    id: "p-2",
    lat: 45.0918,
    lng: -64.3683,
    magnitude: 2.1,
    confirmation_count: 7,
    first_reported_at: "2026-03-20T12:00:00Z",
    last_confirmed_at: "2026-04-20T12:00:00Z",
    status: "active",
    segment_id: null,
  },
];

describe("potholes shell — split layout", () => {
  it("renders a row per pothole with rank, location, magnitude, confirmations", () => {
    const markup = renderToStaticMarkup(
      <PotholesShell limit={20} rows={sampleRows} activePotholeCount={2} generatedAt={null} />,
    );

    expect(markup).toContain("Most-reported potholes");
    expect(markup).toContain("Community pothole report");
    expect(markup).toContain("class=\"pothole-row");
    expect(markup).toContain("#1");
    expect(markup).toContain("#2");
    expect(markup).toContain("12 confirmations");
    expect(markup).toContain("magnitude 3.4");
  });

  it("renders the photo placeholder and disabled future actions on the detail card", () => {
    const markup = renderToStaticMarkup(
      <PotholesShell limit={20} rows={sampleRows} activePotholeCount={2} generatedAt={null} />,
    );

    expect(markup).toContain("Photo · coming soon");
    expect(markup).toMatch(/aria-label="Mark as fixed \(coming soon\)"[^>]*disabled/);
    expect(markup).toMatch(/aria-label="Comment \(coming soon\)"[^>]*disabled/);
    expect(markup).toContain("How is this measured?");
  });

  it("links each row to /?mode=potholes&lat=…&lng=… on the main map", () => {
    const markup = renderToStaticMarkup(
      <PotholesShell limit={20} rows={sampleRows} activePotholeCount={2} generatedAt={null} />,
    );

    expect(markup).toContain("/?mode=potholes&amp;lat=44.64880&amp;lng=-63.57520");
    expect(markup).toContain("/?mode=potholes&amp;lat=45.09180&amp;lng=-64.36830");
  });
});

describe("potholes explorer — client interactions", () => {
  it("updates the detail card when a row is clicked", () => {
    render(<PotholesExplorer rows={sampleRows} activePotholeCount={2} />);

    const detailHeading = screen.getByTestId("pothole-detail-coords");
    expect(detailHeading.textContent).toMatch(/44\.6488/);

    fireEvent.click(screen.getByRole("button", { name: /pothole #2/i }));
    expect(screen.getByTestId("pothole-detail-coords").textContent).toMatch(/45\.0918/);
  });

  it("distinguishes an unavailable report feed from an empty pothole dataset", () => {
    render(<PotholesExplorer rows={[]} activePotholeCount={196} listUnavailable />);

    expect(screen.getByText(/report list unavailable/i)).toBeInTheDocument();
    expect(screen.getByText(/196 active pothole reports exist/i)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /open pothole map/i })).toHaveAttribute("href", "/?mode=potholes");
  });
});
