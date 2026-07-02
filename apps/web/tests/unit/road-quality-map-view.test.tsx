import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { RoadQualityMapView } from "@/components/map/road-quality-map-view";
import type { UrlViewportState } from "@/lib/url-state";

afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
});

type Handler = (...args: unknown[]) => void;

// Minimal fake mapboxgl.Map that records event listeners so tests can fire
// "error" / "load" / "idle" the same way the real SDK would.
class FakeMap {
  listeners = new Map<string, Handler[]>();
  static instances: FakeMap[] = [];

  constructor(_options: unknown) {
    FakeMap.instances.push(this);
  }

  on(event: string, a: Handler | string, b?: Handler) {
    // Support both map.on("load", cb) and map.on("click", "layer-id", cb)
    const handler = typeof a === "function" ? a : b!;
    const list = this.listeners.get(event) ?? [];
    list.push(handler);
    this.listeners.set(event, list);
    return this;
  }

  once(event: string, handler: Handler) {
    this.on(event, handler);
    return this;
  }

  emit(event: string, payload?: unknown) {
    for (const handler of this.listeners.get(event) ?? []) {
      handler(payload);
    }
  }

  addControl() {
    return this;
  }
  addSource() {
    return this;
  }
  getSource() {
    return undefined;
  }
  addLayer() {
    return this;
  }
  getLayer() {
    return undefined;
  }
  setLayoutProperty() {}
  setFilter() {}
  isStyleLoaded() {
    return true;
  }
  resize() {}
  fitBounds() {}
  easeTo() {}
  getCanvas() {
    return { style: {} } as unknown as HTMLCanvasElement;
  }
  getBounds() {
    return {
      getWest: () => -64,
      getSouth: () => 44,
      getEast: () => -63,
      getNorth: () => 45,
    };
  }
  getCenter() {
    return { lat: 44.5, lng: -63.5 };
  }
  getZoom() {
    return 10;
  }
  remove() {}
}

vi.mock("mapbox-gl", () => {
  return {
    default: {
      Map: FakeMap,
      NavigationControl: class {},
      accessToken: "",
    },
  };
});

vi.mock("@/lib/api/client", async () => {
  const actual = await vi.importActual<typeof import("@/lib/api/client")>("@/lib/api/client");
  return {
    ...actual,
    getMapboxToken: () => "test-token",
    getMapboxStyleUrl: () => "mapbox://styles/mapbox/light-v11",
    getQualityTileUrlTemplate: () => "https://test.local/tiles/{z}/{x}/{y}.mvt",
    getCoverageTileUrlTemplate: () => "https://test.local/tiles/coverage/{z}/{x}/{y}.mvt",
    getPublicReadHeaders: () => ({}),
  };
});

const baseRouteState: UrlViewportState = {
  mode: "quality",
  segment: null,
  lat: null,
  lng: null,
  z: null,
  q: null,
};

beforeEach(() => {
  FakeMap.instances = [];
});

describe("RoadQualityMapView error banner recovery", () => {
  it("clears a previously shown error banner once the map settles again (idle)", async () => {
    const onMapErrorChange = vi.fn();

    render(
      <RoadQualityMapView
        mode="quality"
        routeState={baseRouteState}
        mapBounds={null}
        mapFocusBounds={null}
        potholeBounds={null}
        topPotholes={[]}
        onViewportCommit={vi.fn()}
        onSegmentSelect={vi.fn()}
        onMapReadyChange={vi.fn()}
        onMapErrorChange={onMapErrorChange}
      />,
    );

    await waitFor(() => expect(FakeMap.instances.length).toBe(1));
    const map = FakeMap.instances[0];

    // Simulate the map finishing its initial load.
    map.emit("load");

    // A tile/sprite/glyph fetch fails at some point during the session.
    map.emit("error", { error: { message: "Failed to fetch tile" } });
    expect(onMapErrorChange).toHaveBeenCalledWith("Road data is temporarily unavailable. Try again shortly.");

    // The map recovers and settles again — the banner should not be sticky.
    onMapErrorChange.mockClear();
    map.emit("idle");
    expect(onMapErrorChange).toHaveBeenCalledWith(null);
  });
});
