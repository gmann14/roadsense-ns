import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  POTHOLES_UNAVAILABLE_MESSAGE,
  ROAD_NOT_PUBLISHED_MESSAGE,
  ROAD_UNAVAILABLE_MESSAGE,
  SegmentDrawer,
} from "@/components/map/segment-drawer";

const { getPotholesMock, getSegmentDetailMock } = vi.hoisted(() => ({
  getPotholesMock: vi.fn(),
  getSegmentDetailMock: vi.fn(),
}));

vi.mock("@/lib/api/client", async () => {
  const actual = await vi.importActual<typeof import("@/lib/api/client")>("@/lib/api/client");
  return {
    ...actual,
    getPotholes: getPotholesMock,
    getSegmentDetail: getSegmentDetailMock,
  };
});

const smallBbox = { minLng: -63.6, minLat: 44.6, maxLng: -63.55, maxLat: 44.65 };

beforeEach(() => {
  getPotholesMock.mockReset();
  getSegmentDetailMock.mockReset();
});

afterEach(() => {
  cleanup();
});

function renderDrawer(overrides: Partial<Parameters<typeof SegmentDrawer>[0]> = {}) {
  return render(
    <SegmentDrawer
      mode="potholes"
      selectedSegmentId={null}
      visibleBbox={smallBbox}
      topPotholes={[]}
      onClearSelection={vi.fn()}
      onPotholeLocate={vi.fn()}
      isOpen
      onClose={vi.fn()}
      {...overrides}
    />,
  );
}

describe("segment drawer data states", () => {
  it("says pothole data is unavailable when the API fails, never 'no potholes'", async () => {
    getPotholesMock.mockResolvedValue({ ok: false, reason: "http", status: 503 });

    renderDrawer();

    expect(await screen.findByText(POTHOLES_UNAVAILABLE_MESSAGE)).toBeInTheDocument();
    expect(screen.queryByText(/no active potholes/i)).not.toBeInTheDocument();
  });

  it("shows the empty state only for a successful empty response", async () => {
    getPotholesMock.mockResolvedValue({ ok: true, data: { potholes: [] } });

    renderDrawer();

    expect(await screen.findByText(/no active potholes are published in this view yet/i)).toBeInTheDocument();
  });

  it("passes an abort signal to the pothole request", async () => {
    getPotholesMock.mockResolvedValue({ ok: true, data: { potholes: [] } });

    renderDrawer();

    await screen.findByText(/no active potholes/i);
    expect(getPotholesMock).toHaveBeenCalledWith(smallBbox, { signal: expect.any(AbortSignal) });
  });

  it("explains unpublished roads on a 404", async () => {
    getSegmentDetailMock.mockResolvedValue({ ok: false, reason: "http", status: 404 });

    renderDrawer({ mode: "quality", selectedSegmentId: "seg-1" });

    expect(await screen.findByText(ROAD_NOT_PUBLISHED_MESSAGE)).toBeInTheDocument();
    expect(getSegmentDetailMock).toHaveBeenCalledWith("seg-1", { signal: expect.any(AbortSignal) });
  });

  it("shows an outage message for other segment failures", async () => {
    getSegmentDetailMock.mockResolvedValue({ ok: false, reason: "timeout", status: null });

    renderDrawer({ mode: "quality", selectedSegmentId: "seg-2" });

    expect(await screen.findByText(ROAD_UNAVAILABLE_MESSAGE)).toBeInTheDocument();
  });

  it("formats segment detail dates and counts consistently", async () => {
    getSegmentDetailMock.mockResolvedValue({
      ok: true,
      data: {
        id: "seg-3",
        road_name: "Robie Street",
        road_type: "primary",
        municipality: "Halifax",
        length_m: 50,
        has_speed_bump: false,
        has_rail_crossing: false,
        surface_type: "asphalt",
        aggregate: {
          avg_roughness_score: 0.5,
          category: "fair",
          confidence: "medium",
          total_readings: 12345,
          unique_contributors: 4,
          pothole_count: 0,
          trend: "stable",
          score_last_30d: null,
          score_30_60d: null,
          last_reading_at: "2026-11-08",
          updated_at: "2026-11-08",
        },
        history: [],
        neighbors: null,
      },
    });

    renderDrawer({ mode: "quality", selectedSegmentId: "seg-3" });

    expect(await screen.findByText("12,345")).toBeInTheDocument();
    expect(screen.getByText(/Last community reading on Nov 8, 2026/)).toBeInTheDocument();
  });
});
