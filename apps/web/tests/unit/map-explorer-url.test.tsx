import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { MapExplorer } from "@/components/map/map-explorer";

const { routerPush, mapViewProps, drawerProps } = vi.hoisted(() => ({
  routerPush: vi.fn(),
  mapViewProps: { current: null as null | { onSegmentSelect: (id: string) => void } },
  drawerProps: { current: null as null | { isOpen: boolean; selectedSegmentId: string | null; onClose: () => void } },
}));

// Next keeps usePathname/useSearchParams in sync with native
// history.replaceState (re-rendering subscribers); mirror that here.
vi.mock("next/navigation", async () => {
  const { useSyncExternalStore } = await import("react");
  const listeners = new Set<() => void>();
  const nativeReplaceState = window.history.replaceState.bind(window.history);
  window.history.replaceState = (...args: Parameters<History["replaceState"]>) => {
    nativeReplaceState(...args);
    listeners.forEach((listener) => listener());
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  };
  const useHref = () => useSyncExternalStore(subscribe, () => window.location.href);

  return {
    usePathname: () => new URL(useHref()).pathname,
    useRouter: () => ({ push: routerPush, replace: vi.fn() }),
    useSearchParams: () => new URL(useHref()).searchParams,
  };
});

vi.mock("@/components/map/road-quality-map-view", () => ({
  RoadQualityMapView: (props: { onSegmentSelect: (id: string) => void }) => {
    mapViewProps.current = props;
    return <div data-testid="map" />;
  },
}));

vi.mock("@/components/map/segment-drawer", () => ({
  SegmentDrawer: (props: { isOpen: boolean; selectedSegmentId: string | null; onClose: () => void }) => {
    drawerProps.current = props;
    return <div data-testid="drawer" data-open={props.isOpen} />;
  },
}));

vi.mock("@/lib/search/mapbox-geocoding", () => ({ searchPlaces: vi.fn(async () => []) }));

beforeEach(() => {
  window.history.replaceState(null, "", "/");
  routerPush.mockClear();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("map URL state", () => {
  it("updates the URL in place on mode changes, without a server navigation", () => {
    const replaceState = vi.spyOn(window.history, "replaceState");
    render(<MapExplorer stats={null} />);

    fireEvent.click(screen.getByRole("tab", { name: /coverage/i }));

    expect(replaceState).toHaveBeenCalledWith(null, "", "/?mode=coverage");
    expect(window.location.search).toBe("?mode=coverage");
    expect(routerPush).not.toHaveBeenCalled();
    expect(screen.getByRole("tab", { name: /coverage/i })).toHaveAttribute("aria-selected", "true");
  });

  it("deep-links segment clicks and keeps the drawer closed once cleared", () => {
    // Server rendered this page from a shared ?segment= link.
    window.history.replaceState(null, "", "/?segment=abc");
    render(<MapExplorer stats={null} searchParams={{ segment: "abc" }} />);
    expect(drawerProps.current?.isOpen).toBe(true);

    act(() => {
      drawerProps.current?.onClose();
    });
    expect(window.location.search).toBe("");
    // The stale server prop must not bring the segment back.
    expect(drawerProps.current?.selectedSegmentId).toBeNull();
    expect(drawerProps.current?.isOpen).toBe(false);

    act(() => {
      mapViewProps.current?.onSegmentSelect("seg-42");
    });
    expect(window.location.search).toBe("?segment=seg-42");
    expect(drawerProps.current?.selectedSegmentId).toBe("seg-42");
    expect(routerPush).not.toHaveBeenCalled();
  });
});

describe("mobile search toggle", () => {
  it("opens and closes the search panel", () => {
    const { container } = render(<MapExplorer stats={null} />);
    const toggle = screen.getByRole("button", { name: "Search the map" });
    const panel = container.querySelector("#map-search-panel");

    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(toggle).toHaveAttribute("aria-controls", "map-search-panel");
    expect(panel).toHaveAttribute("data-mobile-open", "false");

    fireEvent.click(toggle);
    expect(screen.getByRole("button", { name: "Close search" })).toHaveAttribute("aria-expanded", "true");
    expect(panel).toHaveAttribute("data-mobile-open", "true");

    fireEvent.click(screen.getByRole("button", { name: "Close search" }));
    expect(panel).toHaveAttribute("data-mobile-open", "false");
  });
});
