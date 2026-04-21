import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ModeSwitcher } from "@/components/map/mode-switcher";
import { MunicipalitySearch } from "@/components/map/municipality-search";
import { SegmentDrawerPanel } from "@/components/map/segment-drawer";
import type { SegmentDetail } from "@/lib/api/client";
import { searchMunicipalities } from "@/lib/municipality-manifest";

afterEach(() => {
  cleanup();
});

vi.mock("next/navigation", () => ({
  usePathname: () => "/",
  useRouter: () => ({
    push: vi.fn(),
    replace: vi.fn(),
  }),
}));

const { searchPlacesMock } = vi.hoisted(() => ({
  searchPlacesMock: vi.fn(async () => []),
}));

vi.mock("@/lib/search/mapbox-geocoding", () => ({
  searchPlaces: searchPlacesMock,
}));

describe("map mode switcher", () => {
  it("renders every documented mode and calls onSelect", () => {
    const onSelect = vi.fn();

    render(<ModeSwitcher activeMode="quality" onSelect={onSelect} />);

    fireEvent.click(screen.getByRole("button", { name: /coverage/i }));
    expect(onSelect).toHaveBeenCalledWith("coverage");
    expect(screen.getByRole("button", { name: /quality/i })).toHaveAttribute("aria-pressed", "true");
  });
});

describe("segment drawer accessibility", () => {
  it("marks the drawer busy while loading", () => {
    render(
      <SegmentDrawerPanel
        mode="quality"
        selectedSegmentId="seg-loading"
        detail={null}
        potholes={[]}
        isLoading
        errorMessage={null}
        onClearSelection={vi.fn()}
      />,
    );

    expect(screen.getByRole("complementary")).toHaveAttribute("aria-busy", "true");
  });
});

describe("municipality search", () => {
  it("matches municipalities by alias as well as canonical name", () => {
    expect(searchMunicipalities("HRM")[0]?.municipality.slug).toBe("halifax");
    expect(searchMunicipalities("cape breton")[0]?.municipality.slug).toBe(
      "cape-breton-regional-municipality",
    );
  });

  it("renders a municipality-first quick-jump input", () => {
    render(<MunicipalitySearch activeMode="quality" currentQuery="Halifax" />);

    expect(screen.getByPlaceholderText(/halifax, truro, kentville/i)).toBeInTheDocument();
    expect(screen.getByDisplayValue("Halifax")).toBeInTheDocument();
  });

  it("renders ranked municipality suggestions for partial matches", () => {
    render(<MunicipalitySearch activeMode="quality" currentQuery="Cape" />);

    expect(screen.getByRole("listbox", { name: /search suggestions/i })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /cape breton regional municipality/i })).toBeInTheDocument();
  });

  it("shows a recoverable no-results state when neither municipalities nor places match", async () => {
    searchPlacesMock.mockResolvedValueOnce([]);

    render(<MunicipalitySearch activeMode="quality" currentQuery="zzzzzz" />);

    expect(await screen.findByText(/no municipality or place match/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /clear/i })).toBeInTheDocument();
  });
});

describe("segment drawer panel", () => {
  it("renders an empty-selection prompt in quality mode", () => {
    render(
      <SegmentDrawerPanel
        mode="quality"
        selectedSegmentId={null}
        detail={null}
        potholes={[]}
        isLoading={false}
        errorMessage={null}
        onClearSelection={vi.fn()}
      />,
    );

    expect(screen.getByText(/select a road to inspect/i)).toBeInTheDocument();
  });

  it("renders segment detail metrics when a segment is available", () => {
    const detail: SegmentDetail = {
      id: "seg-1",
      road_name: "Barrington Street",
      road_type: "primary",
      municipality: "Halifax",
      length_m: 48.7,
      has_speed_bump: false,
      has_rail_crossing: false,
      surface_type: "asphalt",
      aggregate: {
        avg_roughness_score: 0.72,
        category: "rough",
        confidence: "high",
        total_readings: 137,
        unique_contributors: 34,
        pothole_count: 2,
        trend: "worsening",
        score_last_30d: 0.78,
        score_30_60d: 0.69,
        last_reading_at: "2026-04-16T22:15:00Z",
        updated_at: "2026-04-17T03:15:00Z",
      },
      history: [],
      neighbors: null,
    };

    render(
      <SegmentDrawerPanel
        mode="quality"
        selectedSegmentId="seg-1"
        detail={detail}
        potholes={[]}
        isLoading={false}
        errorMessage={null}
        onClearSelection={vi.fn()}
      />,
    );

    expect(screen.getAllByText("Barrington Street").length).toBeGreaterThan(0);
    expect(screen.getByText(/high confidence/i)).toBeInTheDocument();
    expect(screen.getByText("137")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
  });

  it("renders a recoverable error state when the fetch fails", () => {
    const onClearSelection = vi.fn();

    render(
      <SegmentDrawerPanel
        mode="quality"
        selectedSegmentId="seg-404"
        detail={null}
        potholes={[]}
        isLoading={false}
        errorMessage="We could not load details for this road segment."
        onClearSelection={onClearSelection}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /clear selection/i }));
    expect(onClearSelection).toHaveBeenCalledTimes(1);
  });

  it("renders pothole rows when potholes mode has viewport data", () => {
    render(
      <SegmentDrawerPanel
        mode="potholes"
        selectedSegmentId={null}
        detail={null}
        potholes={[
          {
            id: "p-1",
            lat: 44.64,
            lng: -63.57,
            magnitude: 2.4,
            confirmation_count: 7,
            first_reported_at: "2026-04-01T12:00:00Z",
            last_confirmed_at: "2026-04-16T08:00:00Z",
            status: "active",
            segment_id: "seg-1",
          },
        ]}
        isLoading={false}
        errorMessage={null}
        onClearSelection={vi.fn()}
      />,
    );

    expect(screen.getByText(/active community potholes in this view/i)).toBeInTheDocument();
    expect(screen.getByText(/7 confirmations/i)).toBeInTheDocument();
  });
});
